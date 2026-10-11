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
            try app.clickButton("library.filter.attribute")
            try app.wait("the Attribute section") { model in
                model.libraryFilters?.filter.sections.contains(.attribute) == true
            }

            try choose(app, "Bursts Only")
            try app.wait("the menu to show proposals") { $0.librarySoftFrames.shows }
            try app.wait("the bursts' seven frames measured in the background", timeout: 90) { model in
                model.librarySoftFrames.measuredCount >= 7
            }
            try app.wait("each burst's sharpest proposed, and its soft frames marked", timeout: 30) { model in
                shown(model, .soft) == ["A_0003.JPG", "B_0003.JPG"] && shown(model, .proposed).count == 2
            }

            try app.press(.toggleFilterBar)
            try app.wait("the filter bar hidden") { $0.libraryFilters?.isBarShown == false }
            try app.press(.toggleFilterBar)
            try app.wait("the filter bar's text to take the keyboard again") { _ in
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

            let checked = try app.main { _ in item("Bursts Only")?.state == .on && item("Off")?.state == .off }
            try app.expect(checked, "The Proposals menu checks Bursts Only")
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

        /// Chooses `title` in the Attribute section's Proposals menu, as a click on the item does: its action sent to
        /// its target, posted, since the menu's own machinery can start tracking it.
        private static func choose(_ app: RunningApp, _ title: String) throws {
            guard try app.main({ _ in item(title) != nil }) else {
                throw ScenarioFailure("The Proposals menu has no \(title)")
            }
            app.post { _ in
                guard let item = item(title), let action = item.action else { return }
                NSApp.sendAction(action, to: item.target, from: item)
            }
        }

        @MainActor private static func item(_ title: String) -> NSMenuItem? {
            guard let content = Views.editorWindow?.contentView else { return nil }
            return Views.all(NSPopUpButton.self, in: content)
                .first { $0.accessibilityIdentifier() == "library.filter.proposals" }?
                .menu?.items.first { $0.title == title && $0.isEnabled }
        }

        /// The names of the photos shown that the check gives `verdict`.
        @MainActor private static func shown(_ model: EditorModel, _ verdict: SoftFrames.Verdict) -> [String] {
            let softFrames = model.librarySoftFrames
            return model.items.filter { softFrames.verdict(ofShown: $0.url) == verdict }.map(\.name).sorted()
        }
    }
#endif
