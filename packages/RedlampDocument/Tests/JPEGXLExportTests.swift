import CoreGraphics
import Foundation
import ImageIO
import RedlampDocument
import Testing

/// JPEG XL, written by libjxl and read back through ImageIO as other apps read it.
struct JPEGXLExportTests {
    static let spaces = [CGColorSpace.sRGB as String, CGColorSpace.displayP3 as String]

    private static func settings(_ format: ExportFormat, bits: Int, quality: Int = 90) -> ExportSettings {
        var settings = ExportSettings()
        settings.setFormat(format)
        settings.bitDepth = bits
        settings.quality = quality
        return settings
    }

    /// Smooth gradients over the whole range, whose 16-bit values an 8-bit file couldn't hold.
    private static func gradient(bits: Int, space: String, width: Int = 256, height: Int = 192) -> CGImage {
        let maximum = bits == 16 ? 65535 : 255
        var data = Data(count: width * height * 4 * bits / 8)
        data.withUnsafeMutableBytes { raw in
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let rgb = [
                        x * maximum / (width - 1), y * maximum / (height - 1),
                        (x + y) * maximum / (width + height - 2), maximum,
                    ]
                    for channel in 0 ..< 4 {
                        let index = (y * width + x) * 4 + channel
                        if bits == 16 {
                            raw.storeBytes(of: UInt16(rgb[channel]), toByteOffset: index * 2, as: UInt16.self)
                        } else {
                            raw.storeBytes(of: UInt8(rgb[channel]), toByteOffset: index, as: UInt8.self)
                        }
                    }
                }
            }
        }
        let info = CGImageAlphaInfo.noneSkipLast
            .rawValue | (bits == 16 ? CGImageByteOrderInfo.order16Little.rawValue : 0)
        return CGImage(
            width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits * 4,
            bytesPerRow: width * bits / 2, space: CGColorSpace(name: space as CFString)!,
            bitmapInfo: CGBitmapInfo(rawValue: info), provider: CGDataProvider(data: data as CFData)!,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent,
        )!
    }

    private static func decoded(_ data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.jpeg-xl")
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// `image`'s pixels as 16-bit RGBX in its own colour space, so nothing is converted on the way.
    private static func pixels(_ image: CGImage) throws -> [UInt16] {
        var pixels = [UInt16](repeating: 0, count: image.width * image.height * 4)
        let space = try #require(image.colorSpace)
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 16,
                bytesPerRow: image.width * 8, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGImageByteOrderInfo.order16Little.rawValue,
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return context != nil
        }
        #expect(drawn)
        return pixels.enumerated().filter { $0.offset % 4 != 3 }.map(\.element)
    }

    @Test(arguments: [8, 16], spaces)
    func `lossless JPEG XL keeps every pixel, in the render's colour space`(bits: Int, space: String) throws {
        let image = Self.gradient(bits: bits, space: space)
        let data = try ImageExporter.encode(image, settings: Self.settings(.jxlLossless, bits: bits))
        let read = try Self.decoded(data)
        #expect(read.bitsPerComponent == bits)
        #expect(read.colorSpace?.name as String? == space)
        #expect(try Self.pixels(read) == Self.pixels(image))
    }

    @Test(arguments: [8, 16], spaces)
    func `lossy JPEG XL stays close to the render, in its colour space`(bits: Int, space: String) throws {
        let image = Self.gradient(bits: bits, space: space)
        let data = try ImageExporter.encode(image, settings: Self.settings(.jxl, bits: bits))
        let read = try Self.decoded(data)
        #expect(read.bitsPerComponent == bits)
        #expect(read.colorSpace?.name as String? == space)
        let differences = try zip(Self.pixels(read), Self.pixels(image)).map { abs(Int($0) - Int($1)) }
        let mean = Double(differences.reduce(0, +)) / Double(differences.count) / 257
        #expect(mean < 3, "mean difference \(mean) of 255")
    }

    @Test func `quality 100 stays lossy`() throws {
        let image = Self.gradient(bits: 16, space: CGColorSpace.sRGB as String)
        let data = try ImageExporter.encode(image, settings: Self.settings(.jxl, bits: 16, quality: 100))
        #expect(try Self.pixels(Self.decoded(data)) != Self.pixels(image))
    }

    @Test(arguments: [ExportFormat.jxl, .jxlLossless])
    func `the Exif and XMP come ahead of the image`(format: ExportFormat) throws {
        let data = try ImageExporter.encode(ExportWriterTests.image(), settings: Self.settings(format, bits: 8))
        let bytes = [UInt8](data)
        var boxes: [String] = []
        var offset = 0
        while offset + 8 <= bytes.count {
            let size = bytes[offset ..< offset + 4].reduce(0) { $0 << 8 | Int($1) }
            boxes.append(String(decoding: bytes[offset + 4 ..< offset + 8], as: UTF8.self))
            guard size >= 8 else { break }
            offset += size
        }
        #expect(boxes.first == "JXL ")
        let frame = try #require(boxes.lastIndex { $0 == "jxlc" || $0 == "jxlp" })
        let exif = try #require(boxes.firstIndex(of: "Exif"))
        let xmp = try #require(boxes.firstIndex(of: "xml "))
        #expect(exif < frame && xmp < frame, "\(boxes)")
    }

    @Test func `a JPEG XL export is known as one, so the next export replaces it`() throws {
        let (folder, cleanup) = try ExportWriterTests.temporaryFolder()
        defer { cleanup() }
        let url = folder.appending(path: "IMG_0001-redlamp.jxl")
        let settings = Self.settings(.jxl, bits: 8)
        try ImageExporter.write(ExportWriterTests.image(), to: url, settings: settings, reading: ImageIOFiles())
        #expect(ExportMetadata.isExport(url, reading: ImageIOFiles()))
        try ImageExporter.write(ExportWriterTests.image(), to: url, settings: settings, reading: ImageIOFiles())
    }
}
