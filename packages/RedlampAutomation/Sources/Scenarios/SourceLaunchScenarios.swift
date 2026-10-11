#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Foundation
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    /// A folder's files that can't be read, shown in its grid (LIB-40), and the source shown at quit, reopened at
    /// launch (LIB-23).
    enum SourceLaunchScenarios {
        /// `library.source-at-quit` leaves a collection shown as the main launch quits, which the relaunch's
        /// `library.source-at-launch` finds reopened, then shows the run's folder with the photo that was active, as
        /// the smoke tier's relaunch expects to find it: the catalogue keeps these last before the smoke tier's pair.
        static let all: [Scenario] = [unreadableInFolder, sourceAtQuit, sourceAtLaunch]

        /// Two photos and a file Redlamp may not read, in the external disk's scratch folder: the file in the folder's
        /// grid among the photos, marked No Access; Folders counting it; its menu saying what's wrong, offering nothing
        /// to the Trash, and showing it in Library Health's Damaged Files; and All Photographs leaving it out.
        static let unreadableInFolder = Scenario(
            "library.unreadable-in-folder",
            "A folder's file that can't be read shown in its grid with its mark, counted in Folders, and shown in "
                + "Library Health from its menu",
            claims: [.feature("library.health"), .feature("library.folders")],
        ) { app in
            let scratch = try SourcesScratch(app, photos: ["A.jpg", "B.jpg", "Locked.jpg"])
            let locked = scratch.photo("Locked.jpg")
            let folders = app.photos
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
                scratch.remove(app)
                try? app.main { model in
                    model.showFolder(folders)
                    model.showModule(.develop)
                }
            }
            // Written ten minutes ago: a file written in the last minute may still be arriving.
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-600), .posixPermissions: 0], ofItemAtPath: locked.path,
            )
            try scratch.index(app)
            let folder = scratch.folder
            @MainActor func marks() -> [String: String] {
                guard let window = Views.editorWindow, let grid = LibraryGridViews.grid(in: window) else { return [:] }
                return LibraryGridViews.proposals(in: grid)
            }

            app.step("the folder's grid")
            try app.wait("the file among the folder's photos, marked", timeout: 30) { model in
                model.folder == folder && model.library.isShownFromLibrary
                    && Set(model.items.map(\.name)) == ["A.jpg", "B.jpg", "Locked.jpg"]
                    && marks()["Locked.jpg"] == "No Access"
            }
            let drawn = try app.main { _ in marks() }
            try app.expect(drawn == ["Locked.jpg": "No Access"], "only the file is marked, unframed: \(drawn)")

            app.step("Folders")
            let row = "folders." + folder.standardizedFileURL.path
            try app.wait("Folders counting the file", timeout: 30) { _ in
                app.sourceRowLabel(row)?.contains(", 3 photos") == true
            }
            app.covered(.feature("library.folders"), via: .model)

            app.step("the file's menu")
            let items = try app.rightClick(.identifier("grid.Locked.jpg"), choosing: "Show in Library Health")
                .map(\.title)
            let reason = "Can't be read: \(String(cString: strerror(EACCES)))"
            try app.expect(
                items.contains(reason) && items.contains("Move 1 Damaged File to the Trash…")
                    && items.contains(ShortcutAction.showInFinder.title),
                "the menu says what's wrong and offers what Library Health does: \(items)",
            )
            try app.waitForSource("Damaged Files, the file active", timeout: 30) { model in
                model.librarySources.shown == .health(.damaged) && !model.librarySources.isListing
                    && model.selection == locked
            }
            app.covered(.feature("library.health"), via: .mouse)

            app.step("All Photographs")
            try app.choose(.showAllPhotographs)
            try app.waitForSource("All Photographs without the file", timeout: 30) { model in
                model.librarySources.shown == .allPhotographs && !model.librarySources.isListing
                    && model.items.contains { $0.url == scratch.photo("A.jpg") } && !model.items
                    .contains { $0.url == locked }
            }
        }

        /// What the relaunch should find: written by the main launch, read by the next.
        struct Left: Codable {
            var collection: String
            var photos: [String]
            var active: String
        }

        /// A raw of the run's clicked in the grid and put in a new collection with ⌘N, the collection shown by a click
        /// on its row: left shown as Redlamp quits, the smoke tier's last scenario editing the raw in it. One photo,
        /// whose list shows no stack: until `LibraryStacks` opens the stacks a view kept open before it covers the
        /// closed ones, a photo active at quit inside an open stack would give way to the stack's top at launch.
        static let sourceAtQuit = Scenario(
            "library.source-at-quit",
            "A raw put in a new collection with ⌘N, shown by a click on its row and left shown as Redlamp quits",
            claims: [.feature("library.collections")],
        ) { app in
            let folder = app.photos
            try app.main { model in
                model.showFolder(folder)
                model.showLibrary(.grid)
            }
            try app.wait("the run's photos", timeout: 30) { model in
                model.folder == folder && !model.items.isEmpty && !model.library.isListing
            }
            let raws = ["arw", "raf", "cr3", "nef", "dng"]
            let names = try app.main { model in
                model.items.allRows.map(\.name).filter { raws.contains(($0 as NSString).pathExtension.lowercased()) }
            }
            guard let raw = try names.first(where: { try app.exists(.identifier("grid.\($0)")) }) else {
                throw ScenarioSkip("the grid shows none of the run's raws")
            }
            let name = "Reopened \(UUID().uuidString.prefix(8))"
            guard let path = CollectionPath(name) else { throw ScenarioFailure("\(name) isn't a collection's name") }
            try app.click(.identifier("grid.\(raw)"))
            try app.wait("\(raw) alone selected") { $0.selection?.lastPathComponent == raw && $0.selectedCount == 1 }
            try app.press(.newCollection)
            try app.waitForSheet("New Collection")
            try app.replaceInSheet("collections.name", with: name)
            try app.confirmCollectionSheet("New Collection")
            try app.wait("the collection with the raw", timeout: 60) { _ in
                app.sourceRowLabel("collections.\(name)") == "\(name), 1 photo"
            }
            try app.clickSourceRow("collections.\(name)")
            try app.waitForSource("the collection shown, the raw active", timeout: 30) { model in
                model.librarySources.shown == .collection(path) && !model.librarySources.isListing
                    && model.items.map(\.name) == [raw] && model.selection?.lastPathComponent == raw
            }
            try JSONEncoder().encode(Left(collection: name, photos: [raw], active: raw))
                .write(to: app.runDirectory.appending(path: "source-at-quit.json"))
            app.covered(.feature("library.collections"), via: .mouse)
        }

        /// The collection reopened from the library as Redlamp launches, with the photo active at quit (the smoke
        /// tier's last scenario's when it ran), in Develop, where the main launch left it; then the collection deleted
        /// and the run's folder shown with that photo, as the smoke tier's relaunch expects to find it.
        static let sourceAtLaunch = Scenario(
            "library.source-at-launch",
            "Reopened, Redlamp shows the collection shown at quit, with the photo that was active, in the module it was "
                + "left in",
            group: .relaunch,
            claims: [.feature("library.collections")],
        ) { app in
            let left = try JSONDecoder().decode(
                Left.self, from: Data(contentsOf: app.runDirectory.appending(path: "source-at-quit.json")),
            )
            guard let path = CollectionPath(left.collection) else { throw ScenarioFailure("no collection was left") }
            let edited = (try? Data(contentsOf: app.runDirectory.appending(path: "left.json")))
                .flatMap { try? JSONDecoder().decode(SmokeScenarios.Left.self, from: $0) }
            let active = edited?.photo ?? left.active
            let folder = app.photos
            defer {
                try? app.main { $0.showFolder(folder) }
                try? app.wait("the run's folder", timeout: 30) { model in
                    model.folder == folder && !model.items.isEmpty && !model.library.isListing
                }
                try? app.run("the collection deleted", timeout: 30) { model in
                    model.librarySources.delete(path)
                    await model.libraryPanels.written()
                }
                try? app.main { model in
                    if let url = model.items.allRows.first(where: { $0.name == active })?.url {
                        model.select(url)
                    }
                }
                try? app.wait("\(active) active in the run's folder", timeout: 10) { model in
                    model.selection?.lastPathComponent == active
                }
            }
            @MainActor func develop(_ model: EditorModel) -> String {
                "selection \(model.selection?.lastPathComponent ?? "none"), open "
                    + "\(model.info?.url.lastPathComponent ?? "none"), loading \(model.isLoading), "
                    + "\(model.photoSelection.count) selected, \(model.module)"
            }
            try app.waitForSource("the collection reopened", timeout: 60) { model in
                model.librarySources.shown == .collection(path) && !model.librarySources.isListing
                    && Set(model.items.map(\.name)) == Set(left.photos)
                    && model.selection?.lastPathComponent == active
            }
            let (module, folderShown, reopened) = try app.main { model in (model.module, model.folder, develop(model)) }
            app.recorder.write("note", ["reopened": reopened])
            try app.expect(folderShown == nil, "no folder opened over it")
            try app.expect(module == .develop, "in Develop, where it was left, not \(module)")
            do {
                try app.wait("\(active) open in Develop", timeout: 60) { model in
                    model.info?.url.lastPathComponent == active
                }
            } catch {
                let now = try app.main { model in develop(model) }
                throw ScenarioFailure("\(error) (\(now); as reopened: \(reopened))")
            }
            app.covered(.feature("library.collections"), via: .model)
        }
    }
#endif
