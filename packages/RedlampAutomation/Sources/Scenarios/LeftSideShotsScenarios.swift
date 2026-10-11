#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    /// Pictures of the Library module's left side for the polish phase (LIB-45): the source list with a row of every
    /// kind, its sections collapsed, the collection sheets, the smart collection editor, Library Health's sheet and a
    /// source's summary, each written to the run's `shots` folder. Run by its ID alone; it checks nothing.
    enum LeftSideShotsScenarios {
        static let all: [Scenario] = [shots]

        static let shots = Scenario(
            "polish.left-shots",
            "Pictures of the left side: the source list, its sections collapsed, the collection sheets, the smart "
                + "collection editor, Library Health's sheet and a source's summary",
            tiers: [],
            claims: [],
        ) { app in
            let scratch = try SourcesScratch(
                app, photos: ["Lisbon/A.jpg", "Lisbon/B.jpg", "Lisbon/C.jpg", "Porto/D.jpg", "Porto/E.jpg"],
                empty: ["Empty.jpg"],
            )
            let photos = app.photos
            defer {
                app.removeCollectionsMade()
                scratch.remove(app)
                try? app.main { model in
                    model.showFolder(photos)
                    model.showModule(.develop)
                }
            }
            let copy = try SourcesScratch.jpeg(number: 6)
            for name in ["Copy 1.jpg", "Copy 2.jpg", "Copy 3.jpg"] {
                try copy.write(to: scratch.photo(name))
            }
            try scratch.index(app)
            let (a, b, c, d) = (
                scratch.photo("Lisbon/A.jpg"), scratch.photo("Lisbon/B.jpg"), scratch.photo("Lisbon/C.jpg"),
                scratch.photo("Porto/D.jpg"),
            )
            try app.main { model in
                model.setIncludesSubfolders(true)
                model.showLibrary(.grid)
            }
            try app.wait("the scratch's photos", timeout: 30) { model in
                !model.library.isListing && model.items.count >= 8
            }

            // Marked, Rejected and a pick, from the keys.
            try app.main { model in
                model.select(a)
                model.click(b, toggling: true)
            }
            try app.press(.toggleMark)
            try app.main { $0.select(c) }
            try app.press(.flagReject)
            try app.main { $0.select(d) }
            try app.press(.flagPick)

            // A set with a collection inside, the target; a collection; a smart collection of the picks.
            let tag = scratch.folder.lastPathComponent.suffix(8)
            let (clients, portfolio, picked) = ("Clients \(tag)", "Portfolio \(tag)", "Picked \(tag)")
            guard let set = CollectionPath(clients), let selects = CollectionPath("\(clients)/Selects") else {
                throw ScenarioFailure("No collection paths for \(clients)")
            }
            try app.main { model in
                let sources = model.librarySources
                sources.create(.set, named: clients)
                model.select(a)
                model.click(b, toggling: true)
                sources.create(.collection, named: "Selects", inside: set, adding: true, target: true)
                model.select(d)
                sources.create(.collection, named: portfolio, adding: true)
                sources.saveSmart("flag:pick folder:\(scratch.folder.lastPathComponent)", named: picked, inside: nil)
                sources.setOpen(set, true)
            }
            try app.waitForRow("collections.\(clients)/Selects", "Selects, 2 photos, target collection", "Selects")
            try app.waitForRow("collections.\(picked)", "\(picked), 1 photo", "the smart collection")
            try app.wait("Marked, Rejected and Library Health's checks", timeout: 60) { _ in
                app.sourceRowLabel("sources.marked") != nil && app.sourceRowLabel("sources.rejected") != nil
                    && app.sourceRowLabel("sources.health.damaged") != nil
                    && app.sourceRowLabel("sources.health.duplicates") != nil
            }

            // The source list with a folder shown, then a collection, then its sections collapsed.
            let lisbon = scratch.folder.appending(path: "Lisbon", directoryHint: .isDirectory)
            try app.main { model in
                model.library.setExpanded(scratch.folder, true)
                model.showFolder(lisbon)
            }
            try app.wait("Lisbon shown", timeout: 20) { $0.folder == lisbon && !$0.library.isListing }
            try shoot(app, "window-folder")
            try app.main { $0.librarySources.show(.collection(selects)) }
            try app.waitForSource("Selects shown", timeout: 20) { model in
                model.librarySources.shown == .collection(selects) && !model.librarySources.isListing
            }
            try shoot(app, "window-collection")
            try app.main { model in
                model.librarySources.toggle(.collections)
                model.toggleSidebarSection(.folders, solo: false)
            }
            try shoot(app, "window-collapsed")
            try app.main { model in
                model.librarySources.toggle(.collections)
                model.toggleSidebarSection(.folders, solo: false)
            }

            // The sheets, each cancelled.
            try app.main { $0.select(a) }
            try app.choose(.newCollection)
            try app.waitForSheet("New Collection")
            try shoot(app, "sheet-new-collection")
            try app.pressInSheet(KeyCombo(.escape))
            try app.choose(.newCollectionSet)
            try app.waitForSheet("New Collection Set")
            try shoot(app, "sheet-new-set")
            try app.pressInSheet(KeyCombo(.escape))
            try app.rightClickSourceRow("collections.\(clients)/Selects", choosing: "Rename…")
            try app.waitForSheet("Rename")
            try shoot(app, "sheet-rename")
            try app.pressInSheet(KeyCombo(.escape))
            try app.choose(.addToCollection)
            try app.waitForSheet("Add to a Collection")
            try shoot(app, "sheet-add-to-collection")
            try app.pressInSheet(KeyCombo(.escape))
            try app.choose(.newSmartCollection)
            try app.waitForSheet("New Smart Collection")
            try app.pressInSheet("smart.addRule")
            try app.pressInSheet("smart.addGroup")
            try shoot(app, "sheet-new-smart-collection")
            try app.pressInSheet(KeyCombo(.escape))
            try app.rightClickSourceRow("collections.\(picked)", choosing: "Edit Smart Collection…")
            try app.waitForSheet("Edit Smart Collection")
            try shoot(app, "sheet-edit-smart-collection")
            try app.pressInSheet(KeyCombo(.escape))

            // Library Health's sheet for the copies.
            try app.clickSourceRow("sources.health.duplicates")
            try app.waitForSource("the copies", timeout: 30) { model in
                model.librarySources.shown == .health(.duplicates) && model.items.count >= 3
            }
            try shoot(app, "window-health")
            try app.choose(.acceptHealthProposals)
            try app.wait("Library Health's sheet with its plan", timeout: 30) { $0.healthSheet?.canAccept == true }
            try shoot(app, "sheet-health")
            try app.pressInSheet(KeyCombo(.escape))
            try app.waitForNoSheet("Library Health's sheet")

            // Marked's summary.
            try app.rightClickSourceRow("sources.marked", choosing: "Show Summary…")
            try app.wait("Marked's summary", timeout: 20) { _ in SourceSummaryPopover.shownLines.count > 2 }
            try shoot(app, "popover-summary", popover: true)
            try app.main { _ in SourceSummaryPopover.close() }
        }

        /// The editor window, its sheet while one is up, or the popover shown, as `name`.png in the run's shots folder.
        /// The window's number goes in `name`.request first, for a watcher with the Mac's screen recording to capture
        /// it
        /// as the screen shows it, glass included (`screencapture -l`); without one, the window draws itself.
        static func shoot(_ app: RunningApp, _ name: String, popover: Bool = false) throws {
            let url = app.runDirectory.appending(path: "shots/\(name).png")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            app.pause(0.6)
            @MainActor func window() -> NSWindow? {
                if popover {
                    return NSApp.windows.first { $0.isVisible && "\(type(of: $0))".contains("Popover") }
                }
                return Views.editorWindow.map { $0.attachedSheet ?? $0 }
            }
            let number = try app.main { _ in window()?.windowNumber }
            guard let number else { throw ScenarioFailure("No window for \(name)") }
            let request = url.deletingPathExtension().appendingPathExtension("request")
            try "\(number)".write(to: request, atomically: true, encoding: .utf8)
            for _ in 0 ..< 40 where !FileManager.default.fileExists(atPath: url.path) {
                app.pause(0.1)
            }
            try? FileManager.default.removeItem(at: request)
            if !FileManager.default.fileExists(atPath: url.path) {
                let written = try app.main { _ in window().map { Snapshot.capture($0, to: url) } ?? false }
                try app.expect(written, "\(name) wasn't written")
            }
            app.step("shot \(name)")
        }
    }
#endif
