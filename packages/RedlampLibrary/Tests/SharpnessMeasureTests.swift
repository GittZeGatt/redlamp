import CoreGraphics
import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// The soft-frame measure (LIB-42): a burst's sharp frames score alike, its soft ones (out of focus, moved, focused
/// behind the subject) well below, whatever their brightness; where a camera gives no AF point, the grid finds the
/// sharp part of the frame; and the largest preview of each sample raw is found without developing it.
struct SharpnessMeasureTests {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "tests/fixtures")

    private static var haveSamples: Bool {
        FileManager.default.fileExists(atPath: fixtures.appending(path: "cameras/Canon_EOS-R6-Mark-III.CR3").path)
    }

    private static let scheduler = WorkScheduler(
        widths: WorkScheduler.Widths(onScreen: 2, lookAhead: 2, background: 2), canRunBackground: { true },
    )

    private static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "redlamp-sharpness-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static let frames: [SoftFrameSamples.Frame] = [
        .sharp(shift: 0), .sharp(shift: 1), .sharp(shift: 2), .brighter, .blurred(sigma: 1), .blurred(sigma: 2),
        .motion(length: 5), .motion(length: 9), .focusMissed,
    ]

    @Test func `a burst's sharp frames score alike at the AF point, and its soft ones well below`() async throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = try SoftFrameSamples.writeBurst(Self.frames, to: folder, name: "B_", start: Date())
        let size = CGSize(width: SoftFrameSamples.width, height: SoftFrameSamples.height)
        var scores: [Float] = []
        for url in urls {
            let found = try await SharpnessReader.measure(url, imageSize: size, scheduler: Self.scheduler)
            #expect(found.focus == .afPoint, "\(url.lastPathComponent)")
            scores.append(found.score)
        }
        let sharpest = try #require(scores.max())
        let relative = scores.map { $0 / sharpest }
        print("SHARPNESS", zip(Self.frames, relative).map { "\($0): \(String(format: "%.2f", $1))" })
        for (frame, value) in zip(Self.frames, relative) {
            if frame.isSoft {
                #expect(value < SoftFrames.softBelow, "\(frame) at \(value)")
            } else {
                #expect(value > 0.85, "\(frame) at \(value)")
            }
        }
    }

    @Test func `a region flat but for noise scores low, and a region's contrast doesn't count`() throws {
        let flat = GreyPlane(width: 64, height: 64, pixels: (0 ..< 4096).map { Float(128 + $0 % 3) })
        let image = try #require(SoftFrameSamples.image(.sharp(shift: 0), seed: 3))
        let rect = SoftFrameSamples.subjectRect(width: image.width, height: image.height)
        let textured = try #require(image.cropping(to: rect).flatMap { GreyPlane($0) })
        let halved = GreyPlane(
            width: textured.width, height: textured.height, pixels: textured.pixels.map { 64 + $0 / 2 },
        )
        #expect(SharpnessMeasure.score(flat) < SharpnessMeasure.score(textured) / 4)
        let ratio = SharpnessMeasure.score(halved) / SharpnessMeasure.score(textured)
        #expect(abs(ratio - 1) < 0.05, "half the contrast scores \(ratio) of the whole")
    }

    @Test func `the region is a square around the areas the camera focused, inside the preview`() throws {
        let point = AFPoints.Area.point(CGPoint(x: 0.5, y: 0.5))
        let centre = try #require(SharpnessMeasure.region(around: [point], width: 6000, height: 4000))
        #expect(centre == CGRect(x: 2760, y: 1760, width: 480, height: 480), "8% of the long edge")

        let corner = try #require(SharpnessMeasure.region(
            around: [AFPoints.Area(rect: CGRect(x: 0.85, y: 0.8, width: 0.2, height: 0.2), inFocus: true)],
            width: 6000, height: 4000,
        ))
        #expect(corner.maxX == 6000 && corner.maxY == 4000 && corner.width == 1200, "the area's size, kept inside")

        let chosen = AFPoints.Area(rect: CGRect(x: 0.1, y: 0.1, width: 0, height: 0), inFocus: false)
        let focused = try #require(SharpnessMeasure.region(around: [chosen, point], width: 6000, height: 4000))
        #expect(focused == centre, "the area in focus, not the one only chosen")
        #expect(SharpnessMeasure.region(around: [], width: 6000, height: 4000) == nil)
    }

    @Test func `the grid finds the part of a frame that's sharp`() throws {
        let image = try #require(SoftFrameSamples.image(.sharp(shift: 0), seed: 5))
        let blurred = try #require(SoftFrameSamples.image(.blurred(sigma: 2), seed: 5))
        let plane = try #require(GreyPlane(image))
        let soft = try #require(GreyPlane(blurred))
        let half = plane.width / 2
        var pixels = plane.pixels
        for row in 0 ..< plane.height {
            let start = row * plane.width + half
            pixels.replaceSubrange(
                start ..< start + plane.width - half,
                with: soft.pixels[start ..< start + plane.width - half],
            )
        }
        let cells = SharpnessMeasure.cells(GreyPlane(width: plane.width, height: plane.height, pixels: pixels))
        #expect(cells.count == SharpnessMeasure.columns * SharpnessMeasure.rows)
        let columns = SharpnessMeasure.columns
        for row in 0 ..< SharpnessMeasure.rows {
            let left = cells[row * columns ..< row * columns + columns / 2]
            let right = cells[row * columns + columns / 2 ..< (row + 1) * columns]
            #expect(try #require(left.min()) > right.max()!, "row \(row): \(Array(left)) against \(Array(right))")
        }
    }

    /// Sample raws and the size of the largest JPEG each embeds: the α7 IV's full-size one, which ImageIO passes over
    /// for its 1616-pixel preview, as it does the CR3's.
    private static let previews: [(String, Int, Int)] = [
        ("cameras/Canon_EOS-R6-Mark-III.CR3", 6960, 4640), ("cameras/Canon_EOS-5D-Mark-IV.CR2", 6720, 4480),
        ("cameras/Nikon_Z-9_HE.NEF", 8256, 5504), ("cameras/Sony_ILCE-7M4.ARW", 7008, 4672),
        ("raw/_DSC0009.ARW", 1616, 1080), ("cameras/Fujifilm_X-T5.RAF", 4416, 2944),
        ("cameras/Panasonic_DC-S5M2.RW2", 1920, 1280), ("cameras/Pentax_K-3-Mark-III.PEF", 6192, 4128),
        ("raw/IMG_1361.DNG", 4032, 3024),
    ]

    @Test(.enabled(if: haveSamples)) func `each sample raw's largest preview is found without developing it`() async {
        for (path, width, height) in Self.previews {
            let preview = await LargestPreview.open(Self.fixtures.appending(path: path))
            let size = preview.map { "\($0.width)×\($0.height)" } ?? "none"
            #expect(preview?.width == width && preview?.height == height, "\(path): \(size)")
        }
        let tiny = await LargestPreview.open(Self.fixtures.appending(path: "cameras/DJI_FC4382.DNG"))
        #expect(tiny == nil, "a 960-pixel preview isn't measured")
        let hdr = await LargestPreview.open(Self.fixtures.appending(path: "cameras/Canon_EOS-R5-Mark-II.CR3"))
        #expect(hdr == nil, "an HDR PQ frame's previews are HEIF, which isn't measured")
    }

    @Test(.enabled(if: haveSamples)) func `the sample raws are measured at their AF points, or in the grid without one`(
    ) async throws {
        let cases: [(String, PhotoSharpness.Focus, CGSize?)] = [
            ("cameras/Canon_EOS-R6-Mark-III.CR3", .afPoint, nil), ("cameras/Nikon_Z-9_HE.NEF", .afPoint, nil),
            ("cameras/Sony_ILCE-7M4.ARW", .afPoint, nil), (
                "raw/IMG_1361.DNG",
                .afPoint,
                CGSize(width: 3024, height: 4032),
            ),
            ("cameras/Nikon_Z-8.NEF", .grid, nil), ("cameras/Pentax_K-3-Mark-III.PEF", .grid, nil),
        ]
        for (path, focus, size) in cases {
            let found = try await SharpnessReader.measure(
                Self.fixtures.appending(path: path), imageSize: size, scheduler: Self.scheduler,
            )
            #expect(found.focus == focus, "\(path): \(found.focus)")
            #expect(found.focus != .afPoint || found.score > 0, "\(path)")
            #expect(found.focus != .grid || found.cells.count == SharpnessMeasure.columns * SharpnessMeasure.rows)
        }
    }

    @Test(
        .enabled(if: haveSamples),
        .measuresSpeed,
    ) func `measuring a frame takes tens of milliseconds`() async throws {
        let cases = [
            "cameras/Canon_EOS-R6-Mark-III.CR3", "cameras/Nikon_Z-9_HE.NEF", "cameras/Sony_ILCE-7M4.ARW",
            "cameras/Nikon_Z-8.NEF",
        ]
        let clock = ContinuousClock()
        var report: [String] = []
        for path in cases {
            let url = Self.fixtures.appending(path: path)
            _ = try await SharpnessReader.measure(url, imageSize: nil, scheduler: Self.scheduler)
            var times: [Duration] = []
            var focus = PhotoSharpness.Focus.unmeasured
            for _ in 0 ..< 5 {
                let started = clock.now
                focus = try await SharpnessReader.measure(url, imageSize: nil, scheduler: Self.scheduler).focus
                times.append(clock.now - started)
            }
            let median = times.sorted()[2]
            report.append("\(url.lastPathComponent) (\(focus)): \(median)")
            #expect(median < .milliseconds(focus == .grid ? 400 : 200), "\(path): \(median)")
        }
        print("SHARPNESS-BENCH", report.joined(separator: "; "))
    }
}
