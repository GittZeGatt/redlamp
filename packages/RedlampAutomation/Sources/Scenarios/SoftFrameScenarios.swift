#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    /// Soft frames in bursts (LIB-42), on a scratch folder of two test bursts whose frames are known to be sharp or
    /// soft (`SoftFrameSamples`): measured in the background, proposed in the grid, filtered and accepted.
    enum SoftFrameScenarios {
        static let all: [Scenario] = [proposals]

        /// Four frames whose third is out of focus, then, ten minutes later, three whose last moved.
        static func writeBursts(to folder: URL) throws {
            let start = Date().addingTimeInterval(-86400)
            try SoftFrameSamples.writeBurst(
                [.sharp(shift: 0), .sharp(shift: 1), .blurred(sigma: 2), .sharp(shift: 2)], to: folder, name: "A_",
                start: start, interval: 0.2,
            )
            try SoftFrameSamples.writeBurst(
                [.sharp(shift: 0), .brighter, .motion(length: 9)], to: folder, name: "B_",
                start: start.addingTimeInterval(600), interval: 0.2, seed: 2,
            )
        }

        static let proposals = Scenario(
            "library.soft-frames",
            "Bursts Only in the filter bar's Proposals menu proposes each burst's sharpest frame and marks its soft "
                + "frames once they're measured; Soft Frames in the menu, and is:soft completed with Tab, show the "
                + "soft frames alone; Accept Proposals picks and rejects them as one change, which ⌘Z takes back",
            claims: [.feature("library.filter"), .feature("library.ratings")],
        ) { app in
            let scratch = try SourcesScratch(app, photos: [])
            defer { app.removeScratch(scratch) }
            try writeBursts(to: scratch.folder)
            try scratch.index(app)
            defer {
                try? app.resetFilter()
                try? app.main { $0.showProposals(nil) }
            }
            try app.wait("the folder's seven frames", timeout: 20) { $0.items.count == 7 }
            try app.main { $0.libraryFilters?.setFilter(LibraryFilter()) }
            if try !app.main({ $0.libraryFilters?.isBarShown ?? false }) {
                try app.press(.toggleFilterBar)
            }
            try app.wait("the filter bar's text to take the keyboard") { _ in
                (Views.editorWindow?.firstResponder as? NSTextView)?.delegate is NSTextField
            }
            try app.clickView("library.filter.attribute", modifiers: .shift)
            try app.wait("the Attribute section") { model in
                model.libraryFilters?.filter.sections.contains(.attribute) == true
            }

            try choose(app, "Bursts Only")
            try app.wait("the menu to show proposals") { $0.librarySoftFrames.shows }
            try app.wait("the bursts' seven frames measured in the background", timeout: 90) { model in
                model.librarySoftFrames.measuredCount >= 7
            }
            try app.wait("each burst's sharpest proposed, and its soft frames marked", timeout: 30) {
                model in
                let verdicts = model.librarySoftFrames.verdicts
                return names(model, verdicts.photos(.soft)) == ["A_0003.JPG", "B_0003.JPG"]
                    && verdicts.photos(.proposed).count == 2
            }

            try app.clickView("library.filter.text")
            try app.wait("the filter bar's text to take the keyboard") { _ in
                (Views.editorWindow?.firstResponder as? NSTextView)?.delegate is NSTextField
            }
            try app.typeQuery("is:sof")
            try app.wait("Soft Frames offered, with the folder's two") { model in
                model.libraryFilters?.completions.first.map { $0.text == "is:soft " && $0.count == 2 } == true
            }
            try app.pressInWindow(KeyCombo(.tab))
            try app.wait("Tab to take it, and the soft frames alone", timeout: 20) { model in
                model.libraryFilters?.filter.text == "is:soft " && model.items.count == 2
            }
            app.covered(.feature("library.filter"), via: .key)
            try app.main { model in
                model.libraryFilters?.setFilter(LibraryFilter())
                Views.editorWindow?.makeFirstResponder(nil)
            }
            try app.wait("every frame again", timeout: 20) { $0.items.count == 7 }

            try choose(app, "Soft Frames")
            try app.wait("the menu's Soft Frames to show them alone", timeout: 20) { model in
                model.libraryFilters?.filter.text == "is:soft" && model.items.map(\.name).sorted() == [
                    "A_0003.JPG", "B_0003.JPG",
                ]
            }
            try choose(app, "Soft Frames")
            try app.wait("and every frame again", timeout: 20) { model in
                model.libraryFilters?.filter.text.isEmpty == true && model.items.count == 7
            }
            app.covered(.feature("library.filter"), via: .mouse)

            try choose(app, "Accept Proposals")
            try app.wait("the proposals picked and rejected", timeout: 30) { model in
                let flags = Dictionary(uniqueKeysWithValues: model.items.map { ($0.name, $0.metadata.flag) })
                return flags["A_0003.JPG"] == .reject && flags["B_0003.JPG"] == .reject
                    && flags.values.count { $0 == .pick } == 2 && !model.isWritingCulling
            }
            app.covered(.feature("library.ratings"), via: .mouse)
            try app.press(.undo)
            try app.wait("⌘Z to take every flag back", timeout: 30) { model in
                model.items.count == 7 && model.items.allSatisfy { $0.metadata.flag == nil } && !model.isWritingCulling
            }
            app.covered(.feature("library.ratings"), via: .key)

            try choose(app, "Off")
            try app.wait("the proposals hidden") { !$0.librarySoftFrames.shows }
        }

        /// Chooses `title` in the Attribute section's Proposals menu, as a click on the item does.
        private static func choose(_ app: RunningApp, _ title: String) throws {
            try app.main { _ in
                guard let content = Views.editorWindow?.contentView,
                      let menu = Views.all(NSPopUpButton.self, in: content)
                      .first(where: { $0.accessibilityIdentifier() == "library.filter.proposals" })?.menu,
                      let item = menu.items.first(where: { $0.title == title && $0.isEnabled })
                else { throw ScenarioFailure("The Proposals menu has no \(title)") }
                menu.performActionForItem(at: menu.index(of: item))
            }
        }

        @MainActor private static func names(_ model: EditorModel, _ ids: [Int64]) -> [String] {
            ids.compactMap { model.library.url(ofPhoto: $0)?.lastPathComponent }.sorted()
        }
    }
#endif
