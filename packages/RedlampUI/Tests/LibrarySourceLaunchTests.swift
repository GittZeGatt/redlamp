import Foundation
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// The source shown at quit, reopened at launch (LIB-23): a collection, a smart collection, a Library entry, a Library
/// Health check or Previous Import shown again from the library alone, with its selection, its active photo, its place
/// and the module it was left in; a folder too, with its own; a source that's gone, or a library that doesn't open,
/// giving way to the folder launch opens without one; and a folder opened before the library is, kept.
@MainActor
struct LibrarySourceLaunchTests {
    nonisolated static let lisbon = CollectionPath("Trips/Lisbon")!
    nonisolated static let everything = CollectionPath("Trips/Everything")!
    static let names = ["A.jpg", "B.jpg", "C.jpg", "D.jpg", "E.jpg"]

    /// Five photos in Shoot, all but A in Lisbon's collection and B marked, and a smart collection finding them all.
    private static func shoot(_ launches: LaunchSandbox) throws {
        try launches.sandbox.photos(names.map { "Shoot/" + $0 })
        for name in names.dropFirst() {
            try SidecarStore().save(
                Sidecar(
                    recipe: EditRecipe(),
                    metadata: PhotoMetadata(mark: name == "B.jpg", collections: [lisbon.text]),
                ),
                for: launches.photo(name),
            )
        }
        try CollectionDefinitions(collections: [everything: .smart("rating>=0")])
            .save(to: CollectionDefinitions.url(in: launches.paths))
    }

    @Test func `the key a source's filter and view are kept under names that source again`() throws {
        let sources: [LibrarySource] = try LibrarySource.library + LibrarySource.healthChecks + [
            .collection(Self.lisbon), .collection(#require(CollectionPath("Été/Café – Alfama"))),
        ]
        for source in sources {
            #expect(LibrarySource(key: source.key) == source, "\(source.key)")
        }
        for key in ["", "library:", "library:health:nothing", "collection:", "/Users/me/Pictures", "+/Users/me"] {
            #expect(LibrarySource(key: key) == nil, "\(key)")
        }
    }

    @Test func `a collection shown at quit is shown again at launch, with its selection, its active photo and its place`(
    ) async throws {
        let launches = try LaunchSandbox()
        defer { launches.remove() }
        try Self.shoot(launches)
        let first = launches.launch()
        try await launches.indexed()
        first.showFolder(launches.sandbox.folder("Shoot"))
        try await launches.sandbox.eventually { first.items.count == 5 }
        let sources = first.librarySources
        #expect(sources.show(.collection(Self.lisbon)))
        try await launches.sandbox.eventually { !sources.isListing && first.items.count == 4 }
        first.select(launches.photo("D.jpg"))
        first.click(launches.photo("C.jpg"), toggling: true)
        first.libraryViews.topPhoto = launches.photo("B.jpg")
        #expect(first.module == .library && first.selectedPhotos.count == 2)
        await launches.quit()

        let model = launches.launch()
        #expect(model.librarySources.isReopening, "it waits for the library, which the collection's photos come from")
        try await launches.sandbox.eventually { model.librarySources.shown != nil && !model.librarySources.isListing }
        #expect(model.librarySources.shown == .collection(Self.lisbon))
        #expect(Set(model.items.map(\.name)) == ["B.jpg", "C.jpg", "D.jpg", "E.jpg"])
        #expect(model.selection == launches.photo("C.jpg"), "the active photo")
        #expect(Set(model.selectedPhotos) == [launches.photo("C.jpg"), launches.photo("D.jpg")], "and the selection")
        #expect(model.libraryViews.restoredTop == launches.photo("B.jpg"), "the grid goes back to where it was")
        #expect(model.module == .library && model.library.openFolder == nil)
        #expect(!model.librarySources.isReopening)
        // The folder the restore finds isn't opened over it once its bookmarks resolve.
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.librarySources.shown == .collection(Self.lisbon) && model.library.openFolder == nil)
    }

