#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDocument
    import RedlampEngineAPI
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    /// What carries across Library and Develop (LIB-13): one Undo for both, the filter and sort, and ⌘Z for an import
    /// from Lightroom Classic (LIB-29); and Compare's Swap and Make Select from the menus and the palette (LIB-16).
    /// Each is worked by keys, menus and the palette on the run's working folder, and put back after.
    enum ModulesCarryScenarios {
        static let all: [Scenario] = [compareActions, oneUndo, filterCarried, lightroomUndo]

        private static let ratings: [ShortcutAction] = [.rating0, .rating1, .rating2, .rating3, .rating4, .rating5]

        private static let raws: Set<String> = ["arw", "raf", "cr3", "nef", "dng", "orf", "pef", "rw2", "3fr"]

        /// Compare's select and candidate, by name.
        @MainActor private static func compared(_ model: EditorModel) -> [String] {
            [model.libraryCompare.select, model.libraryCompare.candidate].map { $0?.lastPathComponent ?? "-" }
        }

        /// The rating the grid shows on photo `name`.
        @MainActor private static func rating(of name: String, in model: EditorModel) -> Int? {
            model.items.first { $0.url.lastPathComponent == name }?.metadata.rating
        }

        static let compareActions = Scenario(
            "library.compare-actions",
            "In Compare, Swap and Make Select from the View menu and the command palette, as from ↓ and ↑; outside "
                + "Compare their items are off",
            claims: [.action(.swapCompared), .action(.makeSelect)],
        ) { app in
            try app.withCulling { _ in
                let cells = try app.gridCells()
                try app.expect(cells.count >= 4, "The grid has \(cells.count) cells")
                let (first, second, third, fourth) = (cells[0][0], cells[1][0], cells[2][0], cells[3][0])
                let swap = try app.menuItem(Menus.title(of: .swapCompared))
                try app.expect(swap.found && !swap.enabled, "Swap is on in the grid")
                try app.click(.identifier("grid.\(first)"))
                try app
                    .wait("\(first)'s cell alone") { Set($0.selectedPhotos.map(\.lastPathComponent)) == Set(cells[0]) }
                try app.press(.compareView)
                try app.wait("Compare: \(first) beside \(second)") { model in
                    model.libraryView == .compare && compared(model) == [first, second]
                }
                try app.choose(.swapCompared)
                try app.wait("the View menu's Swap") { compared($0) == [second, first] }
                try app.runFromPalette(.swapCompared)
                try app.wait("the palette's Swap: back") { compared($0) == [first, second] }
                try app.choose(.makeSelect)
                try app.wait("the View menu's Make Select") { compared($0) == [second, third] }
                try app.runFromPalette(.makeSelect)
                try app.wait("the palette's Make Select") { compared($0) == [third, fourth] }
                try app.press(.swapCompared)
                try app.wait("↓: swapped") { compared($0) == [fourth, third] }
                try app.press(.gridView)
                try app.wait("G: the grid") { $0.libraryView == .grid }
                try app.main { $0.deselectOtherPhotos() }
            }
        }

        static let oneUndo = Scenario(
            "modules.one-undo",
            "⌘Z in either module takes back the newest change of either, a nudge in Develop and a rating in Library in "
                + "turn, by its key and from the Edit menu, the notice naming the module out of sight; Redo makes "
                + "them again in turn",
            claims: [.action(.undo), .action(.redo), .feature("history.undo"), .feature("library.modules")],
        ) { app in
            try app.withCulling { _ in
                let open = try app.main { $0.info?.url.lastPathComponent }
                guard let open, let cell = try app.gridCells().first(where: { $0.contains(open) }) else {
                    throw ScenarioFailure("Develop has no photo open in the grid")
                }
                try app.click(.identifier("grid.\(cell[0])"))
                try app.wait("\(open)'s cell, Develop keeping it open") { model in
                    Set(model.selectedPhotos.map(\.lastPathComponent)) == Set(cell)
                        && model.info?.url.lastPathComponent == open
                }
                let own = try app.shown(open).rating
                let stars = own == 4 ? 2 : 4
                try app.press(ratings[stars])
                try app.wait("\(stars) stars on \(open)") { rating(of: open, in: $0) == stars }
                try app.waitWritten()

                try app.press(.editTool)
                try app
                    .wait("D: \(open) in Develop") { $0.module == .develop && $0.info?.url.lastPathComponent == open }
                let exposure = try app.value(.exposure)
                try app.press(.increaseSetting)
                try app.wait("=: the exposure nudged") { $0.sliderValue(.exposure) > exposure }
                try app.press(.gridView)
                try app.wait("G: Library") { $0.module == .library }

                try app.press(.undo)
                try app.wait("⌘Z in Library: Develop's exposure back") { model in
                    abs(model.sliderValue(.exposure) - exposure) < 1e-6
                }
                let said = try app.main { $0.undoNotice.text }
                try app.expect(said == "Undo Exposure in Develop", "The notice says \(said ?? "nothing")")
                try app.expect(try app.shown(open).rating == stars, "The rating, older, went first")
                try app.choose(.undo)
                try app.wait("the Edit menu's Undo: the rating back") { rating(of: open, in: $0) == own }
                try app.waitWritten()

                // ⇧⌘Z, as the driver reaches a ⌘ key with ⇧: its menu item carrying it.
                try app.expectKeyBinding(.redo)
                try app.choose(.redo)
                try app.wait("⇧⌘Z: the rating again") { rating(of: open, in: $0) == stars }
                try app.waitWritten()
                try app.press(.editTool)
                try app.wait("D: Develop") { $0.module == .develop }
                try app.choose(.redo)
                try app.wait("⇧⌘Z in Develop: the exposure again") { $0.sliderValue(.exposure) > exposure }
                try app.press(.undo)
                try app.wait("⌘Z: the exposure back") { abs($0.sliderValue(.exposure) - exposure) < 1e-6 }
                try app.press(.undo)
                try app.wait("⌘Z in Develop: Library's rating back") { rating(of: open, in: $0) == own }
                let named = try app.main { $0.undoNotice.text }
                try app.expect(named == "Undo \(stars) Stars in Library", "The notice says \(named ?? "nothing")")
                try app.waitWritten()
                app.covered([.feature("history.undo"), .feature("library.modules")], via: .key)
            }
        }

        static let filterCarried = Scenario(
            "modules.filter-carried",
            "The filter and sort Library shows the working folder with are Develop's filmstrip's, → in Develop "
                + "going through those photos in that order, and ⌘L in Develop turns the filter off in Library too",
            claims: [
                .action(.sortByName), .action(.reverseSort), .action(.toggleFilters), .feature("library.filter"),
                .feature("library.filmstrip"),
            ],
        ) { app in
            try app.withFilterBar { names in
                let raws = names.filter { Self.raws.contains(($0 as NSString).pathExtension.lowercased()) }
                try app.expect(raws.count >= 2 && raws.count < names.count, "The folder needs raws and other photos")
                try app.typeQuery("type:raw")
                try app.wait("only the raws") { $0.library.isFiltered && $0.items.count == raws.count }
                try app.pressInWindow(KeyCombo(.escape))
                try app.wait("Esc to give the grid the keyboard") { _ in
                    Views.editorWindow?.firstResponder.map { "\(Swift.type(of: $0))" } == "LibraryGridContentView"
                }
                try app.choose(.sortByName)
                try app.choose(.reverseSort)
                let order = raws.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
                try app.wait("the raws by name, Z to A") { $0.items.map(\.name) == order }
                try app.click(.identifier("grid.\(order[0])"))
                try app.wait("\(order[0]) active") { $0.selection?.lastPathComponent == order[0] }

                try app.press(.editTool)
                try app.wait("D: Develop") { $0.module == .develop }
                try app.expect(try app.main { $0.items.map(\.name) } == order, "Develop's filmstrip has another list")
                for name in order.dropFirst().prefix(2) {
                    try app.press(.nextPhoto)
                    try app.wait("→ in Develop: \(name)") { $0.selection?.lastPathComponent == name }
                }
                app.covered(.feature("library.filmstrip"), via: .key)
                try app.press(.toggleFilters)
                try app.wait("⌘L in Develop: every photo") { $0.items.count == names.count }
                try app.press(.gridView)
                try app.wait("G: Library with every photo") { $0.module == .library && $0.items.count == names.count }
                let kept = try app.main { model in
                    model.libraryFilters.map { !$0.filter.isEnabled && $0.filter.text == "type:raw" } ?? false
                }
                try app.expect(kept, "Library's filter isn't off with its text kept")
                try app.press(.toggleFilters)
                try app.wait("⌘L in Library: the raws again") { $0.items.count == raws.count }
                app.covered(.feature("library.filter"), via: .key)
            }
        }

        static let lightroomUndo = Scenario(
            "library.lightroom-undo",
            "⌘Z takes back an import from Lightroom Classic, as Undo Import in its window does, once the changes made "
                + "after it are taken back",
            claims: [.action(.importFromLightroom), .action(.undo)],
        ) { app in
            let scratch = try SourcesScratch(
                app, photos: ["Shoot/LR_0001.jpg", "Shoot/LR_0002.jpg", "Shoot/LR_0003.jpg"],
            )
            let tag = String(scratch.folder.lastPathComponent.suffix(8))
            let catalog = try LightroomScratchCatalog.make(of: scratch.folder, tag: tag)
            defer {
                try? app.main { _ in LightroomWindowController.current?.close() }
                scratch.remove(app)
                try? FileManager.default.removeItem(at: catalog.deletingLastPathComponent())
            }
            try app.main { model in model.showLibrary(.grid) }
            try app.choose(.importFromLightroom)
            try app.wait("the Lightroom Classic window", timeout: 30) { _ in
                LightroomWindowController.current?.window?.isVisible == true
            }
            // Choose…'s open panel can't be driven: the catalog it would pick is handed to the window.
            try app.inLightroomWindow { $0.choose(catalog: catalog) }
            try app.wait("the catalog's report", timeout: 60) { _ in
                LightroomWindowController.current?.isReported == true
            }
            try app.clickInLightroomWindow("lightroom.import")
            try app.wait("the import", timeout: 180) { _ in LightroomWindowController.current?.isImported == true }
            let sidecars = SidecarStore(locator: .besidePhotos)
            let photos = scratch.names.map(scratch.photo)
            try app.expect(sidecars.load(for: photos[0])?.metadata?.rating == 5, "The import's rating isn't there")
            try app.wait("the import on Undo") { $0.canPerform(.undo) }

            try app.choose(.undo)
            try app.wait("the import taken back", timeout: 120) { _ in
                LightroomWindowController.current?.isUndone == true
            }
            for photo in photos {
                let metadata = sidecars.load(for: photo)?.metadata
                try app.expect(
                    metadata == nil || metadata?.isEmpty == true,
                    "\(photo.lastPathComponent)'s sidecar after ⌘Z: \(String(describing: metadata))",
                )
            }
            let said = try app.main { $0.undoNotice.text }
            try app.expect(
                said == "Undo Import from Lightroom Classic of 3 photos", "The notice says \(said ?? "nothing")",
            )
            app.covered(.action(.importFromLightroom), via: .menu)
        }
    }
#endif
