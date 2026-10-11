import Accelerate
import CoreGraphics
import Foundation
import IOSurface
import RedlampEngineAPI

/// What the sensor clipped in a photo, as Develop's Show Sensor Clipping paints it (LIB-38): its marks, at the size
/// and over the part of the photo asked for, each mark in the colour of the channels the sensor clipped there (black
/// where all three did), and the share of the photo each channel clipped in.
struct ClippingMarks: @unchecked Sendable {
    /// The marks on clear, in Display P3; nil when the sensor clipped nothing there.
    let image: CGImage?
    let size: PixelSize
    /// The part of the photo the marks cover; nil for all of it.
    let region: ImageRect?
    /// The share of the pixels where each channel clipped, red, green and blue.
    let shares: SIMD3<Double>
    /// The share where all three did.
    let allShare: Double
    /// The photo's histogram as Redlamp develops it from the raw, for the whole photo's marks.
    var histogram: Histogram?
    /// The share of the photosites at the sensor's clip point, as the decoder counted them.
    var photosites: Double?

    /// What the raw histogram shows of them.
    var reading: RawHistogramView.Reading {
        RawHistogramView.Reading(clipped: shares, clippedInAll: allShare, photosites: photosites, histogram: histogram)
    }
}

/// What sensor clipping asks of an engine: `EditingEngine`'s calls for opening photos, decoding them ahead,
/// rendering them and letting them go.
protocol ClippingEngine: AnyObject, Sendable {
    func open(_ url: URL) async throws -> ImageInfo
    func prefetch(_ urls: [URL])
    func render(_ request: RenderRequest)
    func frames() -> AsyncStream<RenderedFrame>
    func releaseResources() async
}

/// A worker engine, as sensor clipping uses it.
final class WorkerClippingEngine: ClippingEngine {
    let engine: any EditingEngine

    init(_ engine: any EditingEngine) {
        self.engine = engine
    }

    func open(_ url: URL) async throws -> ImageInfo {
        try await engine.open(url)
    }

    func prefetch(_ urls: [URL]) {
        engine.prefetch(urls)
    }

    func render(_ request: RenderRequest) {
        engine.render(request)
    }

    func frames() -> AsyncStream<RenderedFrame> {
        engine.frames()
    }

    func releaseResources() async {
        await engine.releaseResources()
    }
}

/// Sensor clipping for the Library's loupe and Compare (LIB-38): Develop's own, painted by Redlamp's engine from the
/// raw data, in an engine of the judging tools' own that's made when a tool needs the raw and let go when none has
/// for `idleRelease`. Each photo is opened (decoded in the decode service, its pyramid built) and rendered at the size
/// it's shown with `showRawClipping`, its `comparison` being the same edit, which the engine renders without the
/// marks: the two differ exactly where the marks are. One photo at a time; the photos each host shows and those it's
/// stepping towards are decoded ahead, the engine keeping as many as its own memory budget holds.
@MainActor
final class SensorClipping {
    struct Request: Hashable, Sendable {
        let url: URL
        let recipe: EditRecipe
        let size: PixelSize
        let region: ImageRect?
    }

    /// What reading the raw has cost: photos opened and the time it took, renders and the time they took with
    /// their marks found.
    struct Statistics: Sendable, Equatable {
        var opened = 0
        var opening = Duration.zero
        var rendered = 0
        var rendering = Duration.zero
    }

    /// How long a frame may take before the request gives up.
    static let frameTimeout = Duration.seconds(20)
    /// How long the engine is kept with nothing asked of it, as the library's renders keep theirs.
    static let idleRelease = Duration.seconds(10)

    private let makeEngine: () -> (any ClippingEngine)?
    private var engine: (any ClippingEngine)?
    private var consumer: Task<Void, Never>?
    private var waiting: [UInt64: CheckedContinuation<RenderedFrame?, Never>] = [:]
    private var generation: UInt64 = 0
    /// The photo open in the engine, and what it said about it.
    private var opened: (url: URL, info: ImageInfo)?
    /// Each host's photo and the photos around it, in the order hosts first asked, and the list the engine was
    /// last given: `EditingEngine.prefetch` replaces its list, and an open of a photo off it is cancelled.
    private var wanted: [(host: ObjectIdentifier, urls: [URL])] = []
    private var listed: [URL] = []
    /// One request runs at a time; the rest wait their turn here.
    private var busy = false
    private var turns: [CheckedContinuation<Void, Never>] = []
    private var idle: Task<Void, Never>?
    private(set) var statistics = Statistics()

    init(makeEngine: @escaping () -> (any ClippingEngine)?) {
        self.makeEngine = makeEngine
    }