    @Test(arguments: [
        LibrarySource.collection(everything), .allPhotographs, .marked, .health(.damaged),
    ])
    func `a smart collection, a Library entry or a check shown at quit is shown again at launch in its module`(
        _ source: LibrarySource,
    ) async throws {
        let launches = try LaunchSandbox()
        defer { launches.remove() }
        try Self.shoot(launches)
        if source == .health(.damaged) {
            try Data().write(to: launches.photo("Empty.jpg"))
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: launches.photo("Empty.jpg").path,
            )
        }
        let first = launches.launch()
        try await launches.indexed()
        let sources = first.librarySources
        try await launches.sandbox.eventually(seconds: 30) {
            sources.recount()
            return sources.count(of: source) != nil
        }
        #expect(sources.show(source))
        try await launches.sandbox.eventually { !sources.isListing && !first.items.isEmpty }
        let shown = first.items.map(\.url)
        let active = try #require(shown.last)
        first.select(active)
        first.showModule(.develop)
        try await launches.sandbox.eventually { first.info?.url == active }
        await launches.quit()

        let model = launches.launch()
        try await launches.sandbox.eventually { model.librarySources.shown != nil && model.info?.url == active }
        #expect(model.librarySources.shown == source)
        #expect(Set(model.items.map(\.url)) == Set(shown))
        #expect(model.selection == active && model.info?.url == active, "open in Develop, as it was left")
        #expect(model.module == .develop)
    }

    @Test func `Previous Import shown at quit is shown again at launch, with the import's own photos`() async throws {
        let launches = try LaunchSandbox()
        defer { launches.remove() }
        try launches.sandbox.photos(["Shoot/A.jpg"])
        let card = launches.sandbox.base.appending(path: "Card", directoryHint: .isDirectory)
        try launches.sandbox.photos(["IMG_0001.JPG", "IMG_0002.JPG"], under: card, from: 10)
        let first = launches.launch()
        try await launches.indexed()
        let core = try #require(launches.service?.core)
        let library = ImportLibrary(
            paths: core.paths, index: core.index, store: core.store, indexer: core.indexer, live: core.live,
        )
        let session = try ImportSession(sources: [ImportSource.at(card)], library: library, makesPreviews: false)
        let destination = launches.sandbox.folder("Imported")
        let plan = try await session.plan(ImportSettings(
            destination: destination,
            folders: NamingTemplate(parsing: ""),
        ))
        #expect(try await session.importer().run(plan).state == .finished)
        let sources = first.librarySources
        try await launches.sandbox.eventually(seconds: 30) {
            sources.recount()
            return sources.count(of: .previousImport) == 2
        }
        #expect(first.perform(.showPreviousImport))
        try await launches.sandbox.eventually { !sources.isListing && first.items.count == 2 }
        let imported = Set(first.items.map(\.url))
        await launches.quit()

        let model = launches.launch()
        try await launches.sandbox.eventually { model.librarySources.shown != nil && !model.librarySources.isListing }
        #expect(model.librarySources.shown == .previousImport)
        #expect(Set(model.items.map(\.url)) == imported, "the import's photos, not the rest of their folder")
        #expect(model.module == .library)
    }

    @Test func `a smart collection that's gone at launch gives way to the folder shown before it, with its photo`(
    ) async throws {
        let launches = try LaunchSandbox()
        defer { launches.remove() }
        try Self.shoot(launches)
        let first = launches.launch()
        try await launches.indexed()
        first.showFolder(launches.sandbox.folder("Shoot"))
        try await launches.sandbox.eventually { first.items.count == 5 }
        first.select(launches.photo("C.jpg"))
        #expect(first.librarySources.show(.collection(Self.everything)))
        try await launches.sandbox.eventually { !first.librarySources.isListing && first.items.count == 5 }
        await launches.quit()
        try CollectionDefinitions().save(to: CollectionDefinitions.url(in: launches.paths))

        let model = launches.launch()
        try await launches.sandbox.eventually { model.folder != nil && model.selection != nil }
        #expect(model.folder == launches.sandbox.folder("Shoot") && model.librarySources.shown == nil)
        #expect(model.selection == launches.photo("C.jpg"), "the folder's photo, as launch opens it without a source")
        #expect(!model.librarySources.isReopening)
        #expect(
            launches.defaults.string(forKey: LibrarySources.shownKey) == nil,
            "and the next launch won't look for it",
        )
    }

    @Test func `an entry with no photos left at launch gives way to the folder shown before it`() async throws {
        let launches = try LaunchSandbox()
        defer { launches.remove() }
        try Self.shoot(launches)
        let first = launches.launch()
        try await launches.indexed()
        first.showFolder(launches.sandbox.folder("Shoot"))
        try await launches.sandbox.eventually { first.items.count == 5 }
        #expect(first.librarySources.show(.marked))
        try await launches.sandbox.eventually { !first.librarySources.isListing && first.items.count == 1 }
        // B unmarked while Redlamp is closed, and read again: no photo is marked as the next launch opens.
        try SidecarStore().save(
            Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(collections: [Self.lisbon.text])),
            for: launches.photo("B.jpg"),
        )
        let core = try #require(launches.service?.core)
        for await event in core.indexer.update([FolderChange(launches.sandbox.folder("Shoot"), recursive: true)]) {
            core.live.receive(.indexer(event))
        }
        try await launches.sandbox.eventually { first.items.isEmpty }
        await launches.quit()
        launches.defaults.set(LibrarySource.marked.key, forKey: LibrarySources.shownKey)

        let model = launches.launch()
        try await launches.sandbox.eventually { model.folder != nil && model.items.count == 5 }
        #expect(model.folder == launches.sandbox.folder("Shoot") && model.librarySources.shown == nil)
        #expect(!model.librarySources.isReopening)
    }

    @Test func `a library that doesn't open at launch gives way to the folder`() async throws {
        let launches = try LaunchSandbox()
        defer { launches.remove() }
        try Self.shoot(launches)
        let first = launches.launch()
        try await launches.indexed()
        first.showFolder(launches.sandbox.folder("Shoot"))
        try await launches.sandbox.eventually { first.items.count == 5 }
        #expect(first.librarySources.show(.collection(Self.lisbon)))
        try await launches.sandbox.eventually { !first.librarySources.isListing && first.items.count == 4 }
        await launches.quit()
        // A library folder inside a file: the index can't open.
        let blocked = launches.sandbox.base.appending(path: "Blocked", directoryHint: .notDirectory)
        try Data([1]).write(to: blocked)
        launches.paths = LibraryPaths(root: blocked.appending(path: "Library", directoryHint: .isDirectory))

        let model = launches.launch()
        try await launches.sandbox.eventually { model.folder != nil && model.items.count == 5 }
        #expect(model.library.service?.isReady == false)
        #expect(model.folder == launches.sandbox.folder("Shoot") && model.librarySources.shown == nil)
        #expect(!model.librarySources.isReopening)
    }

    @Test func `a folder opened before the library is keeps its place, and the source shown at quit isn't opened over it`(
    ) async throws {
        let launches = try LaunchSandbox()
        defer { launches.remove() }
        try Self.shoot(launches)
        try launches.sandbox.photos(["Other/F.jpg"], from: 9)
        let first = launches.launch()
        try await launches.indexed()
        #expect(first.librarySources.show(.collection(Self.lisbon)))
        try await launches.sandbox.eventually { !first.librarySources.isListing && first.items.count == 4 }
        await launches.quit()

        let model = launches.launch()
        model.showFolder(launches.sandbox.folder("Other"))
        try await launches.sandbox
            .eventually { model.library.service?.isReady == true && !model.librarySources.isReopening }
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.folder == launches.sandbox.folder("Other") && model.librarySources.shown == nil)
        #expect(model.items.map(\.name) == ["F.jpg"])
    }

    /// Its multi-selection isn't checked: a folder listed from the disk at launch loses it as the library takes the
    /// folder over, keeping the active photo.
    @Test func `a folder opened before a library that doesn't open is kept, and nothing is opened over it`(
    ) async throws {
        let launches = try LaunchSandbox()
        defer { launches.remove() }
        try Self.shoot(launches)
        try launches.sandbox.photos(["Other/F.jpg"], from: 9)
        let first = launches.launch()
        try await launches.indexed()
        first.showFolder(launches.sandbox.folder("Shoot"))
        try await launches.sandbox.eventually { first.items.count == 5 }
        #expect(first.librarySources.show(.collection(Self.lisbon)))
        try await launches.sandbox.eventually { !first.librarySources.isListing && first.items.count == 4 }
        await launches.quit()
        let blocked = launches.sandbox.base.appending(path: "Blocked", directoryHint: .notDirectory)
        try Data([1]).write(to: blocked)
        launches.paths = LibraryPaths(root: blocked.appending(path: "Library", directoryHint: .isDirectory))

        let model = launches.launch()
        model.showFolder(launches.sandbox.folder("Other"))
        try await launches.sandbox.eventually {
            model.library.service?.state != .opening && !model.librarySources.isReopening
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.library.service?.isReady == false)
        try await launches.sandbox.eventually { model.items.map(\.name) == ["F.jpg"] }
        #expect(model.folder == launches.sandbox.folder("Other") && model.items.map(\.name) == ["F.jpg"])
    }

    @Test func `a folder shown at quit comes back at launch with its active photo and its place`() async throws {
        let launches = try LaunchSandbox()
        defer { launches.remove() }
        try Self.shoot(launches)
        let first = launches.launch()
        try await launches.indexed()
        first.showFolder(launches.sandbox.folder("Shoot"))
        try await launches.sandbox.eventually { first.items.count == 5 }
        first.select(launches.photo("B.jpg"))
        first.click(launches.photo("E.jpg"), toggling: true)
        first.libraryViews.topPhoto = launches.photo("D.jpg")
        await launches.quit()

        let model = launches.launch()
        try await launches.sandbox.eventually { model.items.count == 5 && model.selection != nil }
        #expect(model.folder == launches.sandbox.folder("Shoot") && model.librarySources.shown == nil)
        #expect(model.selection == launches.photo("E.jpg"))
        #expect(model.libraryViews.restoredTop == launches.photo("D.jpg"), "the grid goes back to where it was")
    }
}

