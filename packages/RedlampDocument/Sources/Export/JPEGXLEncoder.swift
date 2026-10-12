import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import LibJXL

/// Encodes JPEG XL, which ImageIO reads but doesn't write, with libjxl (`scripts/vendor-libjxl.sh`).
enum JPEGXLEncoder {
    /// libjxl's default, its balance of encoding time and file size (1 to 10).
    static let effort: Int64 = 7

    /// `image` as a file of `settings`' format, at `quality` (ImageIO's 0 to 1) unless lossless, with
    /// the Exif and XMP ImageIO would write from `properties` in boxes ahead of it. Like ImageIO, it
    /// keeps the image's own bit depth: 16 bits for one deeper than 8.
    static func encode(
        _ image: CGImage,
        settings: ExportSettings,
        quality: Double,
        properties: [CFString: Any],
    ) throws -> Data {
        let format = settings.format
        let wide = image.bitsPerComponent > 8
        guard let metadata = metadata(properties, like: image),
              let pixels = rgb(image, wide: wide),
              let encoder = JxlEncoderCreate(nil)
        else { throw ExportError.cannotEncode(format) }
        defer { JxlEncoderDestroy(encoder) }
        func check(_ status: JxlEncoderStatus) throws {
            guard status == JXL_ENC_SUCCESS else { throw ExportError.cannotEncode(format) }
        }
        let runner = JxlThreadParallelRunnerCreate(nil, JxlThreadParallelRunnerDefaultNumWorkerThreads())
        defer {
            if let runner {
                JxlThreadParallelRunnerDestroy(runner)
            }
        }
        if let runner {
            try check(JxlEncoderSetParallelRunner(encoder, JxlThreadParallelRunner, runner))
        }

        var info = JxlBasicInfo()
        JxlEncoderInitBasicInfo(&info)
        info.xsize = UInt32(image.width)
        info.ysize = UInt32(image.height)
        info.bits_per_sample = wide ? 16 : 8
        info.uses_original_profile = format.isLossless ? JXL_TRUE : JXL_FALSE
        try check(JxlEncoderSetBasicInfo(encoder, &info))
        try check(setColorEncoding(of: image, on: encoder))

        try check(JxlEncoderUseBoxes(encoder))
        // The Exif box starts with the TIFF header's offset from the end of these four bytes.
        try check(addBox("Exif", Data(count: 4) + metadata.exif, to: encoder))
        if let xmp = metadata.xmp {
            try check(addBox("xml ", xmp, to: encoder))
        }

        guard let frame = JxlEncoderFrameSettingsCreate(encoder, nil) else { throw ExportError.cannotEncode(format) }
        try check(JxlEncoderFrameSettingsSetOption(frame, JXL_ENC_FRAME_SETTING_EFFORT, effort))
        if format.isLossless {
            try check(JxlEncoderSetFrameLossless(frame, JXL_TRUE))
        } else {
            try check(JxlEncoderSetFrameDistance(frame, JxlEncoderDistanceFromQuality(Float(quality * 100))))
        }
        var pixelFormat = JxlPixelFormat(
            num_channels: 3, data_type: wide ? JXL_TYPE_UINT16 : JXL_TYPE_UINT8, endianness: JXL_LITTLE_ENDIAN,
            align: 0,
        )
        try pixels.withUnsafeBytes { try check(JxlEncoderAddImageFrame(frame, &pixelFormat, $0.baseAddress, $0.count)) }
        JxlEncoderCloseInput(encoder)
        return try output(of: encoder, format: format)
    }

    /// The Exif and XMP of `properties`, as ImageIO writes them into a PNG: its eXIf chunk holds Exif
    /// as JPEG XL's Exif box does, and its XMP carries the IPTC fields JPEG XL has no box for.
    /// ImageIO reads them back from a JPEG XL file as it does from the PNG. Nil if the PNG can't be
    /// written or has no Exif.
    static func metadata(_ properties: [CFString: Any], like image: CGImage) -> (exif: Data, xmp: Data?)? {
        let png = NSMutableData()
        guard let pixel = EmbeddedEdit.pixel(like: image),
              let destination = CGImageDestinationCreateWithData(
                  png as CFMutableData, ExportFormat.png.typeIdentifier as CFString, 1, nil,
              )
        else { return nil }
        ExportMetadata.addImage(pixel, to: destination, properties: properties, format: .png)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let found = chunks(of: [UInt8](png as Data))
        return found.exif.map { ($0, found.xmp) }
    }