    /// The marks for `request`; nil when the photo can't be read. Throws `CancellationError` when the caller's task
    /// was cancelled first, or the engine dropped the photo, so it's asked for again rather than taken for unreadable.
    func marks(_ request: Request) async throws -> ClippingMarks? {
        idle?.cancel()
        idle = nil
        await takeTurn()
        defer {
            endTurn()
            releaseWhenIdle()
        }
        try Task.checkCancellation()
        guard SupportedFormats.isRaw(request.url), let engine = engineReady() else { return nil }
        let info: ImageInfo
        if let opened, opened.url == request.url {
            info = opened.info
        } else {
            opened = nil
            if !listed.contains(request.url) {
                sendList(first: request.url)
            }
            let started = ContinuousClock.now
            do {
                info = try await engine.open(request.url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return nil
            }
            statistics.opened += 1
            statistics.opening += .now - started
            opened = (request.url, info)
        }
        try Task.checkCancellation()
        let started = ContinuousClock.now
        let recipe = EditorModel.asShot(request.recipe, info)
        generation += 1
        var render = RenderRequest(
            recipe: recipe, targetSize: request.size, region: request.region, generation: generation,
        )
        render.showRawClipping = true
        render.comparison = recipe
        guard let frame = await frame(for: render, from: engine), frame.comparison != nil else { return nil }
        let region = request.region
        let found = await Task.detached(priority: .userInitiated) {
            frame.comparison
                .map { Self.marks(surface: frame.surface, comparison: $0, size: frame.size, region: region) }
        }.value
        guard var marks = found else { return nil }
        if region == nil {
            marks.histogram = frame.histogram
        }
        marks.photosites = info.diagnostics?.measurements.clippedShare
        statistics.rendered += 1
        statistics.rendering += .now - started
        return marks
    }

    /// Decodes `host`'s photos ahead, the one it shows first: the engine is given every host's photos, each host's
    /// shown photo before the rest, so Compare's two don't take each other off the engine's list.
    func prefetch(_ urls: [URL], for host: AnyObject) {
        let raws = urls.filter(SupportedFormats.isRaw)
        let id = ObjectIdentifier(host)
        if let index = wanted.firstIndex(where: { $0.host == id }) {
            wanted[index].urls = raws
        } else {
            wanted.append((id, raws))
        }
        sendList(first: nil)
    }

    /// `host` shows nothing now: its photos aren't decoded ahead any longer.
    func forget(_ host: AnyObject) {
        let id = ObjectIdentifier(host)
        wanted.removeAll { $0.host == id }
    }

    /// The hosts' photos, `first` before them, each host's shown photo before the photos around them.
    private func sendList(first: URL?) {
        var merged = first.map { [$0] } ?? []
        for url in wanted.compactMap(\.urls.first) + wanted.flatMap({ $0.urls.dropFirst() })
            where !merged.contains(url) {
            merged.append(url)
        }
        guard !merged.isEmpty, merged != listed, let engine = engineReady() else { return }
        listed = merged
        engine.prefetch(merged)
        releaseWhenIdle()
    }

    private func releaseWhenIdle() {
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(for: Self.idleRelease)
            guard !Task.isCancelled, let self, !busy else { return }
            release()
        }
    }

    /// Lets go of the engine and every photo it opened.
    func release() {
        idle?.cancel()
        idle = nil
        consumer?.cancel()
        consumer = nil
        for continuation in waiting.values {
            continuation.resume(returning: nil)
        }
        waiting = [:]
        opened = nil
        listed = []
        if let engine {
            Task { await engine.releaseResources() }
        }
        engine = nil
    }

    var hasEngine: Bool {
        engine != nil
    }

    // MARK: - The engine

    private func engineReady() -> (any ClippingEngine)? {
        if let engine {
            return engine
        }
        guard let made = makeEngine() else { return nil }
        engine = made
        let frames = made.frames()
        consumer = Task { [weak self] in
            for await frame in frames {
                guard let self else { return }
                waiting.removeValue(forKey: frame.generation)?.resume(returning: frame)
            }
        }
        return made
    }

