#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDocument
    @_spi(Harness) import RedlampLibrary
    @_spi(Harness) import RedlampUI

    /// Lightroom Classic catalogs (LIB-29), from a catalog the run makes of photos of its own: never one Lightroom
    /// made, and never the run's working folder.
    enum LightroomScenarios {
        static let all: [Scenario] = [importCatalog]

        static let importCatalog = Scenario(
            "library.lightroom",
            "File › Import from Lightroom Classic… reports a catalog of a folder the library doesn't have, Import adds "
                + "the folder and brings its ratings, picks, labels, keywords, title and collections into the photos' "
                + "sidecars, and Undo Import takes them back",
            claims: [.action(.importFromLightroom)],
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
            let report = try app.inLightroomWindow { $0.report }
            try app.expect(
                report?.photos == 3 && report?.waiting == 3 && report?.roots.first?.state == .notInLibrary,
                "the report: \(report.map { $0.lines().joined(separator: " / ") } ?? "none")",
            )
            try app.expect(report?.smartMapped.count == 1 && report?.smartLeft.count == 1, "the smart collections")
            let sidecars = SidecarStore(locator: .besidePhotos)
            let photos = scratch.names.map(scratch.photo)
            try app.expect(photos.allSatisfy { sidecars.load(for: $0) == nil }, "the report wrote nothing")

            try app.clickInLightroomWindow("lightroom.import")
            try app.wait("the import", timeout: 180) { _ in LightroomWindowController.current?.isImported == true }
            let outcome = try app.inLightroomWindow { window in
                window.outcome.map { "\($0.record.photos) \($0.skipped.count)" } ?? (window.problem ?? "nothing")
            }
            try app.expect(outcome == "3 0", "imported: \(outcome)")
            try app.expect(
                try app.main { model in model.library.root(containing: scratch.folder) != nil },
                "the catalog's root folder is in Folders",
            )
            let first = sidecars.load(for: photos[0])?.metadata
            try app.expect(
                first?.rating == 5 && first?.flag == .pick && first?.label == .red && first?.title == "Tram \(tag)"
                    && first?.keywords == ["Places \(tag)/Lisbon"] && first?.collections == ["Lightroom \(tag)/Trip"],
                "the first photo's sidecar: \(String(describing: first))",
            )
            let second = sidecars.load(for: photos[1])?.metadata
            try app.expect(
                second?.flag == .reject && second?.customLabel == "Client \(tag)",
                "the second photo's sidecar: \(String(describing: second))",
            )
            try app.expect(sidecars.load(for: photos[2])?.metadata?.mark == true, "the Quick Collection is the mark")
            try app.wait("the import's keyword in the Keyword List", timeout: 30) { model in
                model.libraryPanels.refreshKeywords()
                return model.libraryPanels.keywordList?.keywords[KeywordPath("Places \(tag)/Lisbon")!]?.photos == 1
            }

            try app.wait("Undo Import", timeout: 30) { _ in
                LightroomWindowController.current?.button("lightroom.undo")?.enabled == true
            }
            try app.clickInLightroomWindow("lightroom.undo")
            try app.wait("the import taken back", timeout: 120) { _ in
                LightroomWindowController.current?.isUndone == true
            }
            for photo in photos {
                let metadata = sidecars.load(for: photo)?.metadata
                try app.expect(
                    metadata == nil || metadata?.isEmpty == true,
                    "\(photo.lastPathComponent)'s sidecar after Undo: \(String(describing: metadata))",
                )
            }
            app.covered(.action(.importFromLightroom), via: .menu)
        }
    }

    extension RunningApp {
        /// Runs `body` on the main thread with the Lightroom Classic window open now.
        @discardableResult
        func inLightroomWindow<T: Sendable>(_ body: @escaping @MainActor (LightroomWindowController) throws -> T)
            throws -> T {
            try main { _ in
                guard let window = LightroomWindowController.current else {
                    throw ScenarioFailure("The Lightroom Classic window isn't open")
                }
                return try body(window)
            }
        }

        /// Clicks the button carrying `identifier` in the Lightroom Classic window through the window, as the mouse
        /// does.
        func clickInLightroomWindow(_ identifier: String) throws {
            let location = try inLightroomWindow { controller -> NSPoint in
                guard let window = controller.window, let content = window.contentView,
                      let control = Self.lightroomView(identifier, in: content)
                else { throw ScenarioFailure("\(identifier) isn't in the Lightroom Classic window") }
                guard control.isHiddenOrHasHiddenAncestor == false, (control as? NSControl)?.isEnabled != false else {
                    throw ScenarioFailure("\(identifier) is hidden or disabled: \(controller.statusText)")
                }
                window.makeKeyAndOrderFront(nil)
                let frame = control.convert(control.bounds, to: nil)
                return NSPoint(x: frame.midX, y: frame.midY)
            }
            post { _ in
                guard let window = LightroomWindowController.current?.window else { return }
                let events = [NSEvent.EventType.leftMouseDown, .leftMouseUp].compactMap { type in
                    NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1,
                    )
                }
                guard events.count == 2 else { return }
                // The button tracks the press, and takes the release from the queue as the mouse's.
                NSApp.postEvent(events[1], atStart: false)
                window.sendEvent(events[0])
            }
            pause(0.2)
        }

        @MainActor private static func lightroomView(_ identifier: String, in view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == identifier {
                return view
            }
            for subview in view.subviews {
                if let found = lightroomView(identifier, in: subview) {
                    return found
                }
            }
            return nil
        }
    }
#endif