    /// The eXIf chunk and the uncompressed XMP iTXt chunk of a PNG.
    private static func chunks(of png: [UInt8]) -> (exif: Data?, xmp: Data?) {
        var exif: Data?
        var xmp: Data?
        var offset = 8
        while offset + 12 <= png.count {
            let length = png[offset ..< offset + 4].reduce(0) { $0 << 8 | Int($1) }
            let type = String(decoding: png[offset + 4 ..< offset + 8], as: UTF8.self)
            let body = offset + 8 ..< offset + 8 + length
            guard body.upperBound + 4 <= png.count else { break }
            if type == "eXIf" {
                exif = Data(png[body])
            } else if type == "iTXt" {
                xmp = xmp ?? text(of: png[body], keyword: "XML:com.adobe.xmp")
            }
            offset = body.upperBound + 4
        }
        return (exif, xmp)
    }

    /// The text of an uncompressed iTXt chunk with `keyword`: after the keyword, the compression flag
    /// and method, and the language tag and translated keyword, each ending in a zero byte.
    private static func text(of chunk: ArraySlice<UInt8>, keyword: String) -> Data? {
        guard let keywordEnd = chunk.firstIndex(of: 0),
              String(decoding: chunk[..<keywordEnd], as: UTF8.self) == keyword,
              keywordEnd + 2 < chunk.endIndex, chunk[keywordEnd + 1] == 0,
              let languageEnd = chunk[(keywordEnd + 3)...].firstIndex(of: 0),
              let translatedEnd = chunk[(languageEnd + 1)...].firstIndex(of: 0)
        else { return nil }
        return Data(chunk[(translatedEnd + 1)...])
    }

    /// `image`'s pixels in its own colour space, packed as RGB of 8 or 16 bits (little-endian).
    private static func rgb(_ image: CGImage, wide: Bool) -> Data? {
        let width = image.width
        let height = image.height
        let bytes = wide ? 2 : 1
        guard let space = image.colorSpace, space.model == .rgb else { return nil }
        var rgbx = Data(count: width * height * 4 * bytes)
        let drawn = rgbx.withUnsafeMutableBytes { buffer -> Bool in
            let info = CGImageAlphaInfo.noneSkipLast.rawValue | (wide ? CGImageByteOrderInfo.order16Little.rawValue : 0)
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8 * bytes,
                bytesPerRow: width * 4 * bytes, space: space, bitmapInfo: info,
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var rgb = Data(count: width * height * 3 * bytes)
        let error = rgbx.withUnsafeMutableBytes { source in
            rgb.withUnsafeMutableBytes { destination in
                var from = vImage_Buffer(
                    data: source.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                    rowBytes: width * 4 * bytes,
                )
                var to = vImage_Buffer(
                    data: destination.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                    rowBytes: width * 3 * bytes,
                )
                let flags = vImage_Flags(kvImageNoFlags)
                return wide
                    ? vImageConvert_RGBA16UtoRGB16U(&from, &to, flags)
                    : vImageConvert_RGBA8888toRGB888(&from, &to, flags)
            }
        }
        return error == kvImageNoError ? rgb : nil
    }

    /// JPEG XL's own description of sRGB and Display P3, the spaces Redlamp renders exports in, which
    /// needs no ICC profile; any other space's profile.
    private static func setColorEncoding(of image: CGImage, on encoder: OpaquePointer) -> JxlEncoderStatus {
        var color = JxlColorEncoding()
        JxlColorEncodingSetToSRGB(&color, JXL_FALSE)
        let name = image.colorSpace?.name as String?
        if name == CGColorSpace.displayP3 as String {
            color.primaries = JXL_PRIMARIES_P3
        } else if name != CGColorSpace.sRGB as String {
            guard let profile = image.colorSpace?.copyICCData() as Data? else { return JXL_ENC_ERROR }
            return profile.withUnsafeBytes {
                JxlEncoderSetICCProfile(encoder, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
            }
        }
        return JxlEncoderSetColorEncoding(encoder, &color)
    }

    private static func addBox(_ type: String, _ contents: Data, to encoder: OpaquePointer) -> JxlEncoderStatus {
        contents.withUnsafeBytes {
            JxlEncoderAddBox(encoder, type, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, JXL_FALSE)
        }
    }

    private static func output(of encoder: OpaquePointer, format: ExportFormat) throws -> Data {
        var file = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 20)
        var status = JXL_ENC_NEED_MORE_OUTPUT
        while status == JXL_ENC_NEED_MORE_OUTPUT {
            chunk.withUnsafeMutableBufferPointer { buffer in
                var next = buffer.baseAddress
                var available = buffer.count
                status = JxlEncoderProcessOutput(encoder, &next, &available)
                file.append(buffer.baseAddress!, count: buffer.count - available)
            }
        }
        guard status == JXL_ENC_SUCCESS else { throw ExportError.cannotEncode(format) }
        return file
    }
}
