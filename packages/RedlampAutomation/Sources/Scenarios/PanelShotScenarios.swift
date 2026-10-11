#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Foundation
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    /// Not in any tier: pictures of the Library's right column, its sheets, Rename Photos, Move Edits and Metadata
    /// and the import window on a card, for setting their looks beside the wireframes and the Mac's own apps (LIB-45)
    /// (`scripts/e2e.py --scenario diagnostics.library-panel-shots`). Each is written to the run's folder as
    /// `shots/<name>.png`; the changes made for them are taken back.
    enum PanelShotScenarios {
        static let all: [Scenario] = [shots]

        static let shots = Scenario(
            "diagnostics.library-panel-shots",
            "Pictures of the Library's right column, its sheets, Rename Photos, Move Edits and Metadata and the import "
                + "window",
            tiers: [],
            claims: [],
        ) { app in
            let folder = app.runDirectory.appending(path: "shots", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            func shoot(_ name: String, _ window: @escaping @MainActor () -> NSWindow?) throws {
                app.pause(0.8)
                let url = folder.appending(path: "\(name).png")
                let written = try app.main { _ in window().map { Snapshot.capture($0, to: url) } ?? false }
                try app.expect(written, "\(name) captured")
            }

            try app.withPanels { _ in
                // Something in every panel: a keyword on one photo only, others and fields on all three.
                try app.selectFromKeyboard(1)
                try app.wait("the panels on one photo") { $0.libraryPanels.selection.ids.count >= 1 }
                try app.main { model in
                    _ = model.libraryPanels.addKeywords("Night")
                    _ = model.libraryPanels.set(.caption, to: "Climbing to Graça")
                }
                try app.waitForPanels()
                let cells = try app.selectFromKeyboard(3)
                let three = Set(cells.prefix(3).joined()).count
                try app.wait("the panels on three cells") { $0.libraryPanels.selection.ids.count == three }
                try app.main { model in
                    let panels = model.libraryPanels
                    _ = panels.addKeywords("Lisbon, Tram, Places > Portugal")
                    for (field, text) in [
                        (MetadataPreset.Field.title, "Tram 28"), (.creator, "Ana Sousa"), (.city, "Lisbon"),
                        (.country, "Portugal"), (.countryCode, "PT"), (.copyright, "© 2026 Ana Sousa"),
                    ] {
                        _ = panels.set(field, to: text)
                    }
                }
                try app.waitForPanels()
                try app.wait("the keywords shown") { model in
                    model.libraryPanels.selection.hasEverywhere(KeywordPath("Tram")!) == true
                        && model.libraryPanels.selection.hasEverywhere(KeywordPath("Night")!) == nil
                }
                try shoot("panels") { Views.editorWindow }

                try app.typeInField("keywording.entry", "tr", returning: false)
                try app.wait("completions for tr") { !$0.libraryPanels.completions("tr").isEmpty }
                try shoot("keywording-completions") { Views.editorWindow }
                try app.pressInWindow(KeyCombo(.escape))
                try app.main { _ in _ = Views.editorWindow?.makeFirstResponder(nil) }

                try app.choose(.editCaptureTime)
                try app.waitForSheet("Edit Capture Time")
                try shoot("sheet-capture-time") { NSApp.modalWindow ?? Views.editorWindow?.attachedSheet }
                try app.pressInSheet(KeyCombo(.escape))
                try app.waitForNoSheet("Edit Capture Time")

                try app.choose("Edit Presets…", inMenuOf: "metadata.presets")
                try app.waitForSheet("Metadata Presets")
                try shoot("sheet-metadata-presets") { NSApp.modalWindow ?? Views.editorWindow?.attachedSheet }
                try app.pressInSheet(KeyCombo(.escape))
                try app.waitForNoSheet("Metadata Presets")

                try app.chooseKeywordRow("Tram")
                try app.choose("Edit Keyword…", inMenuOf: "keywordList.more")
                try app.waitForSheet("Edit Keyword")
                try shoot("sheet-edit-keyword") { NSApp.modalWindow ?? Views.editorWindow?.attachedSheet }
                try app.pressInSheet(KeyCombo(.escape))
                try app.waitForNoSheet("Edit Keyword")

                try app.choose(.renamePhotos)
                try app.waitForSheet("Rename Photos")
                try app.wait("the photos read and named", timeout: 30) { $0.renameSheetNames != nil }
                try shoot("sheet-rename") { NSApp.modalWindow ?? Views.editorWindow?.attachedSheet }
                try app.pressInSheet(KeyCombo(.escape))
                try app.waitForNoSheet("Rename Photos")

                try app.choose(.moveEditsAndMetadata)
                try app.waitForSheet("Move Edits and Metadata")
                try app.wait("the sheet's numbers", timeout: 30) { $0.moveEditsSheet?.isChecked == true }
                try shoot("sheet-move-edits") { NSApp.modalWindow ?? Views.editorWindow?.attachedSheet }
                try app.pressInSheet(KeyCombo(.escape))
                try app.waitForNoSheet("Move Edits and Metadata")
            }

            let card = try ImportCardScratch(app)
            defer { card.remove(app) }
            try app.main { _ in ImportWindowController.ignoresVolumes = true }
            try app.choose(.importPhotos)
            try app.waitForImportWindow()
            try app.inImportWindow { window in
                window.prepare(
                    destination: card.destination, backup: card.backup, folders: "{date:yyyy}/{date:yyyy-MM-dd}",
                    names: "{name}",
                )
            }
            try app.run("adding the card") { _ in try? await ImportWindowController.current?.add(card: card.root) }
            try app.wait("the card browsed", timeout: 60) { _ in
                ImportWindowController.current.map { $0.isBrowsed && $0.photoCount == card.count } == true
            }
            try app.run("the moments", timeout: 30) { _ in }
            app.pause(1)
            try app.inImportWindow { $0.select([0, 1]) }
            for key in ["3", "p"] {
                try app.pressInImportWindow(KeyCombo(.character(Character(key))))
            }
            try shoot("import") { ImportWindowController.current?.window }
        }
    }

#endif
