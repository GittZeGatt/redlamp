import CoreGraphics
import Foundation
import ImageIO
import RedlampEngineAPI

/// A photo's largest embedded preview (LIB-42), the image soft frames are measured on: for a raw the largest JPEG it
/// embeds, found as the import finds previews (`EmbeddedPreviews`) and in a CR3 the full-size JPEG of its first
/// track; for any other file the image itself. Its decode is left until a region is drawn, so measuring around an AF
/// point decodes about a third of what the whole preview takes. A raw whose largest JPEG can't be found that way is
/// read through ImageIO's own preview, decoded whole, and never developed. The image is immutable, so it's handed to
/// the scheduler's lane to be drawn.
struct LargestPreview: @unchecked Sendable {
    let image: CGImage
    var width: Int {
        image.width
    }

    var height: Int {
        image.height
    }

    /// The scale the image was decoded at, for the grid: 1, or JPEG's 1/2, 1/4 or 1/8.
    let subsampled: Int

    /// Previews shorter than this on their long edge aren't measured: a thumbnail's detail says little of focus.
    static let smallestEdge = 1280

    /// `url`'s largest preview, decoded at full size when it's drawn; with `longEdge`, decoded at the JPEG scale that
    /// keeps it at least that long, for the grid. Nil when the file has none of `smallestEdge` or more.
    static func open(_ url: URL, longEdge: Int? = nil) async -> LargestPreview? {
        if SupportedFormats.isRaw(url) {
            guard let file = try? NSData(contentsOf: url, options: .alwaysMapped) else { return nil }
            if let jpeg = await largestJPEG(in: file), let preview = open(jpeg, longEdge: longEdge) {
                return preview
            }
            return embeddedByImageIO(Data(referencing: file))
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return open(source, longEdge: longEdge)
    }

    /// The JPEG or other image `data` holds.
    static func open(_ data: Data, longEdge: Int? = nil) -> LargestPreview? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary,
        )
        else { return nil }
        return open(source, longEdge: longEdge)
    }

    private static func open(_ source: CGImageSource, longEdge: Int?) -> LargestPreview? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              max(width, height) >= smallestEdge else { return nil }
        var factor = 1
        if let longEdge, CGImageSourceGetType(source) as String? == "public.jpeg" {
            while factor < 8, max(width, height) / (factor * 2) >= longEdge {
                factor *= 2
            }
        }
        var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if factor > 1 {
            options[kCGImageSourceSubsampleFactor] = factor
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else { return nil }
        return LargestPreview(image: image, subsampled: max(1, width / max(image.width, 1)))
    }

    /// The preview ImageIO finds in a raw, decoded whole: without `kCGImageSourceCreateThumbnailFromImageIfAbsent`
    /// it never develops the raw, which takes it seconds.
    private static func embeddedByImageIO(_ data: Data) -> LargestPreview? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary,
        ),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceCreateThumbnailWithTransform: false,
            ] as CFDictionary), max(image.width, image.height) >= smallestEdge
        else { return nil }
        return LargestPreview(image: image, subsampled: 1)
    }

    /// The brightness of `rect`, in the preview's pixels, at full size.
    func region(_ rect: CGRect) -> GreyPlane? {
        image.cropping(to: rect.integral).flatMap { GreyPlane($0) }
    }

    /// The whole preview's brightness, at most `longEdge` on its long edge.
    func whole(longEdge: Int) -> GreyPlane? {
        let scale = min(1, Double(longEdge) / Double(max(width, height)))
        return GreyPlane(
            image, width: max(1, Int((Double(width) * scale).rounded())),
            height: max(1, Int((Double(height) * scale).rounded())),
        )
    }

    // MARK: - Finding the JPEG

    /// The largest JPEG `file` embeds, its bytes left where they are in the mapping, which they keep for as long as
    /// ImageIO holds them.
    static func largestJPEG(in file: NSData) async -> Data? {
        let data = Data(
            bytesNoCopy: UnsafeMutableRawPointer(mutating: file.bytes),
            count: file.length,
            deallocator: .none,
        )
        // The mapping is the head, so the search reads straight through it and never fetches.
        var bytes = PreviewBytes(head: data, size: data.count) { _ in Data() }
        var found: [EmbeddedJPEG] = cr3FullSizeJPEG(in: data).map { [EmbeddedJPEG(
            offset: $0.lowerBound,
            length: $0.count,
        )] } ?? []
        found += await (try? EmbeddedPreviews.find(in: &bytes)) ?? []
        var largest: (range: Range<Int>, pixels: Int)?
        for preview in found {
            guard let (width, height) = try? await EmbeddedPreviews.frameSize(of: preview, in: &bytes),
                  width * height > largest?.pixels ?? 0 else { continue }
            largest = (preview.range, width * height)
        }
        guard let range = largest?.range, range.lowerBound >= 0, range.upperBound <= file.length else { return nil }
        return Data(
            bytesNoCopy: UnsafeMutableRawPointer(mutating: file.bytes + range.lowerBound), count: range.count,
            deallocator: .custom { _, _ in withExtendedLifetime(file) {} },
        )
    }

    /// A CR3's full-size JPEG: the one sample of its first track, where `moov`'s first `trak` has its chunk offset
    /// (`co64`) and size (`stsz`). Canon's HDR PQ frames keep HEIF there instead, which isn't a JPEG.
    static func cr3FullSizeJPEG(in data: Data) -> Range<Int>? {
        guard data.count > 12, data[4 ..< 8].elementsEqual("ftyp".utf8),
              let moov = boxes(in: data, 0 ..< data.count).first(where: { $0.type == "moov" }),
              let trak = boxes(in: data, moov.content).first(where: { $0.type == "trak" }),
              let mdia = boxes(in: data, trak.content).first(where: { $0.type == "mdia" }),
              let minf = boxes(in: data, mdia.content).first(where: { $0.type == "minf" }),
              let stbl = boxes(in: data, minf.content).first(where: { $0.type == "stbl" }) else { return nil }
        let table = boxes(in: data, stbl.content)
        guard let stsz = table.first(where: { $0.type == "stsz" }), stsz.content.count >= 12 else { return nil }
        var size = bigEndian(data, stsz.content.lowerBound + 4, 4)
        if size == 0, stsz.content.count >= 16 {
            size = bigEndian(data, stsz.content.lowerBound + 12, 4)
        }
        let offset: Int
        if let co64 = table.first(where: { $0.type == "co64" }), co64.content.count >= 16 {
            offset = bigEndian(data, co64.content.lowerBound + 8, 8)
        } else if let stco = table.first(where: { $0.type == "stco" }), stco.content.count >= 12 {
            offset = bigEndian(data, stco.content.lowerBound + 8, 4)
        } else {
            return nil
        }
        guard size > 0, offset > 0, offset <= data.count - size else { return nil }
        return offset ..< offset + size
    }

    /// The boxes of an ISO base media file laid end to end in `range`, at most 64 of them.
    private static func boxes(in data: Data, _ range: Range<Int>) -> [(type: String, content: Range<Int>)] {
        var found: [(type: String, content: Range<Int>)] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound, found.count < 64 {
            var size = bigEndian(data, offset, 4)
            var header = 8
            if size == 1, offset + 16 <= range.upperBound {
                size = bigEndian(data, offset + 8, 8)
                header = 16
            } else if size == 0 {
                size = range.upperBound - offset
            }
            guard size >= header, size <= range.upperBound - offset else { break }
            let type = String(decoding: data[offset + 4 ..< offset + 8], as: UTF8.self)
            found.append((type, offset + header ..< offset + size))
            offset += size
        }
        return found
    }

    private static func bigEndian(_ data: Data, _ offset: Int, _ length: Int) -> Int {
        guard offset >= 0, offset + length <= data.count else { return 0 }
        return (0 ..< length).reduce(0) { $0 << 8 | Int(data[data.startIndex + offset + $1]) }
    }
}
