import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Bursts with frames known to be sharp or soft (LIB-42), for the soft-frame measure's tests and its regression
/// scenario until it's tuned on shoots the owner has culled (DEC-61). Each frame is one scene of shapes and fine
/// texture, a subject at the AF point and a background around it, drawn as a camera would record it: moved by a pixel
/// or two from frame to frame, a little noise, and written as a JPEG whose EXIF gives its camera, its capture time to
/// the millisecond, its exposure and its AF point (SubjectArea, as the iPhone writes it).
public enum SoftFrameSamples {
    /// A frame of a burst.
    public enum Frame: Sendable, Hashable {
        /// Sharp, the scene moved `shift` pixels across, as a burst's frames move.
        case sharp(shift: Int)
        /// A third of a stop brighter, and sharp.
        case brighter
        /// Out of focus: a Gaussian blur of `sigma` pixels over the whole frame.
        case blurred(sigma: Double)
        /// The camera's shake or the subject's movement: `length` pixels across.
        case motion(length: Int)
        /// Focused behind the subject: the background sharp and the subject blurred by 2.5 pixels.
        case focusMissed

        /// Whether the measure should find it soft against a sharp frame of its burst.
        public var isSoft: Bool {
            switch self {
            case .sharp, .brighter: false
            case .blurred, .motion, .focusMissed: true
            }
        }

        /// A number of its own, which seeds its noise the same way in every run.
        var code: UInt64 {
            switch self {
            case let .sharp(shift): UInt64(truncatingIfNeeded: 1 + shift)
            case .brighter: 101
            case let .blurred(sigma): 201 + UInt64(max(0, sigma * 10).rounded())
            case let .motion(length): 301 + UInt64(max(0, length))
            case .focusMissed: 401
            }
        }
    }

    /// The size frames are drawn at: a preview the measure reads (`LargestPreview.smallestEdge`).
    public static let width = 1600
    public static let height = 1066
    /// The subject's centre and the AF area around it, as fractions of the frame.
    public static let subject = CGRect(x: 0.52, y: 0.3, width: 0.16, height: 0.24)

    /// `frame` of the scene `seed` draws, as pixels: RGBA, row after row from the top.
    static func pixels(_ frame: Frame, seed: UInt64, width: Int = width, height: Int = height) -> [UInt8] {
        let shift = if case let .sharp(shift) = frame {
            shift
        } else {
            0
        }
        var pixels = scene(seed: seed, shift: shift, width: width, height: height)
        switch frame {
        case .sharp:
            break
        case .brighter:
            for index in pixels.indices where index % 4 != 3 {
                pixels[index] = UInt8(min(255, Double(pixels[index]) * 1.26))
            }
        case let .blurred(sigma):
            pixels = gaussian(pixels, sigma: sigma, width: width, height: height)
        case let .motion(length):
            pixels = convolve(pixels, [Int16](repeating: 1, count: max(1, length)), horizontal: true, width, height)
        case .focusMissed:
            let blurred = gaussian(pixels, sigma: 2.5, width: width, height: height)
            let area = subjectRect(width: width, height: height)
            for y in Int(area.minY) ..< Int(area.maxY) {
                let start = (y * width + Int(area.minX)) * 4
                let end = (y * width + Int(area.maxX)) * 4
                pixels.replaceSubrange(start ..< end, with: blurred[start ..< end])
            }
        }
        addNoise(&pixels, seed: seed &+ frame.code)
        return pixels
    }

