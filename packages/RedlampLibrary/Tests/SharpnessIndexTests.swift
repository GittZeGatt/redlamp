import Foundation
import Testing
@testable import RedlampLibrary

/// The soft-frame measurements in the index (LIB-42, schema version 14): kept by content key, so a photo renamed,
/// moved or copied keeps its own; measured again when the measure changes; and version 14's migration at a million
/// photos.
struct SharpnessIndexTests {
    private static func key(_ byte: UInt8) -> Data {
        Data(repeating: byte, count: 16)
    }

    private static func photo(_ name: String, folder: Int64, key: Data) -> PhotoRecord {
        PhotoRecord(
            folder: folder, name: name, size: 1000, modified: Date(timeIntervalSince1970: 1_700_000_000),
            contentKey: key, captured: Date(timeIntervalSince1970: 1_700_000_000), width: 6000, height: 4000,
            indexed: 1,
        )
    }

    @Test func `measurements are kept by content key, through a rename, a move and a copy`() async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        let folders = try await sandbox.addFolders(["A", "B"])
        let ids = try await sandbox.upsert([
            Self.photo("IMG_1.JPG", folder: #require(folders["A"]), key: Self.key(1)),
            Self.photo("IMG_2.JPG", folder: #require(folders["A"]), key: Self.key(2)),
            Self.photo("IMG_3.JPG", folder: #require(folders["A"]), key: Self.key(3)),
        ])
        let measured = PhotoSharpness(focus: .afPoint, score: 2.5)
        let gridded = PhotoSharpness(focus: .grid, cells: (0 ..< 24).map { Float($0) / 4 })
        try await sandbox.index.write { writer in
            try writer.setPhotoSharpness([(Self.key(1), measured), (Self.key(2), gridded)])
        }
        let found = try await sandbox.index.read { try $0.photoSharpness() }
        #expect(found == [ids[0]: measured, ids[1]: gridded], "the grid's cells come back as they went in")

        // IMG_1 renamed and moved to B, and IMG_3 a copy of IMG_2 elsewhere: same keys.
        try await sandbox.index.write { writer in
            try writer.database.execute("""
            UPDATE photos SET name = 'Renamed.JPG', folder = \(folders["B"]!) WHERE id = \(ids[0]);
            UPDATE photos SET content_key = x'\(Self.key(2).map { String(format: "%02x", $0) }.joined())'
              WHERE id = \(ids[2]);
            """)
        }
        let after = try await sandbox.index.read { try $0.photoSharpness(of: ids) }
        #expect(after == [ids[0]: measured, ids[1]: gridded, ids[2]: gridded])
        #expect(try await sandbox.index.read { try $0.sharpnessCandidates(ids) }.isEmpty)
    }

    @Test func `the photos the measure hasn't read are its candidates, and another version's measurements don't count`(
    ) async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        let folders = try await sandbox.addFolders(["Shoot"])
        let folder = try #require(folders["Shoot"])
        let ids = try await sandbox.upsert([
            Self.photo("IMG_1.JPG", folder: folder, key: Self.key(1)),
            Self.photo("IMG_2.JPG", folder: folder, key: Self.key(2)),
        ])
        try await sandbox.index.write { writer in
            try writer.setPhotoSharpness([(Self.key(1), PhotoSharpness(focus: .afPoint, score: 1))])
            try writer.database.execute("UPDATE photo_sharpness SET version = 0")
            try writer.setPhotoSharpness([(Self.key(2), .unmeasured)])
        }
        let candidates = try await sandbox.index.read { try $0.sharpnessCandidates(ids) }
        #expect(candidates.map(\.photo) == [ids[0]], "measured by another version; an unmeasurable file is done")
        #expect(candidates.first?.url.path == IndexSandbox.rootPath + "/Shoot/IMG_1.JPG")
        #expect(candidates.first?.width == 6000 && candidates.first?.contentKey == Self.key(1))
        #expect(try await sandbox.index.read { try $0.photoSharpness() } == [ids[1]: .unmeasured])

        try await sandbox.index.write { writer in
            try writer.database.execute("DELETE FROM photos WHERE id = \(ids[1])")
            #expect(try writer.removeOrphanedSharpness() == 1)
        }
        #expect(try await sandbox.index.read { try $0.photoSharpnessCount() } == 1)
    }

    /// An index of version 13 at `url` holding `photos` photos, in folders of a thousand.
    private static func version13(at url: URL, photos: Int) async throws {
        let older = try await LibraryIndex.open(at: url, migrations: Array(LibraryIndex.migrations.prefix(13)))
        try await older.write { writer in
            try writer.database.execute("""
            WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i + 1 < \(photos))
            INSERT INTO photos (folder, name, kind, size, modified, content_key, captured, width, height, indexed)
            SELECT 1 + i / 1000, 'IMG_' || i || '.JPG', 2, 2000000 + i, 1600000000 + i, randomblob(16),
              1500000000 + i * 60, 6000, 4000, 1
            FROM n;
            """)
        }
        await older.close()
    }

    @Test func `version 14's migration adds the table and rewrites no photo`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "redlamp-sharpness-index-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Index.sqlite")
        try await Self.version13(at: url, photos: 1000)
        let index = try await LibraryIndex.open(at: url)
        defer { index.closeAndWait() }
        let (version, photos, measured) = try await index.read { reader in
            try (
                reader.database.userVersion,
                reader.database.prepare("SELECT count(*) FROM photos").first { $0.int(at: 0) } ?? 0,
                reader.photoSharpnessCount(),
            )
        }
        #expect(version == 14 && photos == 1000 && measured == 0)
    }

    @Test(.measuresSpeed) func `version 14's migration at a million photos takes milliseconds`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "redlamp-sharpness-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Index.sqlite")
        try await Self.version13(at: url, photos: 1_000_000)
        let started = ContinuousClock.now
        let index = try await LibraryIndex.open(at: url)
        let elapsed = ContinuousClock.now - started
        defer { index.closeAndWait() }
        #expect(try await index.read { try $0.database.userVersion } == 14)
        print("SHARPNESS-INDEX-BENCH migration to version 14 at a million photos, opening included: \(elapsed)")
        #expect(elapsed < .milliseconds(500))
    }
}
