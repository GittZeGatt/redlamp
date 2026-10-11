import CoreGraphics
import CoreVideo
import Foundation
import IOSurface
import RedlampEngineAPI
import Synchronization
import Testing
@testable import RedlampUI

/// An `RGhA` surface as the engine renders frames into, each pixel what `pixel` gives at its column and row.
func judgingSurface(_ size: PixelSize, _ pixel: (Int, Int) -> SIMD4<Float>) -> IOSurfaceRef? {
    let properties: [CFString: Any] = [
        kIOSurfaceWidth: size.width, kIOSurfaceHeight: size.height, kIOSurfaceBytesPerElement: 8,
        kIOSurfacePixelFormat: kCVPixelFormatType_64RGBAHalf,
    ]
    guard let surface = IOSurfaceCreate(properties as CFDictionary) else { return nil }
    IOSurfaceLock(surface, [], nil)
    defer { IOSurfaceUnlock(surface, [], nil) }
    let rowBytes = IOSurfaceGetBytesPerRow(surface)
    let base = IOSurfaceGetBaseAddress(surface)
    for row in 0 ..< size.height {
        let line = base.advanced(by: row * rowBytes).assumingMemoryBound(to: Float16.self)
        for column in 0 ..< size.width {
            let value = pixel(column, row)
            for channel in 0 ..< 4 {
                line[column * 4 + channel] = Float16(value[channel])
            }
        }
    }
    return surface
}

/// An engine that opens anything at once and renders each frame as a grey ramp, with Develop's marks where
/// `clipped` says the sensor clipped at a point of the photo, and its comparison without them.
final class FakeClippingEngine: ClippingEngine, @unchecked Sendable {
    let opened = Mutex<[URL]>([])
    let renders = Mutex<[RenderRequest]>([])
    let prefetched = Mutex<[[URL]]>([])
    let releases = Mutex(0)
    /// The channels the sensor clipped at a point of the photo, 0 ... 1.
    let clipped: @Sendable (CGPoint) -> [Bool]
    /// What `open` throws instead of opening the photo.
    var openError: (any Error)?
    private let stream: AsyncStream<RenderedFrame>
    private let continuation: AsyncStream<RenderedFrame>.Continuation

    init(clipped: @escaping @Sendable (CGPoint) -> [Bool]) {
        self.clipped = clipped
        (stream, continuation) = AsyncStream.makeStream()
    }

    /// The left fifth clipped in red, the top fifth in green and blue, and their corner in all three.
    static func corner() -> FakeClippingEngine {
        FakeClippingEngine { point in [point.x < 0.2, point.y < 0.2, point.y < 0.2] }
    }

    func open(_ url: URL) async throws -> ImageInfo {
        opened.withLock { $0.append(url) }
        if let openError {
            throw openError
        }
        return ImageInfo(url: url, pixelSize: PixelSize(width: 6000, height: 4000), isRaw: true, sensorDescription: "")
    }

    func prefetch(_ urls: [URL]) {
        prefetched.withLock { $0.append(urls) }
    }

    /// The frames painted, by size and region: every photo of the fake looks the same, and painting a pixel at a time
    /// takes the stepping test's time otherwise.
    private let painted = Mutex<[String: RenderedFrame]>([:])

    func render(_ request: RenderRequest) {
        renders.withLock { $0.append(request) }
        let size = request.region == nil
            ? PixelSize(width: 6000, height: 4000).fitted(within: request.targetSize) : request.targetSize
        let region = request.region ?? .full
        let key = "\(size.width)×\(size.height) \(region)"
        if let frame = painted.withLock({ $0[key] }) {
            continuation.yield(RenderedFrame(
                surface: frame.surface, size: size, region: region, comparison: frame.comparison,
                histogram: frame.histogram, generation: request.generation, renderDuration: .zero,
            ))
            return
        }
        // Never quite black or white, as no developed pixel is where all three channels clipped.
        let ramp = { (column: Int, _: Int) in
            let grey = 0.1 + 0.8 * Float(column) / Float(max(size.width, 1))
            return SIMD4<Float>(grey, grey, grey, 1)
        }
        let clipped = clipped
        guard let comparison = judgingSurface(size, ramp), let surface = judgingSurface(size, { column, row in
            let point = CGPoint(
                x: region.x + (Double(column) + 0.5) / Double(size.width) * region.width,
                y: region.y + (Double(row) + 0.5) / Double(size.height) * region.height,
            )
            let channels = clipped(point)
            guard channels.contains(true) else { return ramp(column, row) }
            let mark = !channels.contains(false) ? SIMD3<Float>.zero : SIMD3<Float>(
                channels[0] ? 1 : 0, channels[1] ? 1 : 0, channels[2] ? 1 : 0,
            )
            return SIMD4(mark, 1)
        }) else { return }
        let frame = RenderedFrame(
            surface: surface, size: size, region: region, comparison: comparison, histogram: histogram,
            generation: request.generation, renderDuration: .zero,
        )
        painted.withLock { $0[key] = frame }
        continuation.yield(frame)
    }

