import Foundation
import RedlampDocument
import RedlampEngineAPI
import Synchronization
import Testing
@testable import RedlampLibrary

/// Photos with edits and metadata in both places (DEC-63, LIB-11): a move keeps the copy saved last, the one Redlamp
/// reads, where the folder keeps them from then on, and sets the other aside in a folder of the library's own,
/// journaled
/// as the move is, so a launch after a quit finishes it and Cancel leaves every photo with one copy where Redlamp reads
/// it; two copies the same move as one.
struct SidecarSettleTests {
    static let names = (1 ... 6).map { String(format: "IMG_%04d.JPG", $0) }

    /// Six photos with sidecars beside them, indexed; the library's sidecars and the root's ID.
    static func library() async throws -> (sandbox: KeywordSandbox, sidecars: LibrarySidecars, root: Int64) {
        let sandbox = try await KeywordSandbox.make()
        for (number, name) in names.enumerated() {
            try sandbox.photo(name, rating: number % 5 + 1)
        }
        try await sandbox.indexAll()
        let path = LibraryIndexer.path(sandbox.root)
        let root = try #require(try await sandbox.index.read { try $0.root(path: path) }?.id)
        return (sandbox, LibrarySidecars(index: sandbox.index, paths: sandbox.paths), root)
    }

    /// Where `name`'s sidecar beside it and on this Mac are.
    static func places(_ name: String, _ sandbox: KeywordSandbox, _ sidecars: LibrarySidecars, root: Int64)
        async throws -> (beside: URL, onThisMac: URL) {
        let locator = try await SidecarLocator(folder: sidecars.paths.sidecars, roots: [sidecars.knownRoot(root).1])
        return try (SidecarLocator.besidePhoto(sandbox.url(name)), #require(locator.onThisMac(sandbox.url(name))))
    }

    /// Saves a sidecar rated `rating`, saved `age` seconds ago, for `name` in `place`.
    static func save(
        rating: Int, age: TimeInterval, for name: String, in place: RootRecord.Sidecars, _ sandbox: KeywordSandbox,
        _ sidecars: LibrarySidecars, root: Int64,
    ) async throws {
        var located = try await sidecars.knownRoot(root).1
        located.onThisMac = place == .onThisMac
        let store = SidecarStore(locator: SidecarLocator(folder: sidecars.paths.sidecars, roots: [located]))
        var recipe = EditRecipe()
        recipe[.exposure] = Double(rating) / 10
        try store.save(
            Sidecar(
                recipe: recipe,
                metadata: PhotoMetadata(rating: rating),
                modified: Date(timeIntervalSinceNow: -age),
            ),
            for: sandbox.url(name),
        )
    }

    /// Every file of the sidecar at `url` by its path inside it, with its bytes; nil when it isn't there.
    static func files(_ url: URL) -> [String: Data]? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else { return (try? Data(contentsOf: url)).map { ["": $0] } }
        var files: [String: Data] = [:]
        for path in FileManager.default.subpaths(atPath: url.path) ?? [] {
            var folder: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.appending(path: path).path, isDirectory: &folder),
               !folder.boolValue {
                files[path] = try? Data(contentsOf: url.appending(path: path))
            }
        }
        return files
    }

    /// The rating Redlamp reads for `name`, through the library's locator.
    static func rating(_ name: String, _ sandbox: KeywordSandbox, _ sidecars: LibrarySidecars) async throws -> Int? {
        try await SidecarStore(locator: sidecars.locator()).load(for: sandbox.url(name))?.metadata?.rating
    }

    @Test func `a move keeps the copy saved last where the folder's setting says and sets the other aside`(
    ) async throws {
        let (sandbox, sidecars, root) = try await Self.library()
        defer { sandbox.remove() }
        // IMG_0002 saved later on this Mac, IMG_0003 saved later beside it: the photos' sidecars beside them were
        // saved an hour ago.
        let (newer, older) = (Self.names[1], Self.names[2])
        try await Self.save(rating: 5, age: 0, for: newer, in: .onThisMac, sandbox, sidecars, root: root)
        try await Self.save(rating: 1, age: 7200, for: older, in: .onThisMac, sandbox, sidecars, root: root)
        let ratings = try await (Self.rating(newer, sandbox, sidecars), Self.rating(older, sandbox, sidecars))
        #expect(ratings.0 == 5 && ratings.1 == 3)
        let newerPlaces = try await Self.places(newer, sandbox, sidecars, root: root)
        let olderPlaces = try await Self.places(older, sandbox, sidecars, root: root)
        let before = (
            newer: (Self.files(newerPlaces.beside), Self.files(newerPlaces.onThisMac)),
            older: (Self.files(olderPlaces.beside), Self.files(olderPlaces.onThisMac)),
        )
        #expect(try await sidecars.census(ofRoot: root).both == 2)

        let plan = try await sidecars.planMove(ofRoot: root, to: .onThisMac)
        #expect(plan.conflicts.map(\.photo) == [newer, older] && plan.conflicts.map(\.kept) == [
            .onThisMac,
            .besidePhotos,
        ])
        #expect(plan.items.count == 4)
        let folder = try #require(plan.setAside)
        #expect(folder.deletingLastPathComponent() == sidecars.paths.setAsideEdits)
        #expect(folder.lastPathComponent.hasSuffix(" " + sandbox.root.lastPathComponent))
        #expect(!FileManager.default.fileExists(atPath: folder.path), "made as the first copy goes in")
        let progress = Mutex<[FileProgress]>([])
        let outcome = try await sidecars.move(plan, progress: { step in progress.withLock { $0.append(step) } })

        #expect(outcome.settled == [newer, older] && outcome.setAside == folder)
        #expect(outcome.moved == 5, "four sidecars and IMG_0003's kept copy")
        #expect(outcome.failed.isEmpty && outcome.conflicts.isEmpty && outcome.gone == 0)
        #expect(progress.withLock { $0.last } == FileProgress(done: 6, total: 6, isRollingBack: false))
        #expect(Self.files(newerPlaces.onThisMac) == before.newer.1 && Self.files(newerPlaces.beside) == nil)
        #expect(Self.files(olderPlaces.onThisMac) == before.older.0 && Self.files(olderPlaces.beside) == nil)
        #expect(Self.files(folder.appending(path: newer + ".redlamp")) == before.newer.0, "its copy beside it")
        #expect(Self.files(folder.appending(path: older + ".redlamp")) == before.older.1, "its copy on this Mac")
        let read = try await (Self.rating(newer, sandbox, sidecars), Self.rating(older, sandbox, sidecars))
        #expect(read.0 == 5 && read.1 == 3, "what Redlamp reads is as it was")
        let census = try await sidecars.census(ofRoot: root)
        #expect(census.both == 0 && census.beside == 0 && census.onThisMac == Self.names.count)
        #expect(try await sidecars.unfinishedMove() == nil)
    }

    @Test func `moving back beside the photos keeps the copy saved last there, in a folder of its own`() async throws {
        let (sandbox, sidecars, root) = try await Self.library()
        defer { sandbox.remove() }
        _ = try await sidecars.move(sidecars.planMove(ofRoot: root, to: .onThisMac))
        // Another Mac saves two photos beside them meanwhile: one later than this Mac's copy, one earlier.
        let (newer, older) = (Self.names[3], Self.names[4])
        try await Self.save(rating: 2, age: -60, for: newer, in: .besidePhotos, sandbox, sidecars, root: root)
        try await Self.save(rating: 4, age: 86400, for: older, in: .besidePhotos, sandbox, sidecars, root: root)
        let newerPlaces = try await Self.places(newer, sandbox, sidecars, root: root)
        let olderPlaces = try await Self.places(older, sandbox, sidecars, root: root)
        let before = (newer: Self.files(newerPlaces.beside), older: Self.files(olderPlaces.onThisMac))
        let asides = (Self.files(newerPlaces.onThisMac), Self.files(olderPlaces.beside))

        let plan = try await sidecars.planMove(ofRoot: root, to: .besidePhotos)
        #expect(plan.conflicts.map(\.kept) == [.besidePhotos, .onThisMac])
        let folder = try #require(plan.setAside)
        let outcome = try await sidecars.move(plan)
        #expect(outcome.settled == [newer, older] && outcome.moved == Self.names.count - 1 && outcome.failed.isEmpty)
        #expect(Self.files(newerPlaces.beside) == before.newer && Self.files(newerPlaces.onThisMac) == nil)
        #expect(Self.files(olderPlaces.beside) == before.older && Self.files(olderPlaces.onThisMac) == nil)
        #expect(Self.files(folder.appending(path: newer + ".redlamp")) == asides.0)
        #expect(Self.files(folder.appending(path: older + ".redlamp")) == asides.1)
        #expect(try await sidecars.census(ofRoot: root).onThisMac == 0)
        #expect(try await sidecars.index.read { try $0.root(id: root)?.sidecars } == .besidePhotos)
    }

    @Test func `each move's copies go in a folder of its own, named by when it was planned and the folder it moves`(
    ) throws {
        let library = try TemporaryFolder()
        let paths = LibraryPaths(root: library.url)
        var parts = DateComponents(year: 2026, month: 10, day: 11, hour: 9, minute: 5, second: 7)
        parts.timeZone = .current
        let date = try #require(Calendar(identifier: .gregorian).date(from: parts))
        let first = paths.setAsideFolder(forRootAt: "/Volumes/Card/DCIM", at: date)
        #expect(first == paths.setAsideEdits.appending(path: "2026-10-11 09.05.07 DCIM", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        #expect(paths.setAsideFolder(forRootAt: "/Volumes/Card/DCIM", at: date).lastPathComponent
            == "2026-10-11 09.05.07 DCIM 2")
        #expect(paths.setAsideFolder(forRootAt: "/", at: date).lastPathComponent == "2026-10-11 09.05.07 Startup Disk")
    }

    @Test func `the same copy in both places moves as one, and nothing is set aside`() async throws {
        let (sandbox, sidecars, root) = try await Self.library()
        defer { sandbox.remove() }
        let name = Self.names[0]
        let places = try await Self.places(name, sandbox, sidecars, root: root)
        try FileManager.default.createDirectory(
            at: places.onThisMac.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try FileManager.default.copyItem(at: places.beside, to: places.onThisMac)
        let before = Self.files(places.beside)
        #expect(try await sidecars.census(ofRoot: root).both == 1)

        let plan = try await sidecars.planMove(ofRoot: root, to: .onThisMac)
        #expect(plan.conflicts.isEmpty && plan.setAside == nil && plan.items.count == Self.names.count)
        let outcome = try await sidecars.move(plan)
        #expect(outcome.moved == Self.names.count && outcome.settled.isEmpty && outcome.setAside == nil)
        #expect(Self.files(places.onThisMac) == before && Self.files(places.beside) == nil)
        #expect(!FileManager.default.fileExists(atPath: sidecars.paths.setAsideEdits.path))
    }

    @Test func `a launch finishes settling a move a quit interrupted, from its journal`() async throws {
        let (sandbox, sidecars, root) = try await Self.library()
        defer { sandbox.remove() }
        let (newer, older) = (Self.names[1], Self.names[2])
        try await Self.save(rating: 5, age: 0, for: newer, in: .onThisMac, sandbox, sidecars, root: root)
        try await Self.save(rating: 1, age: 7200, for: older, in: .onThisMac, sandbox, sidecars, root: root)
        let olderPlaces = try await Self.places(older, sandbox, sidecars, root: root)
        let (kept, other) = (Self.files(olderPlaces.beside), Self.files(olderPlaces.onThisMac))

        // As a quit leaves it: the whole move journaled, the placement this Mac's, IMG_0003's copy on this Mac set
        // aside and its kept copy not moved yet.
        let plan = try await sidecars.planMove(ofRoot: root, to: .onThisMac)
        let folder = try #require(plan.setAside)
        try FileManager.default.createDirectory(at: sidecars.paths.root, withIntermediateDirectories: true)
        try JSONEncoder().encode(SidecarMoveJournal(plan: plan)).write(to: sidecars.moveJournal)
        try await sidecars.setPlacement(.onThisMac, forRoot: root)
        let aside = folder.appending(path: older + ".redlamp")
        #expect(try SidecarMover.move(olderPlaces.onThisMac, to: aside) == .moved)
        #expect(try await sidecars.unfinishedMove()?.plan.conflicts.count == 2)

        let outcome = try #require(try await sidecars.resumeMove())
        #expect(outcome.settled == [newer, older] && outcome.moved == 5 && outcome.failed.isEmpty)
        #expect(Self.files(olderPlaces.onThisMac) == kept && Self.files(olderPlaces.beside) == nil)
        #expect(Self.files(aside) == other)
        #expect(try await sidecars.census(ofRoot: root).both == 0)
        #expect(try await sidecars.unfinishedMove() == nil)
    }

    @Test func `Cancel after settling puts back what moved, and the copies set aside stay set aside`() async throws {
        let (sandbox, sidecars, root) = try await Self.library()
        defer { sandbox.remove() }
        let (newer, older) = (Self.names[1], Self.names[2])
        try await Self.save(rating: 5, age: 0, for: newer, in: .onThisMac, sandbox, sidecars, root: root)
        try await Self.save(rating: 1, age: 7200, for: older, in: .onThisMac, sandbox, sidecars, root: root)
        let newerPlaces = try await Self.places(newer, sandbox, sidecars, root: root)
        let olderPlaces = try await Self.places(older, sandbox, sidecars, root: root)
        let newerBefore = (Self.files(newerPlaces.beside), Self.files(newerPlaces.onThisMac))
        let olderBefore = (Self.files(olderPlaces.beside), Self.files(olderPlaces.onThisMac))

        let plan = try await sidecars.planMove(ofRoot: root, to: .onThisMac)
        let control = SidecarMoveControl()
        let outcome = try await sidecars.move(plan, part: 1, control: control, progress: { progress in
            if !progress.isRollingBack, progress.done > 0 {
                control.cancel()
            }
        })
        // IMG_0002's copy beside it was set aside, the first part; its kept copy on this Mac went back beside it.
        #expect(outcome.settled == [newer] && outcome.setAside == plan.setAside && outcome.moved == 0)
        #expect(outcome.putBack == SidecarPutBack(moved: 1))
        #expect(Self.files(newerPlaces.beside) == newerBefore.1 && Self.files(newerPlaces.onThisMac) == nil)
        #expect(try Self.files(#require(plan.setAside).appending(path: newer + ".redlamp")) == newerBefore.0)
        #expect(Self.files(olderPlaces.beside) == olderBefore.0 && Self.files(olderPlaces.onThisMac) == olderBefore.1)
        #expect(try await Self.rating(newer, sandbox, sidecars) == 5)
        #expect(try await sidecars.index.read { try $0.root(id: root)?.sidecars } == .besidePhotos)
        #expect(try await sidecars.unfinishedMove() == nil)
    }
}