/// Launches of the app on the photos of a scratch folder, each opened and quit as the app opens and quits, with
/// defaults of their own, so what one launch keeps at quit the next finds.
@MainActor
final class LaunchSandbox {
    let sandbox = SourcesSandbox()
    let defaults: UserDefaults
    private let suite = "source-launch-\(UUID().uuidString)"
    /// Where the library is kept; the first launch's unless a test moves it.
    lazy var paths = LibraryPaths(root: sandbox.base.appending(path: "Library", directoryHint: .isDirectory))
    private(set) var service: LibraryService?

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    /// Shoot's photo `name`.
    func photo(_ name: String) -> URL {
        sandbox.photo("Shoot/" + name)
    }

    /// Launches as the app does: the library opening off the main thread, the editor made, and the last session's
    /// source or folder restored. The first launch adds the scratch folder to Folders.
    @discardableResult
    func launch() -> EditorModel {
        let library = FolderLibrary(defaults: defaults)
        library.add([sandbox.root])
        let service = LibraryService(paths: paths, sidecars: library.sidecars, defaults: defaults) { url, size in
            StoreThumbnailMaker.imageIO(url, nil, size)
        }
        library.attach(service)
        sandbox.closes(service)
        let engine = StubEngine()
        engine.decodedThumbnail = { url, size in StoreThumbnailMaker.imageIO(url, nil, size) }
        let model = EditorModel(engine: engine, library: library)
        model.restoreLibrary()
        self.service = service
        return model
    }

    /// Returns once the library has indexed the scratch folder and caught up with it, waiting up to `seconds`.
    func indexed(seconds: Double = 30) async throws {
        let service = try #require(service)
        try await SourcesSandbox.eventually(seconds: seconds) {
            await service.canShow(self.sandbox.root, includingSubfolders: true)
        }
        try #require(await service.canShow(sandbox.root, includingSubfolders: true), "the library indexed the folder")
    }

    /// Quits as the app does: the library closes, what keeps the window's state for the next launch first, then its
    /// index.
    func quit() async {
        guard let service else { return }
        service.close()
        await service.core?.index.close()
        self.service = nil
    }

    func remove() {
        sandbox.remove()
        UserDefaults().removePersistentDomain(forName: suite)
    }
}