    private func frame(for request: RenderRequest, from engine: any ClippingEngine) async -> RenderedFrame? {
        let generation = request.generation
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.frameTimeout)
            self?.waiting.removeValue(forKey: generation)?.resume(returning: nil)
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { continuation in
            waiting[generation] = continuation
            engine.render(request)
        }
    }

    private func takeTurn() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { turns.append($0) }
    }

    private func endTurn() {
        if turns.isEmpty {
            busy = false
        } else {
            turns.removeFirst().resume()
        }
    }

    // MARK: - Finding the marks

    /// Rows read at once: about 5 MB of working memory a buffer at 2,560 pixels across.
    private nonisolated static let bandRows = 128

    /// The marks in a frame rendered with sensor clipping: the pixels where it differs from its comparison whose
    /// channels are each exactly 0 or 1, as the engine paints them (`RawClipping.metal`), and never all three 1. A
    /// difference elsewhere, such as a heal's maps refreshed after the frame, isn't taken for a mark. Both `RGhA`.
    nonisolated static func marks(
        surface: IOSurfaceRef, comparison: IOSurfaceRef, size: PixelSize, region: ImageRect?,
    ) -> ClippingMarks {
        let (width, height) = (size.width, size.height)
        let none = ClippingMarks(image: nil, size: size, region: region, shares: .zero, allShare: 0)
        guard width > 0, height > 0, IOSurfaceGetWidth(surface) >= width, IOSurfaceGetHeight(surface) >= height,
              IOSurfaceGetWidth(comparison) >= width, IOSurfaceGetHeight(comparison) >= height else { return none }
        IOSurfaceLock(surface, .readOnly, nil)
        IOSurfaceLock(comparison, .readOnly, nil)
        defer {
            IOSurfaceUnlock(comparison, .readOnly, nil)
            IOSurfaceUnlock(surface, .readOnly, nil)
        }
        var band = MarkBand(width: width, rows: min(bandRows, height))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var top = 0
        while top < height {
            let rows = min(band.rows, height - top)
            guard band.read(surface, into: \.marked, top: top, rows: rows),
                  band.read(comparison, into: \.unmarked, top: top, rows: rows) else { return none }
            band.findMarks(count: rows * width)
            bytes.withUnsafeMutableBufferPointer { bytes in
                band.painted.withUnsafeBufferPointer { painted in
                    guard let target = bytes.baseAddress, let source = painted.baseAddress else { return }
                    vDSP_vfixu8(source, 1, target + top * width * 4, 1, vDSP_Length(rows * width * 4))
                }
            }
            top += rows
        }
        let counts = band.counts
        let pixels = Double(width * height)
        // Black marks are where all three channels clipped, which counts for each of them.
        let all = counts.marks - counts.coloured
        let shares = SIMD3(counts.red + all, counts.green + all, counts.blue + all) / pixels
        let image = counts.marks > 0 ? Self.image(bytes, width: width, height: height) : nil
        return ClippingMarks(image: image, size: size, region: region, shares: shares, allShare: all / pixels)
    }

    private nonisolated static func image(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent,
        )
    }
}

/// The working buffers `SensorClipping.marks` reads a band of rows into, and what it has counted so far.
private struct MarkBand {
    let width: Int
    let rows: Int
    var marked: [Float]
    var unmarked: [Float]
    /// Scratch: per channel, then per pixel.
    var scratch: [Float]
    var mask: [Float]
    var other: [Float]
    /// The marks' colours, alpha 1 on a mark and 0 elsewhere, 0 ... 255.
    var painted: [Float]
    var counts = (marks: 0.0, red: 0.0, green: 0.0, blue: 0.0, coloured: 0.0)

    init(width: Int, rows: Int) {
        self.width = width
        self.rows = rows
        let values = width * rows * 4
        marked = [Float](repeating: 0, count: values)
        unmarked = [Float](repeating: 0, count: values)
        scratch = [Float](repeating: 0, count: values)
        painted = [Float](repeating: 0, count: values)
        mask = [Float](repeating: 0, count: width * rows)
        other = [Float](repeating: 0, count: width * rows)
    }

