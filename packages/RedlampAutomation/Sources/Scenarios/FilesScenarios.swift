#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Foundation
    import RedlampDocument
    import RedlampEngineAPI
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    /// The library's files and stacks for 0.3.0 (LIB-11, LIB-28), on scratch folders of the run's own: Move Edits and
    /// Metadata… settling photos with edits and metadata in both places (DEC-63), the bursts the library finds open as
    /// a folder opens (DEC-64), and frames dragged within their open stack in the filmstrip.
    enum FilesScenarios {
        static let all: [Scenario] = [bothPlaces, burstsOpen, filmstripDrag]

        static let bothPlaces = Scenario(
            "library.move-edits-both-places",
            "Photos whose edits and metadata another Mac saved beside them while Redlamp kept them on this Mac are "
                + "named in Move Edits and Metadata's sheet, and the move keeps each one's copy saved last beside the "
                + "photos and sets the other aside, which Show Set-Aside Edits shows",
            claims: [.action(.moveEditsAndMetadata), .feature("library.sidecars")],
        ) { app in
            let (newer, older, alone) = ("Both A.jpg", "Both B.jpg", "Moved C.jpg")
            let scratch = try SourcesScratch(app, photos: [newer, older, alone])
            var setAside: URL?
            let revealing = try app.main { _ in SetAsideEdits.reveal }
            let revealed = RevealedFolders()
            defer {
                try? app.main { _ in SetAsideEdits.reveal = revealing }
                if let setAside {
                    try? FileManager.default.removeItem(at: setAside)
                }
                app.removeScratch(scratch)
                try? app.openWorking()
            }
            for (number, name) in [newer, older, alone].enumerated() {
                try SidecarStore().save(
                    Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(rating: number + 1)),
                    for: scratch.photo(name),
                )
            }
            try scratch.index(app)
            let row = "folders." + scratch.folder.standardizedFileURL.path
            try app.main { model in model.expandedSidebarSections.insert(.folders) }
            try app.wait("the folder's row in the Folders panel") { _ in
                Views.editorWindow.flatMap { Views.find(row, in: $0) } != nil
            }

            // The folder's edits and metadata kept in Redlamp on this Mac, from the folder's menu.
            try app.rightClick(.identifier(row), choosing: ShortcutAction.moveEditsAndMetadata.title)
            try app.waitForSheet("Move Edits and Metadata")
            try app.wait("the folder looked through", timeout: 30) { $0.moveEditsSheet?.canMove == true }
            try app.clickInSheet("moveEdits.move")
            try app.waitForNoSheet("Move Edits and Metadata", timeout: 60)
            let onThisMac = try app.main { model in
                [newer, older].map { model.library.sidecars.locator.onThisMac(scratch.photo($0)) }
            }
            guard let newerMac = onThisMac[0], let olderMac = onThisMac[1] else {
                throw ScenarioFailure("the folder doesn't keep its edits on this Mac")
            }

            // Another Mac saves two photos' edits beside them: one after this Mac's copy was saved, one before.
            let before = (newerMac: SidecarFiles.read(newerMac), olderMac: SidecarFiles.read(olderMac))
            for (name, rating, saved) in [(newer, 5, 3600.0), (older, 4, -86400.0)] {
                try SidecarStore().save(
                    Sidecar(
                        recipe: EditRecipe(), metadata: PhotoMetadata(rating: rating),
                        modified: Date().addingTimeInterval(saved),
                    ),
                    for: scratch.photo(name),
                )
            }
            let beside = (
                newer: SidecarFiles.read(SidecarLocator.besidePhoto(scratch.photo(newer))),
                older: SidecarFiles.read(SidecarLocator.besidePhoto(scratch.photo(older))),
            )

            // The Library menu's sheet names them, and moving them back settles them.
            try app.main { _ in SetAsideEdits.reveal = { revealed.note($0) } }
            try app.choose(.moveEditsAndMetadata)
            try app.waitForSheet("Move Edits and Metadata")
            try app.wait("the sheet naming the photos in both places", timeout: 30) { model in
                model.moveEditsSheet?.inBothPlaces == [newer, older] && model.moveEditsSheet?.canMove == true
            }
            let status = try app.main { $0.moveEditsSheet?.status }
            try app.expect(
                status == "2 photos have edits and metadata in both places: \(newer), \(older). Moving keeps the copy "
                    + "saved last, which Redlamp reads, and sets the other aside.",
                "the sheet says \(status ?? "nothing")",
            )
            try app.clickInSheet("moveEdits.move")
            let settled = "Moved 2 photos' edits and metadata beside the photos. 2 photos had edits and metadata in "
                + "both places: the copy saved last was kept beside the photos, and the other set aside."
            try app.wait("the sheet saying what it settled", timeout: 60) { model in
                model.moveEditsSheet?.isOver == true && model.moveEditsSheet?.status == settled
            }
            setAside = try app.main { $0.moveEditsSheet?.setAside }
            guard let folder = setAside else { throw ScenarioFailure("the sheet doesn't offer the copies set aside") }
            try app.expect(
                SidecarFiles.read(SidecarLocator.besidePhoto(scratch.photo(newer))) == beside.newer
                    && SidecarFiles.read(SidecarLocator.besidePhoto(scratch.photo(older))) == before.olderMac,
                "each photo's copy saved last is beside it",
            )
            try app.expect(
                SidecarFiles.read(folder.appending(path: newer + ".redlamp")) == before.newerMac
                    && SidecarFiles.read(folder.appending(path: older + ".redlamp")) == beside.older,
                "the other copies are set aside in \(folder.path)",
            )
            try app.expect(
                [newerMac, olderMac].allSatisfy { !FileManager.default.fileExists(atPath: $0.path) },
                "nothing left on this Mac",
            )
            try app.clickInSheet("moveEdits.showSetAside")
            try app.wait("Show Set-Aside Edits to show them") { _ in revealed.folders == [[folder]] }
            try app.pressInSheet(KeyCombo(.escape))
            try app.waitForNoSheet("Move Edits and Metadata")
            app.covered([.action(.moveEditsAndMetadata), .feature("library.sidecars")], via: .menu)
        }

        static let burstsOpen = Scenario(
            "library.bursts-open",
            "A folder's bursts the library finds start open, every frame with its cell in the grid and the filmstrip "
                + "and the burst marked as one, while a raw and its JPEG are one photo; S closes the burst, and it's "
                + "closed again when the folder is shown again",
            claims: [.action(.toggleStack), .feature("library.stacks")],
        ) { app in
            let scratch = try StackScratch(app)
            defer { app.removeScratch(scratch.sources) }
            let (raw, jpeg, burst) = (StackScratch.raw, StackScratch.jpeg, StackScratch.burst)
            try scratch.sources.index(app)
            try app.press(.gridView)
            try app.waitForStacks("the burst found open and the pair closed", open: 1, closed: 1, timeout: 60)
            try app.wait("every frame's cell, and the raw's without its JPEG's", timeout: 20) { _ in
                let cells = GroupScenarios.onScreen()
                return burst.allSatisfy { cells.contains("grid.\($0)") } && cells.contains("grid.\(raw)")
                    && !cells.contains("grid.\(jpeg)")
            }
            let value = try app.cellValue(burst[0])
            try app.expect(value.contains("a stack of 3, open"), "the burst's first cell says \(value)")
            try app.expect(
                try burst.allSatisfy { try app.exists(.filmstrip($0)) } && !app.exists(.filmstrip(jpeg)),
                "the filmstrip shows every frame, and the pair as one",
            )

            try app.clickStill("grid.\(burst[1])")
            try app.press(.toggleStack)
            try app.waitForStacks("S to close the burst", open: 0, closed: 2)
            try app.wait("one cell for the burst") { _ in
                let cells = GroupScenarios.onScreen()
                return cells.contains("grid.\(burst[0])") && !cells.contains("grid.\(burst[2])")
            }
            app.covered([.action(.toggleStack), .feature("library.stacks")], via: .key)

            let (photos, folder) = (app.photos, scratch.sources.folder)
            try app.main { $0.showFolder(photos) }
            try app.wait("the run's folder", timeout: 30) { $0.folder == photos && !$0.library.isListing }
            try app.main { $0.showFolder(folder) }
            try app.wait("the scratch folder again", timeout: 30) { $0.folder == folder && !$0.library.isListing }
            try app.waitForStacks("the burst still closed", open: 0, closed: 2, timeout: 30)
        }

        static let filmstripDrag = Scenario(
            "library.stacks-filmstrip-drag",
            "In the filmstrip, a frame of an open burst dragged onto another takes its place, each frame's sidecar "
                + "keeping its place, and ⌘Z puts it back; a photo dragged from the filmstrip onto a folder of Folders "
                + "moves there, as from the grid, and ⌘Z brings it back",
            claims: [.feature("library.stacks"), .feature("library.folders")],
        ) { app in
            let scratch = try StackScratch(app)
            let burst = StackScratch.burst
            let folder = scratch.sources.folder
            let picked = folder.deletingLastPathComponent()
                .appending(path: folder.lastPathComponent + " Picked", directoryHint: .isDirectory)
            let changes = try app.main { $0.libraryPanels.undoCount }
            defer {
                try? app.simulateLibraryDrags(false)
                try? app.run("the stacks' changes taken back", timeout: 120) { model in
                    model.showModule(.library)
                    while model.libraryPanels.undoCount > changes, model.libraryPanels.undoInLibrary() == true {}
                    await model.libraryPanels.written()
                }
                try? app.main { model in
                    if let root = model.library.root(containing: picked) {
                        model.library.remove(root)
                    }
                }
                try? FileManager.default.removeItem(at: picked)
                app.removeScratch(scratch.sources)
            }
            try scratch.sources.index(app)
            try app.press(.gridView)
            try app.waitForStacks("the burst found open", open: 1, closed: 1, timeout: 60)
            let ids = try burst.map(app.photoID)
            try app.wait("the burst's frames in the filmstrip", timeout: 20) { _ in
                burst.allSatisfy { Views.place(of: "filmstrip.\($0)", scrolling: false) != nil }
            }

            try app.simulateLibraryDrags(true)
            let outlined = try app.main { _ in LibraryDrags.outlined }
            let from = try app.frame(of: .filmstrip(burst[2]))
            let to = try app.frame(of: .filmstrip(burst[0]))
            try app.drag(
                .filmstrip(burst[2]),
                by: CGVector(dx: to.midX - from.midX, dy: to.midY - from.midY),
                steps: 12,
            )
            try app.wait("the drag onto the first frame", timeout: 60) { model in
                model.gridStacks.list?.stacks.stack(containing: ids[0])?.photos == [ids[2], ids[0], ids[1]]
            }
            try app.expect(try app.main { _ in LibraryDrags.outlined } > outlined, "the first frame was ringed")
            try app.waitWritten()
            let place = SidecarStore().load(for: scratch.sources.photo(burst[2]))?.metadata?.stack?.position
            try app.expect(place == 0, "BURST_3's sidecar puts it at \(place.map(String.init) ?? "no place")")
            app.covered(.feature("library.stacks"), via: .mouse)

            try app.press(.undo)
            try app.wait("⌘Z to put it back", timeout: 60) { model in
                model.gridStacks.list?.stacks.stack(containing: ids[0])?.photos == ids
            }

            // A photo alone dragged from the filmstrip onto another folder of Folders moves there.
            try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
            let row = "folders." + picked.standardizedFileURL.path
            try app.main { model in
                model.library.add([picked])
                model.expandedSidebarSections.insert(.folders)
            }
            try app.wait("the other folder in Folders", timeout: 20) { _ in
                Views.editorWindow.flatMap { Views.find(row, in: $0) } != nil
            }
            let alone = StackScratch.alone[0]
            try app.main { $0.select(scratch.sources.photo(alone)) }
            try app.wait("\(alone) selected alone") { $0.selectedPhotos == [scratch.sources.photo(alone)] }
            let moves = try app.main { $0.fileUndoCount }
            let start = try app.frame(of: .filmstrip(alone))
            let end = try app.frame(of: .identifier(row))
            try app.drag(
                .filmstrip(alone),
                by: CGVector(dx: end.midX - start.midX, dy: end.midY - start.midY),
                steps: 12,
            )
            try app.wait("\(alone) moved to the other folder", timeout: 60) { model in
                FileManager.default.fileExists(atPath: picked.appending(path: alone).path)
                    && model.fileUndoCount == moves + 1 && !model.isModalDialogOpen
            }
            app.covered(.feature("library.folders"), via: .mouse)
            try app.press(.undo)
            try app.run("the Undo", timeout: 60) { await $0.filesMade() }
            try app.wait("⌘Z to bring it back", timeout: 30) { _ in
                FileManager.default.fileExists(atPath: scratch.sources.photo(alone).path)
                    && !FileManager.default.fileExists(atPath: picked.appending(path: alone).path)
            }
        }
    }

    /// The folders Show Set-Aside Edits showed, from the main thread.
    private final class RevealedFolders: @unchecked Sendable {
        private let lock = NSLock()
        private var shown: [[URL]] = []

        var folders: [[URL]] {
            lock.withLock { shown }
        }

        func note(_ urls: [URL]) {
            lock.withLock { shown.append(urls) }
        }
    }
#endif
