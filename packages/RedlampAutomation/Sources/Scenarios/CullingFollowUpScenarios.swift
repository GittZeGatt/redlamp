#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDocument
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    /// Culling's follow-ups (LIB-15, LIB-24, DEC-62), each on a scratch folder of its own: custom labels named with
    /// their colours and recoloured, a change some photos didn't get said over them, B on the target collection, and
    /// with `.xmp` writing on, Undo giving another app's label back.
    enum CullingFollowUpScenarios {
        static let all: [Scenario] = [customLabelColors, problem, targetB, xmpUndo]

        /// What `photo`'s sidecar holds, where the library keeps it.
        @MainActor static func sidecar(_ photo: URL, in model: EditorModel) -> PhotoMetadata? {
            model.library.sidecars.store(for: photo).load(for: photo)?.metadata
        }

        /// The custom label `photo` shows.
        @MainActor static func label(of photo: URL, in model: EditorModel) -> String? {
            model.library.item(for: photo)?.metadata.customLabel
        }

        static let customLabelColors = Scenario(
            "library.custom-label-colors",
            "Custom Labels… from a cell's menu names a label with its colour and gives it to that photo; the Photo "
                + "menu gives it with its colour; the sheet from the Photo menu recolours every photo of it, with ⌘Z; and "
                + "in Compare and Survey the Photo menu's label reaches the active photo alone",
            claims: [.feature("library.ratings"), .action(.undo), .action(.compareView), .action(.surveyView)],
        ) { app in
            let scratch = try SourcesScratch(app, photos: ["A.jpg", "B.jpg", "C.jpg"])
            let depth = try app.main { $0.cullingUndoCount }
            defer {
                try? app.takeBackCulling(to: depth)
                scratch.remove(app)
            }
            try scratch.index(app)
            let (a, b, c) = (scratch.photo("A.jpg"), scratch.photo("B.jpg"), scratch.photo("C.jpg"))
            let name = "E2E Urgent \(scratch.folder.lastPathComponent.suffix(8))"

            // A cell's menu: Set Color Label ▸ Custom Labels…, a name and Teal.
            try app.click(.identifier("grid.A.jpg"))
            let cell = try app.frame(of: .identifier("grid.A.jpg"))
            try app.chooseInContextMenu(
                "Custom Labels…", at: NSPoint(x: cell.midX, y: cell.midY), submenu: "Set Color Label",
            )
            try app.waitForSheet("Custom Labels")
            try app.typeInAttachedSheet(name)
            try app.chooseInCollectionSheet("labels.new.color", "Teal")
            try app.confirmCollectionSheet("Custom Labels")
            try app.wait("A labelled at once") { label(of: a, in: $0) == name }
            try app.waitWritten()
            try app.wait("A's sidecar holding the label in teal", timeout: 15) { model in
                sidecar(a, in: model)?.customLabel == name && sidecar(a, in: model)?.customLabelColor == .teal
            }
            app.covered(.feature("library.ratings"), via: .mouse)

            // The Photo menu gives it to B with its colour.
            try app.click(.identifier("grid.B.jpg"))
            try app.wait("the label in the Photo menu") { $0.customLabels.contains(name) }
            try app.choose(name)
            try app.waitWritten()
            try app.wait("B's sidecar holding the label in teal", timeout: 15) { model in
                sidecar(b, in: model)?.customLabelColor == .teal
            }
            app.covered(.feature("library.ratings"), via: .menu)

            // Its colour chosen again from the Photo menu's sheet reaches both, and ⌘Z puts teal back.
            try app.choose("Custom Labels…")
            try app.waitForSheet("Custom Labels")
            try app.chooseInCollectionSheet("labels.color.\(name)", "Pink")
            try app.confirmCollectionSheet("Custom Labels")
            try app.wait("pink in A's and B's sidecars", timeout: 20) { model in
                sidecar(a, in: model)?.customLabelColor == .pink && sidecar(b, in: model)?.customLabelColor == .pink
            }
            try app.wait("the label pink") { $0.customLabelColor(of: name) == .pink }
            try app.press(.undo)
            try app.wait("teal again in A's and B's sidecars", timeout: 20) { model in
                sidecar(a, in: model)?.customLabelColor == .teal && sidecar(b, in: model)?.customLabelColor == .teal
            }
            app.covered(.action(.undo), via: .key)

            // B and C both labelled, C active: in Compare the label comes off C alone.
            try app.main { model in
                model.select(b)
                model.click(c, toggling: true)
            }
            try app.choose(name)
            try app.wait("B and C labelled") { model in
                label(of: b, in: model) == name && label(of: c, in: model) == name
            }
            try app.press(.compareView)
            try app.wait("Compare, C active") { $0.libraryView == .compare && $0.selection == c }
            try app.choose(name)
            try app.wait("the label off C alone") { model in
                label(of: c, in: model) == nil && label(of: b, in: model) == name
            }
            app.covered(.action(.compareView), via: .key)

            // In Survey, B made active with ←, it comes off B alone.
            try app.press(.surveyView)
            try app.wait("Survey") { $0.libraryView == .survey }
            try app.press(.previousPhoto)
            try app.wait("B active") { $0.selection == b }
            try app.choose(name)
            try app.wait("the label off B alone") { model in
                label(of: b, in: model) == nil && label(of: c, in: model) == nil
            }
            app.covered(.action(.surveyView), via: .key)
            try app.press(.gridView)
            try app.waitWritten()
        }

        static let problem = Scenario(
            "library.culling-problem",
            "A rating a photo's sidecar can't take is said over the grid, naming the photo; Select selects it, Try "
                + "Again gives it the rating once its sidecar can take it, and Close closes another",
            claims: [.feature("library.ratings"), .action(.rating3)],
        ) { app in
            let scratch = try SourcesScratch(app, photos: ["A.jpg", "B.jpg", "C.jpg"])
            let depth = try app.main { $0.cullingUndoCount }
            let b = scratch.photo("B.jpg")
            var edit: URL?
            defer {
                if let edit {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: edit.path)
                }
                try? app.takeBackCulling(to: depth)
                scratch.remove(app)
            }
            try scratch.index(app)

            // B's own sidecar first, which then can't be read.
            try app.click(.identifier("grid.B.jpg"))
            try app.press(.rating1)
            try app.waitWritten()
            try app.wait("B's sidecar", timeout: 15) { sidecar(b, in: $0)?.rating == 1 }
            let sidecarEdit = try app.main { $0.library.sidecars.store(for: b).editURL(for: b) }
            edit = sidecarEdit
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: sidecarEdit.path)

            try app.press(.selectAllPhotos)
            try app.wait("every photo selected") { $0.selectedPhotos.count == 3 }
            try app.press(.rating3)
            try app.waitWritten()
            try app.wait("the photo it didn't reach said over the grid", timeout: 15) { model in
                model.cullingProblem?.photos == [b]
            }
            try app.expect(try app.exists(.identifier("library.cullingProblem")), "No strip over the grid")
            let message = try app.main { $0.cullingProblem?.message ?? "" }
            try app.expect(message.hasPrefix("3 Stars wasn't saved to B.jpg"), "The strip says \(message)")

            try app.tap(.identifier("library.cullingProblem.select"))
            try app.wait("B selected") { $0.selectedPhotos.map(\.lastPathComponent) == ["B.jpg"] }
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sidecarEdit.path)
            try app.tap(.identifier("library.cullingProblem.retry"))
            try app.waitWritten()
            try app.wait("B's three stars, and the strip gone", timeout: 15) { model in
                model.cullingProblem == nil && sidecar(b, in: model)?.rating == 3
            }

            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: sidecarEdit.path)
            try app.press(.rating5)
            try app.waitWritten()
            try app.wait("another said", timeout: 15) { $0.cullingProblem?.title == "5 Stars" }
            try app.tap(.identifier("library.cullingProblem.close"))
            try app.wait("the strip closed") { $0.cullingProblem == nil }
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sidecarEdit.path)
            app.covered(.feature("library.ratings"), via: .mouse)
            app.covered(.action(.rating3), via: .key)
        }

        static let targetB = Scenario(
            "library.target-collection-b",
            "With a collection the target, B puts the photos selected in it, B again takes them out and ⌘Z puts them "
                + "back; with Marked the target, B marks them",
            claims: [.action(.toggleMark), .feature("library.collections")],
        ) { app in
            let scratch = try SourcesScratch(app, photos: ["A.jpg", "B.jpg"])
            let depth = try app.main { $0.cullingUndoCount }
            defer {
                try? app.takeBackCulling(to: depth)
                app.removeCollectionsMade()
                scratch.remove(app)
            }
            try scratch.index(app)
            let (a, b) = (scratch.photo("A.jpg"), scratch.photo("B.jpg"))
            let picks = "Picks \(scratch.folder.lastPathComponent.suffix(8))"
            let row = "collections.\(picks)"

            try app.click(.identifier("grid.A.jpg"))
            try app.press(.newCollection)
            try app.waitForSheet("New Collection")
            try app.replaceInSheet("collections.name", with: picks)
            try app.pressInSheet("collections.target")
            try app.confirmCollectionSheet("New Collection")
            try app.waitForRow(row, "\(picks), 0 photos, target collection", "the target")

            try app.press(.selectAllPhotos)
            try app.wait("both selected") { $0.selectedPhotos.count == 2 }
            try app.press(.toggleMark)
            try app.waitForRow(row, "\(picks), 2 photos, target collection", "B putting both in the target")
            let marked = try app
                .main { model in [a, b].contains { model.library.item(for: $0)?.metadata.mark == true } }
            try app.expect(!marked, "B marked them")
            try app.press(.toggleMark)
            try app.waitForRow(row, "\(picks), 0 photos, target collection", "B again taking them out")
            try app.press(.undo)
            try app.waitForRow(row, "\(picks), 2 photos, target collection", "⌘Z putting them back")

            try app.rightClickSourceRow("sources.marked", choosing: "Set as Target Collection")
            try app.wait("Marked the target", timeout: 30) { $0.librarySources.target == nil }
            try app.press(.toggleMark)
            try app.wait("both marked") { model in
                [a, b].allSatisfy { model.library.item(for: $0)?.metadata.mark == true }
            }
            try app.waitWritten()
            app.covered(.action(.toggleMark), via: .key)
        }

        static let xmpUndo = Scenario(
            "library.xmp-undo",
            "With .xmp writing on, a label set over the one another app left in a photo's .xmp, then taken back with ⌘Z, "
                + "gives the .xmp that app's label again",
            claims: [.feature("library.ratings"), .action(.labelYellow), .action(.undo)],
        ) { app in
            let scratch = try SourcesScratch(app, photos: ["A.jpg"])
            let depth = try app.main { $0.cullingUndoCount }
            defer {
                try? app.takeBackCulling(to: depth)
                try? app.main { model in
                    let service = model.library.service
                    Task { _ = await service?.setXMPSettings(XMPSettings()) }
                }
                try? app.wait("writing .xmp off") { $0.library.service?.xmpSettings?.writes == false }
                scratch.remove(app)
            }
            let a = scratch.photo("A.jpg")
            // Lightroom's label, there before Redlamp first reads the photo.
            let lightroom = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0">
             <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="2" xmp:Label="Red"/>
             </rdf:RDF>
            </x:xmpmeta>

            """
            try Data(lightroom.utf8).write(to: RunningApp.xmpURL(of: a))
            try app.wait("the library to open", timeout: 60) { $0.library.service?.isReady == true }
            try app.main { model in
                let service = model.library.service
                Task { _ = await service?.setXMPSettings(XMPSettings(writes: true)) }
            }
            try app.wait("writing .xmp on") { $0.library.service?.xmpSettings?.writes == true }
            try scratch.index(app)

            try app.click(.identifier("grid.A.jpg"))
            try app.press(.labelYellow)
            try app.waitWritten()
            try app.waitXMPSynced()
            try app.waitInXMP(a, "Redlamp's yellow") { $0?.label == .yellow }
            try app.press(.undo)
            try app.waitWritten()
            try app.waitXMPSynced()
            try app.waitInXMP(a, "Lightroom's red again") { $0?.label == .red && $0?.rating == 2 }
            app.covered([.feature("library.ratings"), .action(.undo)], via: .key)
        }
    }
#endif
