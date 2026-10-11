import Foundation

/// TIFF directories as raw files and their maker notes lay them out, read with every offset checked against the
/// bytes, so a damaged or hostile file gives nil rather than a trap (LIB-38). Offsets in a directory are counted
/// from `base`, which is the TIFF header's start for most makers and the maker note's own start for some.
struct TIFFBytes {
    let data: Data
    let base: Int
    let littleEndian: Bool

    /// A directory entry: its tag, type and count, and where its value lies in `data`.
    struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: Int
        let valueOffset: Int

        /// Bytes per value of TIFF's types; 0 for a type TIFF doesn't define.
        static func size(of type: UInt16) -> Int {
            switch type {
            case 1, 2, 6, 7: 1
            case 3, 8: 2
            case 4, 9, 11, 13: 4
            case 5, 10, 12: 8
            default: 0
            }
        }
    }

    /// The most entries a directory may have before it's taken for garbage.
    private static let entryLimit = 1024

    /// A TIFF header at `start`: `II` or `MM`, any magic number (Panasonic and Olympus use their own), and the first
    /// directory's offset from the header.
    static func header(in data: Data, at start: Int) -> (bytes: TIFFBytes, firstDirectory: Int)? {
        guard let order = data.bytes(at: start, count: 2) else { return nil }
        let littleEndian: Bool
        switch (order[0], order[1]) {
        case (0x49, 0x49): littleEndian = true
        case (0x4D, 0x4D): littleEndian = false
        default: return nil
        }
        let bytes = TIFFBytes(data: data, base: start, littleEndian: littleEndian)
        guard let first = bytes.uint32(at: start + 4) else { return nil }
        return (bytes, Int(first))
    }

    func uint16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset <= data.count - 2 else { return nil }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
        return littleEndian ? UInt16(littleEndian: value) : UInt16(bigEndian: value)
    }

    func uint32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        return littleEndian ? UInt32(littleEndian: value) : UInt32(bigEndian: value)
    }

    /// The directory at `offset` from `base`, by tag; nil when it doesn't fit in the data.
    func directory(at offset: Int) -> [UInt16: Entry]? {
        let start = base + offset
        guard offset >= 0, let count = uint16(at: start), count > 0, Int(count) <= Self.entryLimit,
              data.holds(start + 2, count: Int(count) * 12) else { return nil }
        var entries: [UInt16: Entry] = [:]
        for index in 0 ..< Int(count) {
            let at = start + 2 + index * 12
            guard let tag = uint16(at: at), let type = uint16(at: at + 2), let count = uint32(at: at + 4) else {
                continue
            }
            let size = Entry.size(of: type) * Int(count)
            guard size > 0 else { continue }
            let valueOffset: Int
            if size <= 4 {
                valueOffset = at + 8
            } else {
                guard let pointer = uint32(at: at + 8) else { continue }
                valueOffset = base + Int(pointer)
            }
            guard data.holds(valueOffset, count: size) else { continue }
            entries[tag] = Entry(tag: tag, type: type, count: Int(count), valueOffset: valueOffset)
        }
        return entries
    }

    /// An entry's values as unsigned integers (BYTE, SHORT or LONG), at most `limit` of them.
    func integers(_ entry: Entry, limit: Int = .max) -> [Int] {
        let count = min(entry.count, limit)
        let size = Entry.size(of: entry.type)
        guard [1, 3, 4, 7].contains(entry.type), entry.valueOffset >= 0,
              entry.valueOffset <= data.count - count * size else { return [] }
        let littleEndian = littleEndian
        return data.withUnsafeBytes { raw in
            (0 ..< count).map { index in
                let at = entry.valueOffset + index * size
                switch size {
                case 1: return Int(raw[at])
                case 2:
                    let value = raw.loadUnaligned(fromByteOffset: at, as: UInt16.self)
                    return Int(littleEndian ? UInt16(littleEndian: value) : UInt16(bigEndian: value))
                default:
                    let value = raw.loadUnaligned(fromByteOffset: at, as: UInt32.self)
                    return Int(littleEndian ? UInt32(littleEndian: value) : UInt32(bigEndian: value))
                }
            }
        }
    }

    /// An entry's RATIONAL values as numbers.
    func rationals(_ entry: Entry) -> [Double] {
        guard entry.type == 5 else { return [] }
        return (0 ..< entry.count).compactMap { index in
            guard let numerator = uint32(at: entry.valueOffset + index * 8),
                  let denominator = uint32(at: entry.valueOffset + index * 8 + 4), denominator > 0 else { return nil }
            return Double(numerator) / Double(denominator)
        }
    }

    /// The bytes of an entry's value.
    func bytes(_ entry: Entry) -> [UInt8]? {
        data.bytes(at: entry.valueOffset, count: Entry.size(of: entry.type) * entry.count)
    }
}

extension Data {
    /// Whether `count` bytes from `offset` (counted from the data's start) are all there.
    func holds(_ offset: Int, count: Int) -> Bool {
        offset >= 0 && count >= 0 && offset <= self.count - count
    }

    /// `count` bytes from `offset` (counted from the data's start), or nil when they aren't all there.
    func bytes(at offset: Int, count: Int) -> [UInt8]? {
        guard holds(offset, count: count) else { return nil }
        let start = startIndex + offset
        return [UInt8](self[start ..< start + count])
    }

    /// Where `pattern` first starts, looking no further than `limit` bytes in.
    func firstOffset(of pattern: [UInt8], limit: Int) -> Int? {
        let length = Swift.min(count, limit)
        guard !pattern.isEmpty, length >= pattern.count else { return nil }
        return withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            guard let base = raw.baseAddress else { return nil }
            return pattern.withUnsafeBytes { needle -> Int? in
                guard let found = memmem(base, length, needle.baseAddress, pattern.count) else { return nil }
                return base.distance(to: UnsafeRawPointer(found))
            }
        }
    }
}
