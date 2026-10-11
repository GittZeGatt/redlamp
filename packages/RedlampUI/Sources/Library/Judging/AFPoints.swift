import CoreGraphics
import Foundation

/// Where the camera focused, as it recorded it in the file's maker notes or EXIF (LIB-38). Areas are in the photo as
/// the camera framed it, before its orientation turns it upright, 0 ... 1 across and down; a camera that records a
/// point without a size gives an area of no size.
struct AFPoints: Sendable, Equatable {
    struct Area: Sendable, Equatable {
        var rect: CGRect
        /// Whether the camera focused there; false for an area chosen where it didn't (Canon records both).
        var inFocus: Bool
    }

    /// Which reading found the areas, for the tests and the activity log.
    enum Source: String, Sendable {
        case canon, nikon, sony, fujifilm, panasonic, subjectArea
    }

    var areas: [Area]
    /// The file's EXIF orientation, 1 to 8.
    var orientation: Int
    var source: Source

    /// The areas in the photo as it's shown upright.
    var upright: [Area] {
        areas.map { area in
            let corners = [
                CGPoint(x: area.rect.minX, y: area.rect.minY), CGPoint(x: area.rect.maxX, y: area.rect.maxY),
            ].map { Self.oriented($0, orientation) }
            let rect = CGRect(
                x: min(corners[0].x, corners[1].x), y: min(corners[0].y, corners[1].y),
                width: abs(corners[0].x - corners[1].x), height: abs(corners[0].y - corners[1].y),
            )
            return Area(rect: rect, inFocus: area.inFocus)
        }
    }

    /// Where a point of the stored photo lands once EXIF orientation `orientation` turns it, both 0 ... 1.
    static func oriented(_ point: CGPoint, _ orientation: Int) -> CGPoint {
        let (x, y) = (point.x, point.y)
        switch orientation {
        case 2: return CGPoint(x: 1 - x, y: y)
        case 3: return CGPoint(x: 1 - x, y: 1 - y)
        case 4: return CGPoint(x: x, y: 1 - y)
        case 5: return CGPoint(x: y, y: x)
        case 6: return CGPoint(x: 1 - y, y: x)
        case 7: return CGPoint(x: 1 - y, y: 1 - x)
        case 8: return CGPoint(x: y, y: 1 - x)
        default: return point
        }
    }

    /// Whether orientation `orientation` turns the photo a quarter, so its width becomes its height.
    static func swapsAxes(_ orientation: Int) -> Bool {
        (5 ... 8).contains(orientation)
    }
}

/// Reads the AF point a raw file records (LIB-38), from the maker notes of the cameras whose layout is known and
/// checked on a sample, else from EXIF's SubjectArea:
///
/// - **Canon** (CR2, CR3): AFInfo2 (tag 0x26), the areas centred on the frame's middle, Y up, in the frame it states;
///   the areas in focus, or those chosen when none was.
/// - **Nikon** (NEF, Z bodies): AFInfo2 (tag 0xB7), version 03xx or 04xx, the area's centre and size in pixels.
/// - **Sony** (ARW): FocusLocation (tag 0x2027), a point in the frame it states.
/// - **Fujifilm** (RAF): FocusPixel (tag 0x1023), a point in half the photo's size.
/// - **Panasonic** (RW2): AFPointPosition (tag 0x4D), a point as fractions of the frame.
/// - **SubjectArea** (EXIF 0x9214), which the iPhone writes: a point, circle or rectangle in the photo's pixels.
///
/// Nikon's DSLRs, Pentax (a point's number), Olympus and OM System, Leica, Sigma, Hasselblad and Phase One aren't read.
enum AFPointReader {
    /// How far into a file maker notes are looked for: CR3's boxes, RAF's preview and RW2's embedded JPEG start there.
    static let searchLimit = 4 << 20

