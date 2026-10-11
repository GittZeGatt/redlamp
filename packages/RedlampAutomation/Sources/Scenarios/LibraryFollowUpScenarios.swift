#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Foundation
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    /// The library's follow-ups for 0.3.0, each on a scratch folder of its own: a folder handed over by another form
    /// of its path shown as itself (LIB-15's culling there), and a photo active in a stack its folder's view had open
    /// still active when the folder is shown again (LIB-28, LIB-23).
    enum LibraryFollowUpScenarios {
        static let all: [Scenario] = [folderByAnotherPath, stackOpenAgain]

        /// Three photos, C shown last, the folder left for the run's; then the folder handed over as a path with `..`
        /// and `//`, as a drop on the window, Finder's Open With or the command line hands one over.
        static let folderByAnotherPath = Scenario(
            "library.folder-by-another-path",
            "A folder handed to Redlamp by another form of its path, with .. and //, is shown as itself: once in "
                + "Folders, the photo last shown in it active again, and 3 rating the photo clicked",
            claims: [.feature("library.folders"), .feature("library.ratings")],
        ) { app in
            let scratch = try SourcesScratch(app, photos: ["A.jpg", "B.jpg", "C.jpg"])
            let depth = try app.main { $0.cullingUndoCount }
            defer {
                try? app.takeBackCulling(to: depth)
                app.removeScratch(scratch)
            }
            try scratch.index(app)
            let (folder, photos, c) = (scratch.folder, app.photos, scratch.photo("C.jpg"))
            try app.clickStill("grid.C.jpg")
            try app.wait("C active") { $0.selection == c }

            app.step("the run's folder")
            try app.main { $0.showFolder(photos) }
            try app.wait("the run's folder", timeout: 30) { $0.folder == photos && !$0.library.isListing }

            app.step("the folder handed over by another form of its path")
            let other = URL(
                fileURLWithPath: folder.path + "/../" + folder.lastPathComponent + "//", isDirectory: true,
            )
            let roots = try app.main { model in
                let count = model.library.roots.count
                model.open([other])
                return count
            }
            try app.waitForSource("the folder shown as itself, C active again", timeout: 30) { model in
                model.folder == folder && model.library.isShownFromLibrary && !model.library.isListing
                    && model.items.count == 3 && model.selection == c
            }
            let (named, rooted) = try app.main { model in
                (model.items.map(\.url) == ["A.jpg", "B.jpg", "C.jpg"].map(scratch.photo), model.library.roots.count)
            }
            try app.expect(named, "its photos named as the library names them")
            try app.expect(rooted == roots, "Folders holds it once, not \(rooted - roots + 1) times")
            app.covered(.feature("library.folders"), via: .model)

            app.step("3 on C")
            try app.clickStill("grid.C.jpg")
            try app.press(.rating3)
            try app.wait("C rated 3 in the grid") { $0.library.item(for: c)?.metadata.rating == 3 }
            try app.waitWritten()
            try app.wait("C's sidecar rated 3", timeout: 15) { model in
                CullingFollowUpScenarios.sidecar(c, in: model)?.rating == 3
            }
            app.covered(.feature("library.ratings"), via: .key)
        }

        /// The scratch pair opened with S and its JPEG clicked, the folder left for the run's and shown again: until
        /// `LibraryStacks` opened the stacks a view kept open before it covered the closed ones, the raw on top took
        /// the JPEG's place, both selected.
        static let stackOpenAgain = Scenario(
            "library.stack-open-again",
            "A raw and its JPEG opened with S and the JPEG clicked, the folder left and shown again: the pair open as "
                + "it was left, the JPEG active and alone selected",
            claims: [.feature("library.stacks"), .action(.toggleStack)],
        ) { app in
            try app.withStacks { scratch in
                let (photos, folder) = (app.photos, scratch.sources.folder)
                let jpeg = scratch.sources.photo(StackScratch.jpeg)
                try app.clickStill("grid.\(StackScratch.raw)")
                try app.press(.toggleStack)
                try app.waitForStacks("S to open the pair", open: 1, closed: 1)
                try app.clickStill("grid.\(StackScratch.jpeg)")
                try app.wait("the JPEG active, alone selected") { $0.selection == jpeg && $0.selectedCount == 1 }
                app.covered(.action(.toggleStack), via: .key)

                app.step("the run's folder, then the scratch folder again")
                try app.main { $0.showFolder(photos) }
                try app.wait("the run's folder", timeout: 30) { $0.folder == photos && !$0.library.isListing }
                try app.main { $0.showFolder(folder) }
                try app.wait("the scratch folder again", timeout: 30) { model in
                    model.folder == folder && model.library.isShownFromLibrary && !model.library.isListing
                }
                try app.waitForStacks("the pair open again, the burst closed", open: 1, closed: 1, timeout: 30)
                try app.wait("the stacks found", timeout: 30) { $0.gridStacks.isIdle }
                let (active, selected) = try app.main { model in (model.selection, model.selectedCount) }
                try app.expect(
                    active == jpeg && selected == 1,
                    "the JPEG active and alone selected, not \(active?.lastPathComponent ?? "none") with \(selected)",
                )
                try app.wait("the JPEG with its cell") { _ in
                    GroupScenarios.onScreen().contains("grid.\(StackScratch.jpeg)")
                }
                app.covered(.feature("library.stacks"), via: .mouse)
            }
        }
    }
#endif
