#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    /// The filter bar's search field (LIB-45, DEC-66, DEC-67): the query's terms as its tokens, worked through the keys
    /// and the field's buttons, and the whole library searched from beside it and from ⌘K.
    enum FilterBarScenarios {
        static let all: [Scenario] = [tokens, searchAll]

        /// The field's tokens and the text being typed after them.
        @MainActor private static func shown(_: EditorModel) -> (tokens: [String], typing: String?)? {
            Views.editorWindow.flatMap { LibraryFilterBars.shown(in: $0) }
        }

        static let tokens = Scenario(
            "library.filter-tokens",
            "The filter bar's search field makes each term typed a token once a space follows it, Tab takes a "
                + "completion as a token, ⌫ takes the token before the cursor out, the field's buttons open the "
                + "Attribute row and the Metadata columns, its clear button empties it, and Esc goes back to the grid",
            claims: [.feature("library.filter")],
        ) { app in
            try app.withFilterBar { names in
                let raws = names.filter(FilterScenarios.isRaw)
                try app.expect(!raws.isEmpty && raws.count < names.count, "The folder needs raws and other photos")
                try app.typeQuery("type:raw ")
                try app.wait("type:raw a token, and the raws") { model in
                    shown(model)?.tokens == ["type:raw"] && model.items.count == raws.count
                }
                try app.typeQuery("label:re")
                try app.wait("a label offered for the text typed after the token") { model in
                    model.libraryFilters?.completions.first?.text == "label:red " && shown(model)?.typing == "label:re"
                }
                try app.pressInWindow(KeyCombo(.tab))
                try app.wait("Tab to take it as a token") { model in
                    shown(model)?.tokens == ["type:raw", "label:red"] && shown(model)?.typing == nil
                }
                try app.pressInWindow(KeyCombo(.delete))
                // A token field may select the token first, as Mail's does; a second ⌫ takes it out.
                if try app.main({ shown($0)?.tokens.count == 2 }) {
                    try app.pressInWindow(KeyCombo(.delete))
                }
                try app.wait("⌫ to take the label's token out, and the raws back") { model in
                    shown(model)?.tokens == ["type:raw"] && model.libraryFilters?.filter.text == "type:raw"
                        && model.items.count == raws.count
                }
                app.covered(.feature("library.filter"), via: .key)

                try app.clickButton("library.filter.attribute")
                try app.wait("the Attribute row open from the field") { model in
                    model.libraryFilters.map { $0.isBarShown && $0.filter.sections.contains(.attribute) } == true
                }
                try app.clickButton("library.filter.metadata")
                try app.wait("the Metadata columns open from it too") { model in
                    model.libraryFilters.map { $0.isBarShown && $0.filter.sections.isSuperset(of: [
                        .attribute,
                        .metadata,
                    ]) }
                        == true
                }
                try app.clickButton("library.filter.clear")
                try app.wait("the clear button to empty the field, and every photo back") { model in
                    model.libraryFilters?.filter.text.isEmpty == true && model.items.count == names.count
                        && shown(model)?.tokens.isEmpty == true
                }
                app.covered(.feature("library.filter"), via: .mouse)
                try app.pressInWindow(KeyCombo(.escape))
                try app.wait("Esc to give the grid the keyboard") { _ in
                    Views.editorWindow?.firstResponder.map { "\(Swift.type(of: $0))" } == "LibraryGridContentView"
                }
            }
        }

        static let searchAll = Scenario(
            "library.filter-search-all",
            "Search All, beside the filter bar's field with the library's count, shows All Photographs with the "
                + "field's query; and ⌘K, from Develop, runs the text typed over All Photographs from its Search All "
                + "Photographs row",
            claims: [.feature("library.filter"), .feature("workspace.palette")],
        ) { app in
            let photos = app.photos
            /// All Photographs' filter cleared, and the run's folder shown again, as Develop and the scenarios after
            /// find it.
            func showFolderAgain() throws {
                try app.main { model in
                    if model.library.shownSource == .allPhotographs {
                        model.libraryFilters?.setFilter(LibraryFilter())
                    }
                    model.showFolder(photos)
                }
                try app.wait("the run's folder again", timeout: 20) { $0.folder == photos && !$0.library.isListing }
            }
            defer {
                try? showFolderAgain()
                try? app.resetFilter()
            }
            try app.withFilterBar { names in
                let raws = names.filter(FilterScenarios.isRaw)
                try app.typeQuery("type:raw")
                try app.wait("the folder's raws") { $0.items.count == raws.count }
                try app.wait("Search All beside the field, with the library's count", timeout: 20) { _ in
                    guard let root = Views.editorWindow?.contentView?.superview,
                          let button = Views.all(NSButton.self, in: root)
                          .first(where: { $0.accessibilityIdentifier() == "library.filter.search-all" })
                    else { return false }
                    return !button.isHiddenOrHasHiddenAncestor && button.title.contains(where: \.isNumber)
                }
                try app.clickButton("library.filter.search-all")
                try app.wait("All Photographs, filtered by the same query", timeout: 30) { model in
                    model.library.shownSource == .allPhotographs && model.libraryFilters?.filter.text == "type:raw"
                        && model.items.count >= raws.count && model.items.allSatisfy { FilterScenarios.isRaw($0.name) }
                }
                app.covered(.feature("library.filter"), via: .mouse)
                try showFolderAgain()
            }

            try app.press(.commandPalette)
            try app.wait("the palette") { $0.commandPalette != nil }
            _ = try app.searchPalette("type:raw")
            let row = try app.main { $0.commandPalette?.rows.first { $0.kind == .rowAction(.searchAll) } }
            guard let row else { throw ScenarioFailure("The palette has no Search All Photographs row for type:raw") }
            try app.expect(row.title == "Search All Photographs for “type:raw”", "The row is titled \(row.title)")
            try app.choosePaletteRow(row)
            try app.wait("Library, All Photographs, filtered by the text typed", timeout: 30) { model in
                model.module == .library && model.library.shownSource == .allPhotographs
                    && model.libraryFilters?.filter.text == "type:raw" && !model.items.isEmpty
                    && model.items.allSatisfy { FilterScenarios.isRaw($0.name) }
            }
            app.covered([.feature("workspace.palette"), .feature("library.filter")], via: .key)
        }
    }
#endif
