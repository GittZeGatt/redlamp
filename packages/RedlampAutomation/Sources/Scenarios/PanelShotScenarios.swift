#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Foundation
    import RedlampDesign
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
            /// The right column's every panel, top to bottom, on a background of the window's appearance.
            func shootColumn(_ name: String) throws {
                app.pause(0.8)
                let url = folder.appending(path: "\(name).png")
                let written = try app.main { _ -> Bool in
                    guard let window = Views.editorWindow, let document = rightColumn()?.scrollView.documentView,
                          let drawn = document.bitmapImageRepForCachingDisplay(in: document.bounds),
                          let picture = NSBitmapImageRep(
                              bitmapDataPlanes: nil, pixelsWide: drawn.pixelsWide, pixelsHigh: drawn.pixelsHigh,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
                          ),
                          let context = NSGraphicsContext(bitmapImageRep: picture)
                    else { return false }
                    document.cacheDisplay(in: document.bounds, to: drawn)
                    picture.size = document.bounds.size
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = context
                    // The panels' own background is glass, which a picture of them alone doesn't show.
                    let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    NSColor(white: dark ? 0.12 : 0.94, alpha: 1).setFill()
                    NSRect(origin: .zero, size: picture.size).fill()
                    drawn.draw(in: NSRect(origin: .zero, size: picture.size))
                    NSGraphicsContext.restoreGraphicsState()
                    return (try? picture.representation(using: .png, properties: [:])?.write(to: url)) != nil
                }
                try app.expect(written, "\(name) captured")
            }
            /// Library's right column: Develop's inspector stays in the window, out of sight, while Library is shown.
            @MainActor func rightColumn() -> PanelColumnScrollView? {
                guard let root = Views.editorWindow?.contentView else { return nil }
                return Views.all(PanelColumnScrollView.self, in: root)
                    .first { String(describing: type(of: $0)) == "LibraryInfoColumn" }
            }
            // The windows at one size, whatever they were left at.
            try app.main { _ in
                guard let window = Views.editorWindow, let area = (window.screen ?? NSScreen.main)?.visibleFrame
                else { return }
                let size = NSSize(width: min(1440, area.width), height: min(940, area.height))
                window.setFrame(
                    NSRect(
                        x: area.midX - size.width / 2,
                        y: area.midY - size.height / 2,
                        width: size.width,
                        height: size.height,
                    ), display: true,
                )
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
                try shootColumn("panels-column")

                try app.typeInField("keywording.entry", "tr", returning: false)
                try app.wait("completions for tr") { !$0.libraryPanels.completions("tr").isEmpty }
                try shootColumn("keywording-completions")
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
            app.pause(1)
            try app.inImportWindow { window in
                guard let frame = window.window?.frame, let area = window.window?.screen?.visibleFrame else { return }
                let size = NSSize(width: min(1180, area.width), height: min(740, area.height))
                window.window?.setFrame(
                    NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height),
                    display: true,
                )
            }
            try app.inImportWindow { $0.select([0, 1]) }
            for key in ["3", "p"] {
                try app.pressInImportWindow(KeyCombo(.character(Character(key))))
            }
            try shoot("import") { ImportWindowController.current?.window }
        }
    }

#endif