    /// `frame` as an image.
    public static func image(_ frame: Frame, seed: UInt64, width: Int = width, height: Int = height) -> CGImage? {
        let data = Data(pixels(frame, seed: seed, width: width, height: height))
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.noneSkipLast.rawValue,
            ), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent,
        )
    }

    /// Writes `frames` as a burst of JPEGs in `folder`, `name` followed by 1, 2… (`B_0001.JPG`), the first captured
    /// at `start` and each `interval` seconds after the one before, from one camera; returns their files in order.
    @discardableResult
    public static func writeBurst(
        _ frames: [Frame], to folder: URL, name: String, start: Date, interval: TimeInterval = 0.1, seed: UInt64 = 1,
        camera: (make: String, model: String) = ("Redlamp", "Test Body"),
    ) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (index, frame) in frames.enumerated() {
            let url = folder.appending(path: String(format: "%@%04d.JPG", name, index + 1))
            let captured = start.addingTimeInterval(Double(index) * interval)
            try write(frame, to: url, captured: captured, seed: seed, camera: camera)
            urls.append(url)
        }
        return urls
    }

    /// Writes one frame as a JPEG.
    public static func write(
        _ frame: Frame, to url: URL, captured: Date, seed: UInt64, camera: (make: String, model: String),
    ) throws {
        guard let image = image(frame, seed: seed),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  UTType.jpeg.identifier as CFString,
                  1,
                  nil,
              )
        else { throw CocoaError(.fileWriteUnknown) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let milliseconds = Int((captured.timeIntervalSince1970 * 1000).rounded()) % 1000
        let area = subjectRect(width: width, height: height)
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.92,
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: camera.make, kCGImagePropertyTIFFModel: camera.model,
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: formatter.string(from: captured),
                kCGImagePropertyExifSubsecTimeOriginal: String(format: "%03d", milliseconds),
                kCGImagePropertyExifOffsetTimeOriginal: "+00:00",
                kCGImagePropertyExifExposureTime: 1.0 / 500,
                kCGImagePropertyExifFNumber: 4.0,
                kCGImagePropertyExifISOSpeedRatings: [400],
                kCGImagePropertyExifFocalLength: 50.0,
                kCGImagePropertyExifSubjectArea: [
                    Int(area.midX), Int(area.midY), Int(area.width), Int(area.height),
                ],
            ],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// The subject's area in a frame `width` by `height`, in pixels.
    static func subjectRect(width: Int, height: Int) -> CGRect {
        CGRect(
            x: (subject.minX * Double(width)).rounded(), y: (subject.minY * Double(height)).rounded(),
            width: (subject.width * Double(width)).rounded(), height: (subject.height * Double(height)).rounded(),
        )
    }

    // MARK: - Drawing

    /// The scene: a background of soft and hard-edged shapes at many sizes, and a subject of fine stripes and dots at
    /// the AF point, all moved `shift` pixels to the right.
    private static func scene(seed: UInt64, shift: Int, width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var random = Random(seed: seed)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
            ) else { return }
            // Drawn from the top, as the pixels are read.
            context.translateBy(x: Double(shift), y: Double(height))
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(red: 0.45, green: 0.5, blue: 0.55, alpha: 1)
            context.fill(CGRect(x: -Double(shift), y: 0, width: Double(width + 2 * abs(shift)), height: Double(height)))
            for _ in 0 ..< 700 {
                let size = 4 + 120 * pow(random.unit(), 3)
                let rect = CGRect(
                    x: random.unit() * Double(width), y: random.unit() * Double(height), width: size,
                    height: size * (0.4 + random.unit()),
                )
                context.setFillColor(red: random.unit(), green: random.unit(), blue: random.unit(), alpha: 1)
                if random.unit() < 0.5 {
                    context.fillEllipse(in: rect)
                } else {
                    context.fill(rect)
                }
            }
            let area = subjectRect(width: width, height: height)
            context.setFillColor(red: 0.9, green: 0.85, blue: 0.7, alpha: 1)
            context.fill(area)
            context.setFillColor(red: 0.1, green: 0.12, blue: 0.15, alpha: 1)
            var x = area.minX
            while x < area.maxX {
                context.fill(CGRect(x: x, y: area.minY, width: 1.5, height: area.height / 2))
                x += 3 + 3 * random.unit()
            }
            for _ in 0 ..< 600 {
                let dot = CGRect(
                    x: area.minX + random.unit() * area.width, y: area.midY + random.unit() * area.height / 2,
                    width: 2, height: 2,
                )
                context.setFillColor(gray: random.unit(), alpha: 1)
                context.fillEllipse(in: dot)
            }
        }
        return pixels
    }

    private static func gaussian(_ pixels: [UInt8], sigma: Double, width: Int, height: Int) -> [UInt8] {
        let radius = max(1, Int((3 * sigma).rounded(.up)))
        let kernel = (-radius ... radius).map { offset in
            Int16((1000 * exp(-Double(offset * offset) / (2 * sigma * sigma))).rounded())
        }
        let across = convolve(pixels, kernel, horizontal: true, width, height)
        return convolve(across, kernel, horizontal: false, width, height)
    }

    private static func convolve(
        _ pixels: [UInt8], _ kernel: [Int16], horizontal: Bool, _ width: Int, _ height: Int,
    ) -> [UInt8] {
        var source = pixels
        var result = [UInt8](repeating: 0, count: pixels.count)
        let divisor = Int32(kernel.reduce(0) { $0 + Int($1) })
        source.withUnsafeMutableBytes { input in
            result.withUnsafeMutableBytes { output in
                var from = vImage_Buffer(
                    data: input.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                    rowBytes: width * 4,
                )
                var to = vImage_Buffer(
                    data: output.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                    rowBytes: width * 4,
                )
                _ = vImageConvolve_ARGB8888(
                    &from, &to, nil, 0, 0, kernel, horizontal ? 1 : UInt32(kernel.count),
                    horizontal ? UInt32(kernel.count) : 1, divisor, nil, vImage_Flags(kvImageEdgeExtend),
                )
            }
        }
        return result
    }

    /// A sensor's noise and a JPEG's rounding: up to two levels either way.
    private static func addNoise(_ pixels: inout [UInt8], seed: UInt64) {
        var random = Random(seed: seed)
        for index in pixels.indices where index % 4 != 3 {
            let value = Int(pixels[index]) + Int(random.next() % 5) - 2
            pixels[index] = UInt8(clamping: value)
        }
    }

    /// A small generator, so a seed always draws the same scene.
    private struct Random {
        var state: UInt64

        init(seed: UInt64) {
            state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        }

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }

        mutating func unit() -> Double {
            Double(next() % 1_000_000) / 1_000_000
        }
    }
}