    /// `rows` rows of the half-float surface from `top`, as floats.
    mutating func read(_ source: IOSurfaceRef, into buffer: WritableKeyPath<MarkBand, [Float]>, top: Int, rows: Int)
        -> Bool {
        let rowBytes = IOSurfaceGetBytesPerRow(source)
        let width = width
        var input = vImage_Buffer(
            data: IOSurfaceGetBaseAddress(source).advanced(by: top * rowBytes), height: vImagePixelCount(rows),
            width: vImagePixelCount(width * 4), rowBytes: rowBytes,
        )
        return self[keyPath: buffer].withUnsafeMutableBufferPointer { target in
            var output = vImage_Buffer(
                data: target.baseAddress, height: vImagePixelCount(rows), width: vImagePixelCount(width * 4),
                rowBytes: width * 16,
            )
            return vImageConvert_Planar16FtoPlanarF(&input, &output, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        }
    }

    /// Finds the marks among the band's first `count` pixels, paints them and counts them.
    mutating func findMarks(count: Int) {
        let length = vDSP_Length(count)
        let all = vDSP_Length(count * 4)
        var found = (marks: Float(0), red: Float(0), green: Float(0), blue: Float(0), coloured: Float(0))
        marked.withUnsafeBufferPointer { marked in
            unmarked.withUnsafeBufferPointer { unmarked in
                scratch.withUnsafeMutableBufferPointer { scratch in
                    mask.withUnsafeMutableBufferPointer { mask in
                        other.withUnsafeMutableBufferPointer { other in
                            painted.withUnsafeMutableBufferPointer { painted in
                                guard let a = marked.baseAddress, let b = unmarked.baseAddress,
                                      let d = scratch.baseAddress, let m = mask.baseAddress,
                                      let o = other.baseAddress, let p = painted.baseAddress else { return }
                                Self.mark(a, b, scratch: d, mask: m, other: o, length: length, all: all)
                                found = Self.paint(a, mask: m, into: p, coloured: o, length: length, all: all)
                            }
                        }
                    }
                }
            }
        }
        counts.marks += Double(found.marks)
        counts.red += Double(found.red)
        counts.green += Double(found.green)
        counts.blue += Double(found.blue)
        counts.coloured += Double(found.coloured)
    }

    /// `mask` 1 where `a` is a mark: it differs from `b`, each colour channel is 0 or 1, and they aren't all 1.
    private static func mark(
        _ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, scratch d: UnsafeMutablePointer<Float>,
        mask m: UnsafeMutablePointer<Float>, other o: UnsafeMutablePointer<Float>, length: vDSP_Length,
        all: vDSP_Length,
    ) {
        var (low, high, big, one) = (Float(0), Float(1), Float(1e12), Float(1))
        // Any difference in a colour channel.
        vDSP_vsub(b, 1, a, 1, d, 1, all)
        vDSP_vabs(d, 1, d, 1, all)
        vDSP_vadd(d, 4, d + 1, 4, m, 1, length)
        vDSP_vadd(m, 1, d + 2, 4, m, 1, length)
        vDSP_vsmul(m, 1, &big, m, 1, length)
        vDSP_vclip(m, 1, &low, &high, m, 1, length)
        // A channel that's neither 0 nor 1: |a (1 - a)| is 0 only there.
        var minusOne = Float(-1)
        vDSP_vsadd(a, 1, &minusOne, d, 1, all)
        vDSP_vmul(a, 1, d, 1, d, 1, all)
        vDSP_vabs(d, 1, d, 1, all)
        vDSP_vadd(d, 4, d + 1, 4, o, 1, length)
        vDSP_vadd(o, 1, d + 2, 4, o, 1, length)
        // White: the three channels add up to 3.
        vDSP_vadd(a, 4, a + 1, 4, d, 1, length)
        vDSP_vadd(d, 1, a + 2, 4, d, 1, length)
        var minusTwoAndAHalf = Float(-2.5)
        vDSP_vsadd(d, 1, &minusTwoAndAHalf, d, 1, length)
        vDSP_vclip(d, 1, &low, &high, d, 1, length)
        vDSP_vadd(o, 1, d, 1, o, 1, length)
        vDSP_vsmul(o, 1, &big, o, 1, length)
        vDSP_vclip(o, 1, &low, &high, o, 1, length)
        // mask × (1 − not a mark colour)
        vDSP_vneg(o, 1, o, 1, length)
        vDSP_vsadd(o, 1, &one, o, 1, length)
        vDSP_vmul(m, 1, o, 1, m, 1, length)
    }

    /// The marks' colours into `p`, 0 ... 255, and what they count: marks, each channel's, and those with a colour
    /// (the rest being black). `coloured` is scratch, a value a pixel.
    private static func paint(
        _ a: UnsafePointer<Float>, mask m: UnsafePointer<Float>, into p: UnsafeMutablePointer<Float>,
        coloured c: UnsafeMutablePointer<Float>, length: vDSP_Length, all: vDSP_Length,
    ) -> (marks: Float, red: Float, green: Float, blue: Float, coloured: Float) {
        var (low, high, scale, none) = (Float(0), Float(1), Float(255), Float(0))
        for channel in 0 ..< 3 {
            vDSP_vmul(a + channel, 4, m, 1, p + channel, 4, length)
        }
        vDSP_vsadd(m, 1, &none, p + 3, 4, length)
        vDSP_vclip(p, 1, &low, &high, p, 1, all)
        var sums = [Float](repeating: 0, count: 5)
        vDSP_sve(m, 1, &sums[0], length)
        for channel in 0 ..< 3 {
            vDSP_sve(p + channel, 4, &sums[channel + 1], length)
        }
        vDSP_vmax(p, 4, p + 1, 4, c, 1, length)
        vDSP_vmax(c, 1, p + 2, 4, c, 1, length)
        vDSP_sve(c, 1, &sums[4], length)
        vDSP_vsmul(p, 1, &scale, p, 1, all)
        return (sums[0], sums[1], sums[2], sums[3], sums[4])
    }
}
