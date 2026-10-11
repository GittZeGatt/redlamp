import Foundation

/// A photo the soft-frame measure is to read (LIB-42): its file, its upright size and the content key its
/// measurement is kept by.
public struct SharpnessCandidate: Sendable, Hashable {
    public var photo: Int64
    public var url: URL
    public var contentKey: Data
    public var width: Int?
    public var height: Int?
}

public extension IndexQueries {
    /// The measurements of `photos`, by photo ID, or of every photo with one when it's nil: those the current measure
    /// made, through each photo's content key.
    func photoSharpness(of photos: [Int64]? = nil) throws -> [Int64: PhotoSharpness] {
        var found: [Int64: PhotoSharpness] = [:]
        guard let photos else {
            // Every measurement looked up by its photos' keys: the photos are read once in rowid order, and each key
            // found in the table's own index.
            let statement = try database.cached("""
            SELECT p.id, s.focus, s.score, s.cells FROM photos p CROSS JOIN photo_sharpness s
              ON s.content_key = p.content_key WHERE s.version = ? AND p.content_key IS NOT NULL
            """)
            try statement.bind(PhotoSharpness.version, at: 1)
            for (id, sharpness) in try statement.map({ ($0.int64(at: 0), PhotoSharpness(row: $0, from: 1)) }) {
                found[id] = sharpness
            }
            return found
        }
        let statement = try database.cached("""
        SELECT s.focus, s.score, s.cells FROM photos p JOIN photo_sharpness s ON s.content_key = p.content_key
          WHERE p.id = ? AND s.version = ?
        """)
        for photo in photos {
            try statement.bind(photo, at: 1)
            try statement.bind(PhotoSharpness.version, at: 2)
            if let sharpness = try statement.first({ PhotoSharpness(row: $0, from: 0) }) {
                found[photo] = sharpness
            }
        }
        return found
    }

    /// Those of `photos` the current measure hasn't read, in their order, with their files: photos the index has
    /// read, with a content key, on a volume that's there, and whose files are where the index has them.
    func sharpnessCandidates(_ photos: [Int64]) throws -> [SharpnessCandidate] {
        let statement = try database.cached("""
        SELECT f.path, p.name, p.content_key, p.width, p.height FROM photos p JOIN folders f ON f.id = p.folder
          WHERE p.id = ? AND p.content_key IS NOT NULL AND p.state = 0 AND NOT EXISTS (
            SELECT 1 FROM photo_sharpness s WHERE s.content_key = p.content_key AND s.version = ?)
        """)
        var candidates: [SharpnessCandidate] = []
        for photo in photos {
            try statement.bind(photo, at: 1)
            try statement.bind(PhotoSharpness.version, at: 2)
            let found = try statement.first { row -> SharpnessCandidate? in
                guard let folder = row.string(at: 0), let name = row.string(at: 1), let key = row.data(at: 2) else {
                    return nil
                }
                return SharpnessCandidate(
                    photo: photo, url: URL(fileURLWithPath: folder, isDirectory: true).appending(path: name),
                    contentKey: key, width: row.isNull(at: 3) ? nil : row.int(at: 3),
                    height: row.isNull(at: 4) ? nil : row.int(at: 4),
                )
            }
            if let candidate = found ?? nil {
                candidates.append(candidate)
            }
        }
        return candidates
    }

    func photoSharpnessCount() throws -> Int {
        try database.cached("SELECT count(*) FROM photo_sharpness").first { $0.int(at: 0) } ?? 0
    }
}

public extension LibraryIndex.Writer {
    /// Records each measurement for its content key, in place of what an earlier one recorded.
    func setPhotoSharpness(_ measured: [(contentKey: Data, sharpness: PhotoSharpness)]) throws {
        let statement = try database.cached("""
        INSERT INTO photo_sharpness (content_key, version, focus, score, cells) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT (content_key) DO UPDATE SET version = excluded.version, focus = excluded.focus,
          score = excluded.score, cells = excluded.cells
        """)
        for (key, sharpness) in measured {
            try statement.bind(key, at: 1)
            try statement.bind(PhotoSharpness.version, at: 2)
            try statement.bind(sharpness.focus.rawValue, at: 3)
            try statement.bind(Double(sharpness.score), at: 4)
            try statement.bind(sharpness.cells.isEmpty ? nil : PhotoSharpness.cellData(sharpness.cells), at: 5)
            try statement.run()
        }
    }

    /// Removes the measurements no photo's content key leads to any more; returns how many.
    @discardableResult
    func removeOrphanedSharpness() throws -> Int {
        try database.cached("""
        DELETE FROM photo_sharpness WHERE content_key NOT IN (
          SELECT content_key FROM photos WHERE content_key IS NOT NULL)
        """).run()
        return database.changes
    }
}

extension PhotoSharpness {
    /// The measurement in `row`'s columns from `first`: focus, score and cells.
    init(row: SQLiteStatement, from first: Int32) {
        let cells = row.data(at: first + 2).map(Self.cells(from:)) ?? []
        self.init(
            focus: Focus(rawValue: row.int(at: first)) ?? .unmeasured, score: Float(row.double(at: first + 1)),
            cells: cells,
        )
    }

    static func cellData(_ cells: [Float]) -> Data {
        var data = Data(capacity: cells.count * 4)
        for cell in cells {
            withUnsafeBytes(of: cell.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func cells(from data: Data) -> [Float] {
        stride(from: 0, to: data.count - 3, by: 4).map { offset in
            let bytes = data.dropFirst(offset).prefix(4)
            let bits = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
            return Float(bitPattern: bits)
        }
    }
}