    /// The AF point `url`'s file records, read from the file mapped, so only the pages read are loaded; `imageSize`
    /// is the photo's size upright, which Fujifilm's and SubjectArea's pixels are counted in.
    static func read(_ url: URL, imageSize: CGSize?) -> AFPoints? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return read(data, fileExtension: url.pathExtension, imageSize: imageSize)
    }

    static func read(_ data: Data, fileExtension: String, imageSize: CGSize?) -> AFPoints? {
        switch fileExtension.lowercased() {
        case "cr3": canonCR3(data)
        case "raf": fujifilm(data, imageSize: imageSize)
        default: tiff(data, imageSize: imageSize)
        }
    }

    // MARK: - Containers

    /// A TIFF-based raw (CR2, NEF, ARW, RW2, DNG and the rest): IFD0's orientation, then its EXIF's maker note, or
    /// for RW2 the maker note in the JPEG it embeds, then SubjectArea.
    private static func tiff(_ data: Data, imageSize: CGSize?) -> AFPoints? {
        guard let (file, first) = TIFFBytes.header(in: data, at: 0), let ifd0 = file.directory(at: first) else {
            return nil
        }
        let orientation = ifd0[0x112].flatMap { file.integers($0, limit: 1).first } ?? 1
        if let found = exif(file, ifd0: ifd0, orientation: orientation, imageSize: imageSize) {
            return found
        }
        // RW2 keeps its EXIF and maker notes in the JPEG it embeds (JpgFromRaw).
        if let jpeg = ifd0[0x2E], jpeg.type == 7, let found = jpegExif(
            data, at: jpeg.valueOffset, length: jpeg.count, orientation: orientation, imageSize: imageSize,
        ) {
            return found
        }
        return nil
    }

    /// The EXIF directory of `file`'s IFD0: its maker note, then its SubjectArea.
    private static func exif(
        _ file: TIFFBytes, ifd0: [UInt16: TIFFBytes.Entry], orientation: Int, imageSize: CGSize?,
    ) -> AFPoints? {
        guard let pointer = ifd0[0x8769].flatMap({ file.integers($0, limit: 1).first }),
              let exif = file.directory(at: pointer) else { return nil }
        if let note = exif[0x927C], let found = makerNote(file, note, orientation: orientation, imageSize: imageSize) {
            return found
        }
        return subjectArea(file, exif, orientation: orientation, imageSize: imageSize)
    }

    /// A JPEG's EXIF, found in its APP1 segment.
    private static func jpegExif(
        _ data: Data, at start: Int, length: Int, orientation: Int, imageSize: CGSize?,
    ) -> AFPoints? {
        guard let marker = data.bytes(at: start, count: 2), marker == [0xFF, 0xD8] else { return nil }
        var offset = start + 2
        let end = min(start + length, data.count)
        while offset + 4 <= end, let segment = data.bytes(at: offset, count: 4), segment[0] == 0xFF {
            let size = Int(segment[2]) << 8 | Int(segment[3])
            if segment[1] == 0xE1, data.bytes(at: offset + 4, count: 6) == Array("Exif\0\0".utf8) {
                guard let (file, first) = TIFFBytes.header(in: data, at: offset + 10),
                      let ifd0 = file.directory(at: first) else { return nil }
                let stated = ifd0[0x112].flatMap { file.integers($0, limit: 1).first } ?? orientation
                return exif(file, ifd0: ifd0, orientation: stated, imageSize: imageSize)
            }
            if segment[1] == 0xDA {
                return nil
            }
            offset += 2 + size
        }
        return nil
    }

    /// CR3: Canon's maker notes are the CMT3 box, a TIFF directory of their own, and IFD0 is CMT1.
    private static func canonCR3(_ data: Data) -> AFPoints? {
        func box(_ name: String) -> (TIFFBytes, Int)? {
            guard let at = data.firstOffset(of: Array(name.utf8), limit: searchLimit) else { return nil }
            return TIFFBytes.header(in: data, at: at + 4)
        }
        let orientation = box("CMT1").flatMap { file, first in
            file.directory(at: first)?[0x112].flatMap { file.integers($0, limit: 1).first }
        } ?? 1
        guard let (notes, first) = box("CMT3"), let directory = notes.directory(at: first) else { return nil }
        return canon(notes, directory, orientation: orientation)
    }

    /// RAF: the maker notes are in the EXIF of the JPEG preview whose place the header gives.
    private static func fujifilm(_ data: Data, imageSize: CGSize?) -> AFPoints? {
        guard data.bytes(at: 0, count: 8) == Array("FUJIFILM".utf8), let header = data.bytes(at: 84, count: 8) else {
            return nil
        }
        let offset = header[0 ..< 4].reduce(0) { $0 << 8 | Int($1) }
        let length = header[4 ..< 8].reduce(0) { $0 << 8 | Int($1) }
        return jpegExif(data, at: offset, length: length, orientation: 1, imageSize: imageSize)
    }

    // MARK: - Maker notes

    private static func makerNote(
        _ file: TIFFBytes, _ note: TIFFBytes.Entry, orientation: Int, imageSize: CGSize?,
    ) -> AFPoints? {
        let start = note.valueOffset
        guard let head = file.data.bytes(at: start, count: min(note.count, 16)), head.count >= 12 else { return nil }
        func starts(with text: String) -> Bool {
            head.starts(with: Array(text.utf8))
        }
        if starts(with: "Nikon\0") {
            guard let (notes, first) = TIFFBytes.header(in: file.data, at: start + 10),
                  let directory = notes.directory(at: first) else { return nil }
            return nikon(notes, directory, orientation: orientation)
        }
        if starts(with: "FUJIFILM") {
            let notes = TIFFBytes(data: file.data, base: start, littleEndian: true)
            guard let first = notes.uint32(at: start + 8), let directory = notes.directory(at: Int(first)) else {
                return nil
            }
            return fujifilm(notes, directory, orientation: orientation, imageSize: imageSize)
        }
        if starts(with: "Panasonic\0") {
            guard let directory = file.directory(at: start + 12 - file.base) else { return nil }
            return panasonic(file, directory, orientation: orientation)
        }
        let make = head.prefix(12)
        if starts(with: "SONY DSC ") || starts(with: "SONY CAM ") {
            return file.directory(at: start + 12 - file.base).flatMap { sony(file, $0, orientation: orientation) }
        }
        // Canon's and Sony's ARW maker notes are a directory with no header, its offsets counted from the file's.
        guard !make.allSatisfy({ (0x20 ... 0x7E).contains($0) }), let directory = file.directory(at: start - file.base)
        else { return nil }
        if directory[0x26] != nil {
            return canon(file, directory, orientation: orientation)
        }
        if directory[0x2027] != nil {
            return sony(file, directory, orientation: orientation)
        }
        return nil
    }

    private static func canon(_ notes: TIFFBytes, _ directory: [UInt16: TIFFBytes.Entry], orientation: Int)
        -> AFPoints? {
        guard let entry = directory[0x26], entry.type == 3 else { return nil }
        let values = notes.integers(entry)
        guard values.count > 8 else { return nil }
        let (count, valid, width, height) = (values[2], values[3], Double(values[6]), Double(values[7]))
        let words = (count + 15) / 16
        guard count > 0, valid > 0, valid <= count, width > 0, height > 0, values.count >= 8 + 4 * count + 2 * words
        else { return nil }
        func signed(_ value: Int) -> Double {
            Double(Int16(truncatingIfNeeded: value))
        }
        func bit(_ mask: Int, _ index: Int) -> Bool {
            values[mask + index / 16] >> (index % 16) & 1 == 1
        }
        let (inFocus, chosen) = (8 + 4 * count, 8 + 4 * count + words)
        let focused = (0 ..< valid).filter { bit(inFocus, $0) }
        let shown = focused.isEmpty ? (0 ..< valid).filter { bit(chosen, $0) } : focused
        let areas = shown.map { index in
            let size = CGSize(
                width: Double(values[8 + index]) / width,
                height: Double(values[8 + count + index]) / height,
            )
            let centre = CGPoint(
                x: 0.5 + signed(values[8 + 2 * count + index]) / width,
                y: 0.5 - signed(values[8 + 3 * count + index]) / height,
            )
            return AFPoints.Area(
                rect: CGRect(
                    x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width,
                    height: size.height,
                ),
                inFocus: !focused.isEmpty,
            )
        }
        return areas.isEmpty ? nil : AFPoints(areas: areas, orientation: orientation, source: .canon)
    }

    private static func nikon(_ notes: TIFFBytes, _ directory: [UInt16: TIFFBytes.Entry], orientation: Int)
        -> AFPoints? {
        guard let entry = directory[0xB7], let bytes = notes.bytes(entry), bytes.count >= 4,
              let version = String(bytes: bytes[0 ..< 4], encoding: .ascii) else { return nil }
        let start = switch version.prefix(2) {
        case "03": 0x2A
        case "04": 0x3E
        default: -1
        }
        guard start >= 0, bytes.count >= start + 12 else { return nil }
        // AFInfo2 is little-endian whatever the maker notes' order.
        let fields = (0 ..< 6).map { Double(Int(bytes[start + $0 * 2]) | Int(bytes[start + $0 * 2 + 1]) << 8) }
        let (width, height, x, y, areaWidth, areaHeight) = (
            fields[0],
            fields[1],
            fields[2],
            fields[3],
            fields[4],
            fields[5],
        )
        guard width > 0, height > 0, areaWidth > 0, areaHeight > 0 else { return nil }
        let rect = CGRect(
            x: (x - areaWidth / 2) / width, y: (y - areaHeight / 2) / height, width: areaWidth / width,
            height: areaHeight / height,
        )
        return AFPoints(areas: [.init(rect: rect, inFocus: true)], orientation: orientation, source: .nikon)
    }

    private static func sony(_ file: TIFFBytes, _ directory: [UInt16: TIFFBytes.Entry], orientation: Int)
        -> AFPoints? {
        guard let entry = directory[0x2027], entry.type == 3 else { return nil }
        let values = file.integers(entry)
        guard values.count == 4, values[0] > 0, values[1] > 0 else { return nil }
        let point = CGPoint(x: Double(values[2]) / Double(values[0]), y: Double(values[3]) / Double(values[1]))
        return AFPoints(areas: [.point(point)], orientation: orientation, source: .sony)
    }

    private static func fujifilm(
        _ notes: TIFFBytes, _ directory: [UInt16: TIFFBytes.Entry], orientation: Int, imageSize: CGSize?,
    ) -> AFPoints? {
        guard let entry = directory[0x1023], entry.type == 3, let imageSize else { return nil }
        let values = notes.integers(entry)
        let stored = AFPoints.swapsAxes(orientation)
            ? CGSize(width: imageSize.height, height: imageSize.width) : imageSize
        guard values.count == 2, values[0] > 0 || values[1] > 0, stored.width > 0, stored.height > 0 else {
            return nil
        }
        let point = CGPoint(x: Double(values[0]) * 2 / stored.width, y: Double(values[1]) * 2 / stored.height)
        guard point.x <= 1, point.y <= 1 else { return nil }
        return AFPoints(areas: [.point(point)], orientation: orientation, source: .fujifilm)
    }

    private static func panasonic(_ file: TIFFBytes, _ directory: [UInt16: TIFFBytes.Entry], orientation: Int)
        -> AFPoints? {
        guard let entry = directory[0x4D] else { return nil }
        let values = file.rationals(entry)
        guard values.count == 2, values.allSatisfy({ (0 ... 1).contains($0) }) else { return nil }
        return AFPoints(
            areas: [.point(CGPoint(x: values[0], y: values[1]))], orientation: orientation, source: .panasonic,
        )
    }

    /// EXIF's SubjectArea: a point, a circle's centre and diameter, or a rectangle's centre and size, in the
    /// stored photo's pixels.
    private static func subjectArea(
        _ file: TIFFBytes, _ exif: [UInt16: TIFFBytes.Entry], orientation: Int, imageSize: CGSize?,
    ) -> AFPoints? {
        guard let entry = exif[0x9214], let imageSize else { return nil }
        let values = file.integers(entry).map(Double.init)
        let stored = AFPoints.swapsAxes(orientation)
            ? CGSize(width: imageSize.height, height: imageSize.width) : imageSize
        guard (2 ... 4).contains(values.count), stored.width > 0, stored.height > 0 else { return nil }
        let size = switch values.count {
        case 3: CGSize(width: values[2], height: values[2])
        case 4: CGSize(width: values[2], height: values[3])
        default: CGSize.zero
        }
        let rect = CGRect(
            x: (values[0] - size.width / 2) / stored.width, y: (values[1] - size.height / 2) / stored.height,
            width: size.width / stored.width, height: size.height / stored.height,
        )
        guard rect.midX >= 0, rect.midX <= 1, rect.midY >= 0, rect.midY <= 1 else { return nil }
        return AFPoints(areas: [.init(rect: rect, inFocus: true)], orientation: orientation, source: .subjectArea)
    }
}

extension AFPoints.Area {
    static func point(_ point: CGPoint) -> Self {
        Self(rect: CGRect(origin: point, size: .zero), inFocus: true)
    }
}