    /// A histogram with a bump in the middle of each channel, as the engine would give for the ramp.
    var histogram: Histogram {
        let bins = (0 ..< Histogram.binCount).map { UInt32(max(0, 1000 - abs($0 - 128) * 8)) }
        return Histogram(red: bins, green: bins, blue: bins, luminance: bins)
    }

    func frames() -> AsyncStream<RenderedFrame> {
        stream
    }

    func releaseResources() async {
        releases.withLock { $0 += 1 }
    }
}

/// Sensor clipping in the Library (LIB-38): Develop's marks found in a frame where it differs from its comparison,
/// each channel's share counted, and the engine opened once a photo, only for raws, and let go.
@MainActor
struct SensorClippingTests {
    /// The image's premultiplied RGBA at a pixel.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return [] }
        let at = y * image.bytesPerRow + x * 4
        return (0 ..< 4).map { bytes[at + $0] }
    }

    @Test func `the marks are where the frame differs from its comparison, in their channels' colours`() throws {
        let size = PixelSize(width: 300, height: 200)
        let ramp = { (column: Int, _: Int) in
            let grey = 0.1 + 0.8 * Float(column) / 300
            return SIMD4<Float>(grey, grey, grey, 1)
        }
        let comparison = try #require(judgingSurface(size, ramp))
        let surface = try #require(judgingSurface(size) { column, row in
            switch (column < 60, row < 40) {
            case (true, true): SIMD4(0, 0, 0, 1)
            case (true, false): SIMD4(1, 0, 0, 1)
            case (false, true): SIMD4(0, 1, 1, 1)
            default: ramp(column, row)
            }
        })
        let marks = SensorClipping.marks(surface: surface, comparison: comparison, size: size, region: nil)
        let image = try #require(marks.image)
        #expect(image.width == 300 && image.height == 200)
        #expect(pixel(image, 10, 100) == [255, 0, 0, 255], "red alone on the left")
        #expect(pixel(image, 150, 10) == [0, 255, 255, 255], "green and blue along the top")
        #expect(pixel(image, 10, 10) == [0, 0, 0, 255], "black where all three clipped")
        #expect(pixel(image, 150, 100) == [0, 0, 0, 0], "clear where the sensor clipped nothing")
        // Red: the left fifth, 60 columns of 200 rows; green and blue: the top fifth, 300 columns of 40 rows.
        let pixels = 300.0 * 200
        #expect(abs(marks.shares.x - 60 * 200 / pixels) < 1e-9)
        #expect(abs(marks.shares.y - 300 * 40 / pixels) < 1e-9 && abs(marks.shares.z - marks.shares.y) < 1e-9)
        #expect(abs(marks.allShare - 60 * 40 / pixels) < 1e-9)
    }

    @Test func `a difference in a colour that isn't a mark's isn't taken for one`() throws {
        let size = PixelSize(width: 200, height: 100)
        let ramp = { (column: Int, _: Int) in
            let grey = 0.1 + 0.8 * Float(column) / 200
            return SIMD4<Float>(grey, grey, grey, 1)
        }
        let comparison = try #require(judgingSurface(size, ramp))
        // The frame a touch brighter everywhere, as a heal's maps refreshed after it leave it, and a red mark in its
        // first 20 columns; white, which no mark is, in the next 20.
        let surface = try #require(judgingSurface(size) { column, row in
            switch column {
            case ..<20: SIMD4(1, 0, 0, 1)
            case ..<40: SIMD4(1, 1, 1, 1)
            default: ramp(column, row) + SIMD4(0.01, 0.01, 0.01, 0)
            }
        })
        let marks = SensorClipping.marks(surface: surface, comparison: comparison, size: size, region: nil)
        #expect(abs(marks.shares.x - 0.1) < 1e-9, "red over the first tenth alone: \(marks.shares)")
        #expect(marks.shares.y == 0 && marks.shares.z == 0 && marks.allShare == 0)
        let image = try #require(marks.image)
        #expect(pixel(image, 30, 50) == [0, 0, 0, 0] && pixel(image, 100, 50) == [0, 0, 0, 0])
    }

    @Test func `Compare's two photos are decoded ahead together, each shown photo first`() async throws {
        let engine = FakeClippingEngine.corner()
        let clipping = SensorClipping { engine }
        let (select, candidate) = (NSObject(), NSObject())
        let photos = (1 ... 6).map { URL(fileURLWithPath: "/photos/IMG_000\($0).NEF") }
        clipping.prefetch([photos[0], photos[1], photos[2]], for: select)
        clipping.prefetch([photos[3], photos[4], URL(fileURLWithPath: "/photos/IMG_0009.JPG")], for: candidate)
        #expect(
            engine.prefetched.withLock { $0.last } == [photos[0], photos[3], photos[1], photos[2], photos[4]],
            "both shown photos first, then the ones around them, raws alone",
        )
        let size = PixelSize(width: 64, height: 64)
        _ = try await clipping.marks(.init(url: photos[3], recipe: EditRecipe(), size: size, region: nil))
        #expect(engine.prefetched.withLock { $0.count } == 2, "a listed photo is opened as it is")
        _ = try await clipping.marks(.init(url: photos[5], recipe: EditRecipe(), size: size, region: nil))
        #expect(
            engine.prefetched.withLock { $0.last?.first } == photos[5],
            "one off the list is put first, then opened",
        )
        clipping.forget(candidate)
        clipping.prefetch([photos[1], photos[2]], for: select)
        #expect(engine.prefetched.withLock { $0.last } == [photos[1], photos[2]], "a host showing nothing has no say")
    }

    @Test func `a frame the sensor clipped nothing in has no marks`() throws {
        let size = PixelSize(width: 130, height: 300)
        let plain = { (column: Int, row: Int) in SIMD4<Float>(Float(column) / 130, Float(row) / 300, 0.5, 1) }
        let marks = try SensorClipping.marks(
            surface: #require(judgingSurface(size, plain)), comparison: #require(judgingSurface(size, plain)),
            size: size,
            region: nil,
        )
        #expect(marks.image == nil && marks.shares == .zero && marks.allShare == 0)
    }

    @Test func `a photo is opened once for its whole and its parts, rendered with its marks and without`() async throws {
        let engine = FakeClippingEngine.corner()
        let makes = Mutex(0)
        let clipping = SensorClipping {
            makes.withLock { $0 += 1 }
            return engine
        }
        #expect(!clipping.hasEngine && makes.withLock { $0 } == 0, "no engine until a raw is read")
        let photo = URL(fileURLWithPath: "/photos/IMG_0001.CR3")
        var recipe = EditRecipe()
        recipe[.exposure] = 1
        let whole = try #require(try await clipping.marks(.init(
            url: photo, recipe: recipe, size: PixelSize(width: 300, height: 300), region: nil,
        )))
        #expect(whole.size == PixelSize(width: 300, height: 200) && whole.region == nil)
        #expect(abs(whole.shares.x - 0.2) < 0.01, "red over the left fifth, its corner black counted with it")
        #expect(abs(whole.shares.y - 0.2) < 0.01 && abs(whole.allShare - 0.04) < 0.01)
        let part = ImageRect(x: 0, y: 0, width: 0.1, height: 0.1)
        let corner = try #require(try await clipping.marks(.init(
            url: photo, recipe: recipe, size: PixelSize(width: 100, height: 100), region: part,
        )))
        #expect(abs(corner.allShare - 1) < 1e-9, "the photo's corner is clipped in all three")
        #expect(engine.opened.withLock { $0 } == [photo], "opened once")
        let renders = engine.renders.withLock { $0 }
        #expect(renders.count == 2 && renders.allSatisfy { $0.showRawClipping && $0.comparison == $0.recipe })
        #expect(renders.map(\.recipe[.exposure]) == [1, 1], "the edit's own recipe")
        #expect(renders.last?.region == part)
        #expect(clipping.statistics.opened == 1 && clipping.statistics.rendered == 2)
        clipping.release()
        try await waitUntil { engine.releases.withLock { $0 } == 1 }
        #expect(!clipping.hasEngine)
    }

    @Test func `files without sensor data, and raws that won't open, give no marks`() async throws {
        let engine = FakeClippingEngine.corner()
        let clipping = SensorClipping { engine }
        let size = PixelSize(width: 100, height: 100)
        let jpeg = try await clipping.marks(.init(
            url: URL(fileURLWithPath: "/photos/IMG_0001.JPG"), recipe: EditRecipe(), size: size, region: nil,
        ))
        #expect(jpeg == nil && engine.opened.withLock { $0 }.isEmpty, "a JPEG isn't opened")
        engine.openError = EngineError.unsupportedFile("IMG_0002.NEF")
        let broken = try await clipping.marks(.init(
            url: URL(fileURLWithPath: "/photos/IMG_0002.NEF"), recipe: EditRecipe(), size: size, region: nil,
        ))
        #expect(broken == nil && engine.renders.withLock { $0 }.isEmpty)
    }

    @Test func `requests take their turn, and one cancelled while waiting never opens its photo`() async throws {
        let engine = FakeClippingEngine.corner()
        let clipping = SensorClipping { engine }
        let size = PixelSize(width: 64, height: 64)
        let photos = (1 ... 3).map { URL(fileURLWithPath: "/photos/IMG_000\($0).ARW") }
        let first = Task {
            try await clipping.marks(.init(url: photos[0], recipe: EditRecipe(), size: size, region: nil))
        }
        let second = Task { try await clipping.marks(.init(
            url: photos[1],
            recipe: EditRecipe(),
            size: size,
            region: nil,
        )) }
        second.cancel()
        let third = Task {
            try await clipping.marks(.init(url: photos[2], recipe: EditRecipe(), size: size, region: nil))
        }
        #expect(try await first.value != nil)
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(try await third.value != nil)
        #expect(engine.opened.withLock { $0 } == [photos[0], photos[2]])
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), deadline > .now {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
