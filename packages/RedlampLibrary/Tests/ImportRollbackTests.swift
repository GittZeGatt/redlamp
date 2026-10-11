import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Rolling an import back (LIB-27). The Trash is the Mac's own: each test takes out of it what it put there.
struct ImportRollbackTests {
    private static let shots = (1 ... 16).map { number in
        SimulatedCard.Shot(
            name: String(format: "IMG_%04d.JPG", number), captured: cameraTime(Double(number)), padding: 50000,
        )
    }

    /// The photos below `root`, without the sidecars the import wrote.
    private static func photos(in root: URL) -> [String: Data] {
        ImportSandbox.files(in: root).filter { !$0.key.contains(".redlamp") }
    }

    /// Takes out of the Trash what `rollback` moved there.
    private static func emptyTrash(of rollback: ImportRollback?) {
        for file in rollback?.trashed ?? [] {
            try? FileManager.default.removeItem(atPath: file.to)
        }
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @Test func `an import a forced quit cut short is rolled back: its copies go to the Trash and the folders it made go`(
    ) async throws {
        let sandbox = try await ImportSandbox.make()
        defer { sandbox.remove() }
        let source = try sandbox.card("CARD", Self.shots)
        let card = ImportSandbox.files(in: source.url)
        let session = sandbox.session([source], previews: false)
        let plan = try await session.plan(sandbox.settings())
        let importer = session.importer()
        importer.interruption.withLock { $0 = .afterPhotos(3) }
        await #expect(throws: Importer.ForcedQuit.self) { try await importer.run(plan) }
        let copied = Self.photos(in: sandbox.destination)
        #expect(copied.count >= 3 && copied.count < 16)

        let launch = Importer(library: sandbox.library, fileSystem: sandbox.fileSystem)
        let rollback = try await launch.rollBack(plan.id)
        defer { Self.emptyTrash(of: rollback) }
        #expect(rollback.state == .rolledBack && rollback.left.isEmpty)
        #expect(rollback.photos == copied.count && rollback.rolledBack.count == copied.count)
        // Each photo's copy at both targets, every one now in the Trash.
        #expect(rollback.trashed.count == 2 * copied.count)
        for file in rollback.trashed {
            #expect(FileManager.default.fileExists(atPath: file.to), "\(file.to)")
            #expect(!FileManager.default.fileExists(atPath: file.from), "\(file.from)")
        }
        let trashedNames = Set(rollback.trashed.map { ($0.from as NSString).lastPathComponent })
        #expect(Set(copied.keys.map { ($0 as NSString).lastPathComponent }).isSubset(of: trashedNames))
        // The folders it made, the destination and the backup among them, are gone; the card is as it was.
        for root in [sandbox.destination, sandbox.backup] {
            #expect(!Self.exists(root), "\(root.path)")
        }
        #expect(Set(rollback.removedFolders).isSuperset(of: [
            LibraryIndexer.path(sandbox.destination) + "/2026/2026-10-05", LibraryIndexer.path(sandbox.backup),
        ]))
        #expect(ImportSandbox.files(in: source.url) == card)

        // Over: it neither waits to be resumed nor counts as the previous import, and the card imports again whole.
        let entry = try #require(try await launch.entries().first { $0.id == plan.id })
        #expect(entry.state == .rolledBack && entry.done == 0 && entry.rolledBack == copied.count)
        #expect(try await launch.unfinishedEntries().isEmpty)
        #expect(try ImportJournal(paths: sandbox.paths).previousImport() == nil)
        let again = sandbox.session([source], previews: false)
        let replan = try await again.plan(sandbox.settings())
        #expect(replan.items.count == 16)
    }

    @Test func `a finished import is rolled back the same way, its photos taken out of the library`() async throws {
        let sandbox = try await ImportSandbox.make()
        defer { sandbox.remove() }
        let source = try sandbox.card("CARD", Array(Self.shots.prefix(4)))
        let session = sandbox.session([source], previews: false)
        let plan = try await session.plan(sandbox.settings(names: "Trip-{sequence:3}"))
        let outcome = try await session.importer().run(plan)
        #expect(outcome.state == .finished && outcome.verified == 4 && outcome.indexed == 4)
        #expect(try await sandbox.rows(below: sandbox.destination).count == 4)
        #expect(try ImportJournal(paths: sandbox.paths).previousImport()?.id == plan.id)

        let rollback = try await session.importer().rollBack(plan.id)
        defer { Self.emptyTrash(of: rollback) }
        #expect(rollback.state == .rolledBack && rollback.rolledBack.count == 4 && rollback.removed == 4)
        #expect(try await sandbox.rows(below: sandbox.destination).isEmpty)
        // The destination is a folder of the library now: it stays, empty. The backup, which isn't, goes.
        #expect(Self.exists(sandbox.destination) && ImportSandbox.files(in: sandbox.destination).isEmpty)
        #expect(!Self.exists(sandbox.destination.appending(path: "2026")))
        #expect(!Self.exists(sandbox.backup))
        // The renamed photos' sidecars, which recorded their names on the card, went with them.
        let sidecars = rollback.trashed.filter { $0.from.hasSuffix(".redlamp") }
        #expect(sidecars.count == 4)
        #expect(try ImportJournal(paths: sandbox.paths).previousImport() == nil)
    }

    @Test func `a copy changed since the import is left where it is, and the rollback says why`() async throws {
        let sandbox = try await ImportSandbox.make()
        defer { sandbox.remove() }
        let source = try sandbox.card("CARD", Array(Self.shots.prefix(3)))
        let session = sandbox.session([source], previews: false)
        let plan = try await session.plan(sandbox.settings(folders: ""))
        _ = try await session.importer().run(plan)
        // Another app saved over one photo at the destination.
        let changed = sandbox.destination.appending(path: "IMG_0002.JPG")
        try Data("saved over by another app".utf8).write(to: changed)

        let rollback = try await session.importer().rollBack(plan.id)
        defer { Self.emptyTrash(of: rollback) }
        #expect(rollback.state == .rolledBack && rollback.rolledBack.count == 2)
        let left = try #require(rollback.left.first)
        #expect(rollback.left.count == 1 && left.path == changed.path && left.message.contains("changed since"))
        #expect(try Data(contentsOf: changed) == Data("saved over by another app".utf8))
        // Its copy at the backup, still the one the import made, went; it stays in the library at the destination.
        #expect(!Self.exists(sandbox.backup.appending(path: "IMG_0002.JPG")))
        #expect(try await sandbox.rows(below: sandbox.destination).keys.sorted() == ["IMG_0002.JPG"])
        let entry = try #require(try await session.importer().entries().first { $0.id == plan.id })
        #expect(entry.done == 1 && entry.rolledBack == 2)
        #expect(try ImportJournal(paths: sandbox.paths).previousImport()?.photos == [changed.path])
    }

    @Test func `a rollback a forced quit cut short waits, then is finished from its journal`() async throws {
        let sandbox = try await ImportSandbox.make()
        defer { sandbox.remove() }
        let source = try sandbox.card("CARD", Array(Self.shots.prefix(8)))
        let session = sandbox.session([source], previews: false)
        let plan = try await session.plan(sandbox.settings())
        _ = try await session.importer().run(plan)
        let importer = session.importer()
        importer.interruption.withLock { $0 = .afterTakingBack(3) }
        await #expect(throws: Importer.ForcedQuit.self) { try await importer.rollBack(plan.id) }
        #expect(Self.photos(in: sandbox.destination).count == 5)

        // It waits: no import runs, and Resume's recovery leaves it to the rollback.
        let launch = Importer(library: sandbox.library, fileSystem: sandbox.fileSystem)
        let waiting = try #require(try await launch.unfinishedEntries().first)
        #expect(waiting.id == plan.id && waiting.state == .rollingBack)
        await #expect(throws: ImportError.unfinished(plan.id)) { try await launch.run(plan) }
        #expect(try await launch.recover().isEmpty)
        let rollback = try await launch.rollBack(plan.id)
        defer { Self.emptyTrash(of: rollback) }
        #expect(rollback.state == .rolledBack && rollback.rolledBack.count == 8 && rollback.recoveredFrom == 0)
        // The files the first run moved are in the Trash, from its journal, and their rows went in the second.
        #expect(rollback.trashed.count >= 16 && rollback.trashed
            .allSatisfy { Self.exists(URL(fileURLWithPath: $0.to)) })
        #expect(rollback.removed == 8)
        #expect(try await sandbox.rows(below: sandbox.destination).isEmpty)
        #expect(Self.photos(in: sandbox.destination).isEmpty && Self.photos(in: sandbox.backup).isEmpty)
        #expect(try await launch.unfinishedEntries().isEmpty)
    }

    @Test func `a folder the import made stays while it holds something else, and the copies staged go`() async throws {
        let sandbox = try await ImportSandbox.make()
        defer { sandbox.remove() }
        let source = try sandbox.card("CARD", Array(Self.shots.prefix(3)))
        let session = sandbox.session([source], previews: false)
        let plan = try await session.plan(sandbox.settings())
        let importer = session.importer()
        importer.interruption.withLock { $0 = .beforePlacing(1) }
        await #expect(throws: Importer.ForcedQuit.self) { try await importer.run(plan) }
        #expect(ImportSandbox.leftovers(in: sandbox.backup).contains { $0.hasSuffix(".redlamp-import") })
        // Someone put a note in the day's folder at the destination, and the Finder its own file at the backup's.
        let day = sandbox.destination.appending(path: "2026/2026-10-05")
        try Data("notes".utf8).write(to: day.appending(path: "notes.txt"))
        try Data().write(to: sandbox.backup.appending(path: "2026/2026-10-05/.DS_Store"))

        let rollback = try await Importer(library: sandbox.library, fileSystem: sandbox.fileSystem).rollBack(plan.id)
        defer { Self.emptyTrash(of: rollback) }
        #expect(rollback.state == .rolledBack && rollback.left.isEmpty)
        #expect(ImportSandbox.files(in: sandbox.destination).keys.sorted() == ["2026/2026-10-05/notes.txt"])
        #expect(ImportSandbox.leftovers(in: sandbox.destination).isEmpty)
        #expect(!Self.exists(sandbox.backup))
        #expect(!rollback.removedFolders.contains(LibraryIndexer.path(day)))
    }

    @Test func `a rollback waits for its destination to be there`() async throws {
        let sandbox = try await ImportSandbox.make()
        defer { sandbox.remove() }
        let source = try sandbox.card("CARD", Array(Self.shots.prefix(2)))
        let session = sandbox.session([source], previews: false)
        let plan = try await session.plan(sandbox.settings(backup: false))
        _ = try await session.importer().run(plan)
        let away = sandbox.folder.url.appending(path: "Away", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: sandbox.destination, to: away)
        await #expect(throws: ImportError.missingTarget(plan.id, path: LibraryIndexer.path(sandbox.destination))) {
            try await session.importer().rollBack(plan.id)
        }
        #expect(try await session.importer().entries().first { $0.id == plan.id }?.state == .finished)
        try FileManager.default.moveItem(at: away, to: sandbox.destination)
        let rollback = try await session.importer().rollBack(plan.id)
        defer { Self.emptyTrash(of: rollback) }
        #expect(rollback.state == .rolledBack && rollback.rolledBack.count == 2)
    }

    @Test func `the folders an import would make are written before anything is copied`() async throws {
        let sandbox = try await ImportSandbox.make()
        defer { sandbox.remove() }
        let source = try sandbox.card("CARD", Array(Self.shots.prefix(1)))
        try FileManager.default.createDirectory(
            at: sandbox.destination.appending(path: "2026"), withIntermediateDirectories: true,
        )
        let session = sandbox.session([source], previews: false)
        let plan = try await session.plan(sandbox.settings())
        let destination = LibraryIndexer.path(sandbox.destination)
        let backup = LibraryIndexer.path(sandbox.backup)
        #expect(Importer.newFolders(of: plan, fileSystem: LocalFileSystem()) == [
            destination + "/2026/2026-10-05", backup, backup + "/2026", backup + "/2026/2026-10-05",
        ])
    }
}
