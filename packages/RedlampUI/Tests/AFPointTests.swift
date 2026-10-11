import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import RedlampUI

/// The camera's AF point read from the maker notes of the sample raws (LIB-38): where each camera that records one
/// put it, checked against the photos when the reader was written, and nothing for those that record none.
struct AFPointTests {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "tests/fixtures")

    private static var haveSamples: Bool {
        FileManager.default.fileExists(atPath: fixtures.appending(path: "cameras/Canon_EOS-R5-Mark-II.CR3").path)
    }

    private func read(_ path: String, size: CGSize? = nil) -> AFPoints? {
        AFPointReader.read(Self.fixtures.appending(path: path), imageSize: size)
    }

    private func expect(_ rect: CGRect, near expected: CGRect, sourceLocation: SourceLocation = #_sourceLocation) {
        let close = abs(rect.midX - expected.midX) < 0.002 && abs(rect.midY - expected.midY) < 0.002
            && abs(rect.width - expected.width) < 0.002 && abs(rect.height - expected.height) < 0.002
        #expect(close, "\(rect) isn't \(expected)", sourceLocation: sourceLocation)
    }

    private func centred(_ x: Double, _ y: Double, _ width: Double = 0, _ height: Double = 0) -> CGRect {
        CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
    }

    @Test(.enabled(
        if: haveSamples,
    )) func `Canon's mirrorless bodies give the area they focused, centred, Y up`() throws {
        let r5 = try #require(read("cameras/Canon_EOS-R5-Mark-II.CR3"))
        #expect(r5.source == .canon && r5.orientation == 1 && r5.areas.count == 1)
        expect(r5.areas[0].rect, near: centred(0.5 - 84 / 8192, 0.5 - 344 / 5464, 288 / 8192, 288 / 5464))
        #expect(r5.areas[0].inFocus)

        let r6 = try #require(read("cameras/Canon_EOS-R6-Mark-III.CR3"))
        expect(r6.areas[0].rect, near: centred(0.5 + 1508 / 6960, 0.5 - 406 / 4640, 528 / 6960, 528 / 4640))
        #expect(!r6.areas[0].inFocus, "the area chosen, where the camera didn't say it focused")
    }

    @Test(.enabled(
        if: haveSamples,
    )) func `a Canon DSLR gives the points in focus, and a frame focused by hand none`() throws {
        let dslr = try #require(read("cameras/Canon_EOS-5D-Mark-IV.CR2"))
        #expect(dslr.source == .canon && dslr.areas.count == 1 && dslr.areas[0].inFocus)
        expect(dslr.areas[0].rect, near: centred(0.5, 0.5, 218 / 6720, 218 / 4480))
        #expect(read("raw/Canon_EOS_R6_RAW_ISO_100_nocrop_nodual.CR3") == nil, "no valid AF points")
    }

    @Test(.enabled(
        if: haveSamples,
    )) func `Nikon's Z bodies give the AF area in pixels, from AFInfo2's two layouts`() throws {
        let z9 = try #require(read("cameras/Nikon_Z-9_HE.NEF"))
        #expect(z9.source == .nikon)
        expect(z9.areas[0].rect, near: centred(4905 / 8256, 2461 / 5504, 291 / 8256, 323 / 5504))
        let z6 = try #require(read("raw/DSC_0750.NEF"))
        expect(z6.areas[0].rect, near: centred(3024 / 6048, 1160 / 4024, 285 / 6048, 308 / 4024))
        #expect(read("cameras/Nikon_Z-8.NEF") == nil, "a frame with no AF area recorded")
    }

    @Test(.enabled(if: haveSamples)) func `Sony, Fujifilm and Panasonic give a point`() throws {
        let sony = try #require(read("cameras/Sony_ILCE-7M4.ARW"))
        #expect(sony.source == .sony)
        expect(sony.areas[0].rect, near: centred(3832 / 7008, 2102 / 4672))

        let fujifilm = try #require(read("cameras/Fujifilm_X-T5.RAF", size: CGSize(width: 7728, height: 5152)))
        #expect(fujifilm.source == .fujifilm)
        expect(fujifilm.areas[0].rect, near: centred(2207 * 2 / 7728, 1472 * 2 / 5152))
        #expect(read("cameras/Fujifilm_X-T5.RAF") == nil, "Fujifilm's point needs the photo's size")

        let panasonic = try #require(read("cameras/Panasonic_DC-S5M2.RW2"))
        #expect(panasonic.source == .panasonic)
        expect(panasonic.areas[0].rect, near: centred(0.5, 0.5))
    }

    @Test(.enabled(
        if: haveSamples,
    )) func `the iPhone's SubjectArea is read in the photo as stored, and turned upright`() throws {
        let iphone = try #require(read("raw/IMG_1361.DNG", size: CGSize(width: 3024, height: 4032)))
        #expect(iphone.source == .subjectArea && iphone.orientation == 6)
        expect(iphone.areas[0].rect, near: centred(2009 / 4032, 1506 / 3024, 2318 / 4032, 1390 / 3024))
        let upright = iphone.upright[0].rect
        expect(upright, near: centred(1 - 1506 / 3024, 2009 / 4032, 1390 / 3024, 2318 / 4032))
    }

    /// Every sample frame and the reading that finds its AF point; nil where it gives none. The Nikon Z 8's and
    /// Z5 II's frames were taken in auto-area AF and record no area; the Canon R6's was focused by hand.
    private static let samples: [(String, AFPoints.Source?)] = [
        ("cameras/Canon_EOS-5D-Mark-IV.CR2", .canon), ("cameras/Canon_EOS-R5-Mark-II.CR3", .canon),
        ("cameras/Canon_EOS-R6-Mark-III.CR3", .canon), ("raw/Canon_EOS_R6_RAW_ISO_100_nocrop_nodual.CR3", nil),
        ("cameras/Nikon_Z-6III_HE.NEF", .nikon), ("cameras/Nikon_Z-6III_HE-star.NEF", .nikon),
        ("cameras/Nikon_Z-9_HE.NEF", .nikon), ("cameras/Nikon_Z-9_HE-star.NEF", .nikon),
        ("cameras/Nikon_Z-f_HE.NEF", .nikon), ("cameras/Nikon_Z-f_HE-star.NEF", .nikon),
        ("cameras/Nikon_Z50-II_HE.NEF", .nikon), ("cameras/Nikon_Z50-II_HE-star.NEF", .nikon),
        ("raw/DSC_0750.NEF", .nikon), ("cameras/Nikon_Z-8.NEF", nil), ("cameras/Nikon_Z-8_HE.NEF", nil),
        ("cameras/Nikon_Z-8_HE-star.NEF", nil), ("cameras/Nikon_Z5-II_HE.NEF", nil),
        ("cameras/Nikon_Z5-II_HE-star.NEF", nil),
        ("cameras/Sony_ILCE-7M4.ARW", .sony), ("raw/_DSC0009.ARW", .sony),
        ("cameras/Fujifilm_X-T5.RAF", .fujifilm), ("cameras/Fujifilm_GFX100-II.RAF", .fujifilm),
        ("raw/AFXT2720.RAF", .fujifilm), ("cameras/Panasonic_DC-S5M2.RW2", .panasonic),
        ("raw/IMG_1361.DNG", .subjectArea),
        ("cameras/OM-System_OM-1-Mark-II.orf", nil), ("cameras/Pentax_K-3-Mark-III.PEF", nil),
        ("cameras/Leica_M10-R.DNG", nil), ("cameras/Sigma_fp.DNG", nil), ("cameras/Ricoh_GR-III.DNG", nil),
        ("cameras/Hasselblad_X2D-100C.3FR", nil), ("cameras/Hasselblad_X2D-100C.fff", nil),
        ("cameras/Hasselblad_X1D-II-50C.3FR", nil), ("cameras/Hasselblad_L2D-20c.DNG", nil),
        ("cameras/Phase-One_IQ4-150MP.iiq", nil), ("cameras/DJI_FC4382.DNG", nil),
        ("cameras/Samsung_NX1.srw", nil), ("cameras/Samsung_Galaxy-S23-Ultra.dng", nil),
        ("raw/PXL_20201121_100251397.dng", nil),
    ]

    /// The photo's size upright, as the index has it: ImageIO's, turned by its orientation.
    private func uprightSize(_ path: String) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(Self.fixtures.appending(path: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let turned = (5 ... 8).contains(properties[kCGImagePropertyOrientation] as? Int ?? 1)
        return turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    @Test(.enabled(if: haveSamples)) func `every sample camera gives its AF point, or none, as the table says`() {
        for (path, source) in Self.samples {
            let found = read(path, size: uprightSize(path))
            #expect(found?.source == source, "\(path): \(found.map { "\($0.source)" } ?? "none")")
            for area in found?.upright ?? [] {
                #expect((0 ... 1).contains(area.rect.midX) && (0 ... 1).contains(area.rect.midY), "\(path): \(area)")
            }
        }
    }

    @Test func `damaged and foreign files give nothing rather than a trap`() {
        var generator = SystemRandomNumberGenerator()
        for length in [0, 1, 8, 16, 100, 4096] {
            let noise = Data((0 ..< length).map { _ in UInt8.random(in: 0 ... 255, using: &generator) })
            for name in ["cr3", "raf", "nef", "arw", "jpg"] {
                #expect(AFPointReader.read(noise, fileExtension: name, imageSize: CGSize(width: 10, height: 10)) == nil)
            }
        }
        // A TIFF header whose first directory points past the end, and a RAF header whose preview does.
        let tiff = Data([0x49, 0x49, 0x2A, 0x00, 0xFF, 0xFF, 0xFF, 0x7F])
        #expect(AFPointReader.read(tiff, fileExtension: "nef", imageSize: nil) == nil)
        var raf = Data("FUJIFILMCCD-RAW 0201FF383501".utf8)
        raf.append(Data(count: 84 - raf.count))
        raf.append(contentsOf: [0x7F, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x10, 0x00])
        #expect(AFPointReader.read(raf, fileExtension: "raf", imageSize: nil) == nil)
    }

    @Test(.enabled(if: haveSamples)) func `a truncated raw gives nothing`() throws {
        let data = try Data(contentsOf: Self.fixtures.appending(path: "cameras/Canon_EOS-R5-Mark-II.CR3"))
        for length in [16, 1024, 4096] {
            #expect(AFPointReader.read(data.prefix(length), fileExtension: "cr3", imageSize: nil) == nil)
        }
    }

    @Test func `orientation turns a point as the photo turns`() {
        let point = CGPoint(x: 0.25, y: 0.1)
        #expect(AFPoints.oriented(point, 1) == point)
        #expect(AFPoints.oriented(point, 3) == CGPoint(x: 0.75, y: 0.9))
        #expect(AFPoints.oriented(point, 6) == CGPoint(x: 0.9, y: 0.25), "turned clockwise: the top edge to the right")
        #expect(
            AFPoints.oriented(point, 8) == CGPoint(x: 0.1, y: 0.75),
            "turned anticlockwise: the top edge to the left",
        )
    }

    @Test(.enabled(if: haveSamples), .measuresSpeed) func `reading an AF point takes milliseconds`() {
        let url = Self.fixtures.appending(path: "cameras/Canon_EOS-R5-Mark-II.CR3")
        _ = AFPointReader.read(url, imageSize: nil)
        let clock = ContinuousClock()
        let took = clock.measure {
            for _ in 0 ..< 10 {
                _ = AFPointReader.read(url, imageSize: nil)
            }
        }
        #expect(took / 10 < .milliseconds(50), "\(took / 10) a read")
    }
}
