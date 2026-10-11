import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Custom labels' colours in the library (LIB-15): each photo's from its sidecar, in the index since schema 13, a
/// label's the one most of its photos have, given and changed with the label in batches with Undo.
struct CustomLabelColorIndexTests {
    @Test func `each photo's colour is read from its sidecar, and a label's is the one most of its photos have`(
    ) async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        let labelled: [(String, PhotoMetadata)] = [
            ("A.ARW", PhotoMetadata(customLabel: "Urgent", customLabelColor: .orange)),
            ("B.ARW", PhotoMetadata(customLabel: "Urgent", customLabelColor: .orange)),
            ("C.ARW", PhotoMetadata(customLabel: "Urgent", customLabelColor: .pink)),
            ("D.ARW", PhotoMetadata(customLabel: "Hero")),
            ("E.ARW", PhotoMetadata(customLabel: "Tie", customLabelColor: .teal)),
            ("F.ARW", PhotoMetadata(customLabel: "Tie", customLabelColor: .green)),
            ("G.ARW", PhotoMetadata(label: .red, customLabelColor: .blue)),
        ]
        for (name, metadata) in labelled {
            try sandbox.photo(name)
            try sandbox.sidecar(name, metadata)
        }
        try await sandbox.indexAll()

        #expect(try await sandbox.row("A.ARW").customLabelColor == .orange)
        #expect(try await sandbox.row("C.ARW").customLabelColor == .pink)
        #expect(try await sandbox.row("D.ARW").customLabelColor == nil)
        #expect(try await sandbox.row("G.ARW").customLabelColor == nil, "a colour label has no custom colour")
        let labels = try await LibraryMetadata(index: sandbox.index).customLabels()
        #expect(labels == [
            CustomLabelCount(name: "Hero", photos: 1),
            CustomLabelCount(name: "Tie", photos: 2, color: .green),
            CustomLabelCount(name: "Urgent", photos: 3, color: .orange),
        ], "a tie goes to the palette's first")
    }

    @Test func `a label given with its colour, then another colour, and Undo puts back each photo's`() async throws {
        let (sandbox, paths, ids) = try await MetadataChangeTests.library()
        defer { sandbox.remove() }
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        let three = Array(ids.prefix(3))
        try await metadata.apply(.set([.namedLabel("Urgent"), .customLabelColor(.orange)], on: three))
        #expect(paths.prefix(3).allSatisfy { sandbox.sidecar($0)?.metadata?.customLabelColor == .orange })
        #expect(try await metadata.customLabels() == [CustomLabelCount(name: "Urgent", photos: 3, color: .orange)])

        try await metadata.apply(.set([.namedLabel("Urgent"), .customLabelColor(.teal)], on: three))
        #expect(paths.prefix(3).allSatisfy { sandbox.sidecar($0)?.metadata?.customLabelColor == .teal })
        let rows = try await sandbox.index
            .read { reader in try three.map { try reader.photo(id: $0)?.customLabelColor } }
        #expect(rows == [.teal, .teal, .teal])

        try await metadata.undo()
        #expect(paths.prefix(3).allSatisfy { sandbox.sidecar($0)?.metadata?.customLabelColor == .orange })
        #expect(try await metadata.customLabels() == [CustomLabelCount(name: "Urgent", photos: 3, color: .orange)])
    }

    @Test func `a colour label, or a custom label named again, leaves no colour behind`() async throws {
        let (sandbox, paths, ids) = try await MetadataChangeTests.library()
        defer { sandbox.remove() }
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        try await metadata.apply(.set([.namedLabel("Urgent"), .customLabelColor(.orange)], on: [ids[0], ids[1]]))
        try await metadata.apply(.set([.label(.red)], on: [ids[0]]))
        try await metadata.apply(.set([.namedLabel("Hero")], on: [ids[1]]))

        #expect(sandbox.sidecar(paths[0])?.metadata?.label == .red)
        #expect(sandbox.sidecar(paths[0])?.metadata?.customLabelColor == nil)
        #expect(sandbox.sidecar(paths[1])?.metadata?.customLabel == "Hero")
        #expect(sandbox.sidecar(paths[1])?.metadata?.customLabelColor == nil)
        let rows = try await sandbox.index.read { reader in
            try [ids[0], ids[1]].map { try reader.photo(id: $0)?.customLabelColor }
        }
        #expect(rows == [nil, nil])
    }

    @Test func `another app's label taken in drops the colour of the one it replaces, and the same label keeps it`() {
        let urgent = PhotoMetadata(rating: 1, customLabel: "Urgent", customLabelColor: .orange)
        let renamed = XMPFields(customLabel: "Hero").applied(to: urgent, fields: [.label])
        #expect(renamed.customLabel == "Hero" && renamed.customLabelColor == nil && renamed.rating == 1)
        let same = XMPFields(customLabel: " Urgent ").applied(to: urgent, fields: [.label])
        #expect(same.customLabelColor == .orange)
        let rated = XMPFields(rating: 4).applied(to: urgent, fields: [.rating])
        #expect(rated.customLabelColor == .orange && rated.rating == 4)
    }

    @Test func `an index at version 12 gains the column, and one set back with it migrates again`() async throws {
        let folder = try TemporaryFolder()
        defer { withExtendedLifetime(folder) {} }
        let url = folder.url.appending(path: "Index.sqlite")
        try await LibraryIndex.open(at: url, migrations: Array(LibraryIndex.migrations.prefix(12))).close()

        func columns(_ index: LibraryIndex) async throws -> (Int, [String]) {
            try await index.read { reader in
                let names = try reader.database.prepare("SELECT name FROM pragma_table_info('photos')")
                    .map { $0.string(at: 0) ?? "" }
                return try (reader.database.userVersion, names)
            }
        }
        let migrated = try await LibraryIndex.open(at: url)
        let (version, names) = try await columns(migrated)
        #expect(version == 13 && names.last == "custom_label_color")
        await migrated.close()

        try SQLiteDatabase(path: url.path).setUserVersion(12)
        let again = try await LibraryIndex.open(at: url)
        defer { again.closeAndWait() }
        #expect(try await columns(again).0 == 13)
    }
}
