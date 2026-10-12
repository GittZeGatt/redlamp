#if DEBUG || REDLAMP_PROFILING
    import AppKit
    @_spi(Harness) import RedlampUI

    /// The filmstrip's scroll bar, its thumbnails' sizes, Home and End, and its info line (UX-42).
    enum FilmstripScenarios {
        static let all: [Scenario] = [scrollerAndSizes]

        /// #376: a folder of 200 photos crossed by the scroll bar in one drag; the thumbnails made Large from
        /// View › Filmstrip and Medium by dragging the filmstrip's top edge, the photo fitted above it as it grows
        /// and shrinks; End and Home to the last and first photo; and the info line hidden from the filmstrip's own
        /// menu, with Sync… in a capsule once photos are ⌘-clicked into a selection, above the filmstrip in Develop
        /// and above the toolbar in Library.
        static let scrollerAndSizes = Scenario(
            "library.filmstrip-scroller-and-sizes",
            "The filmstrip's scroll bar across 200 photos, its thumbnails sized from View › Filmstrip and by its top "
                + "edge, Home and End, and its info line hidden, with Sync in a capsule",
            claims: [.feature("library.filmstrip"), .action(.firstPhoto), .action(.lastPhoto)],
            needsFocus: true,
        ) { app in
            let scratch = try SourcesScratch(app, photos: (1 ... 200).map { String(format: "Frame %03d.jpg", $0) })
            defer {
                try? app.main { model in
                    model.filmstripSize = .small
                    model.filmstripShowsInfoLine = true
                    model.filmstripHidesAutomatically = true
                }
                app.removeScratch(scratch)
                try? app.main { $0.showModule(.develop) }
            }
            try scratch.index(app)
            let names = try app.photoNames()
            try app.expect(names.count == 200, "The folder shows \(names.count) photos")
            let (first, second, last) = (names[0], names[1], names[names.count - 1])
            try app.main { model in
                if let url = model.items.first(where: { $0.url.lastPathComponent == first })?.url {
                    model.select(url)
                }
                model.showModule(.develop)
            }
            try app.wait("\(first) open in Develop", timeout: 30) { model in
                model.module == .develop && model.selection?.lastPathComponent == first && model.info != nil
                    && !model.isLoading
            }
            try app.expect(
                try app
                    .main { $0.filmstripHidesAutomatically && $0.filmstripShowsInfoLine && $0.filmstripSize == .small },
                "The filmstrip isn't as it is at first: hiding automatically, with its info line, Small",
            )

            // Kept up, the photo is fitted above it, with the same gaps whatever its height.
            try app.choose("Hide Automatically")
            try app.wait("the filmstrip kept up") { !$0.filmstripHidesAutomatically && $0.makesRoomForFilmstrip }
            try waitInPlace(app, first)
            let (small, gaps) = try app.main { ($0.filmstripHeight, $0.canvas.stageInsets.bottom - $0.filmstripHeight) }
            @MainActor func fitted(_ model: EditorModel) -> Bool {
                let canvas = model.canvas
                let stageBottom = canvas.viewSize.height - canvas.stageInsets.bottom
                return model.makesRoomForFilmstrip
                    && abs(canvas.stageInsets.bottom - model.filmstripHeight - gaps) < 0.5
                    && canvas.imageRect(in: canvas.viewSize).maxY <= stageBottom + 0.5
            }

            // View › Filmstrip › Large Thumbnails: cells about twice today's, in a filmstrip that much taller.
            let large = FilmstripSize.large.title
            try app.choose(large)
            try app.wait("Large Thumbnails, the photo fitted above them") { model in
                model.filmstripSize == .large && model.filmstripHeight == small + 76 && fitted(model)
            }
            try app.wait("View › Filmstrip › \(large) checked") { _ in Menus.isChecked(large) == true }
            try waitInPlace(app, first)
            let cell = try app.frame(of: .filmstrip(first))
            try app.expect(cell.size == CGSize(width: 200, height: 146), "A large cell is \(cell.size)")
            app.covered(.feature("library.filmstrip"), via: .menu)

            // The scroll bar, the app's thin overlay kind, dragged to its end: 200 photos crossed in one movement.
            let scroller = try app.main { _ -> String in
                guard let window = Views.editorWindow,
                      let scroller = Views.shown("filmstrip.\(first)", in: window)?.enclosingScrollView?
                      .horizontalScroller
                else { return "missing" }
                return "\(scroller.scrollerStyle == .overlay ? "overlay" : "legacy"), "
                    + "\(scroller.controlSize == .small ? "small" : "regular")"
            }
            try app.expect(scroller == "overlay, small", "The filmstrip's scroller is \(scroller)")
            try app.expect(try !app.main { _ in showsWhole(last) }, "\(last) is on screen before the drag")
            try app.dragScroller(of: .filmstrip(first), to: 1)
            let dragged = Sighting()
            try app.wait("the drag to bring \(last) on screen; \(dragged.seen)") { model in
                dragged.seen = strip(model)
                return showsWhole(last)
            }
            app.covered(.feature("library.filmstrip"), via: .mouse)

            // The top edge dragged down to Medium (cells 146 to 104 points tall), staying under the pointer.
            if try app.focus() {
                let around = try app.main { model in filmstrip(around: last, model) }
                guard let around else { throw ScenarioFailure("No filmstrip around \(last)") }
                let cell = try app.frame(of: .filmstrip(last))
                let edge = CGPoint(x: 0.5, y: (cell.maxY - (around.maxY - 3)) / cell.height)
                try app.drag(.filmstrip(last), from: edge, by: CGVector(dx: 0, dy: -(146 - 104)))
                app.covered(.feature("library.filmstrip"), via: .mouse)
            } else {
                try app.main { $0.filmstripSize = .medium }
                app.covered(.feature("library.filmstrip"), via: .model)
            }
            let medium = FilmstripSize.medium.title
            try app.wait("Medium Thumbnails from the top edge, the photo fitted above them") { model in
                model.filmstripSize == .medium && model.filmstripHeight == small + 34 && fitted(model)
            }
            try app.wait("View › Filmstrip › \(medium) checked") { _ in Menus.isChecked(medium) == true }
            let size = try app.main { _ in UserDefaults.standard.double(forKey: "app.redlamp.filmstripCellHeight") }
            try app.expect(size == 104, "The size saved is \(size)")

            // End and Home: the last photo and the first, the strip following them.
            try app.press(.lastPhoto)
            try app.wait("End to open \(last)") { $0.selection?.lastPathComponent == last && showsWhole(last) }
            try app.press(.firstPhoto)
            try app.wait("Home to open \(first)") { $0.selection?.lastPathComponent == first && showsWhole(first) }

            // The filmstrip's own menu hides the info line: the filmstrip that much shorter, the photo fitted above.
            try app.focus()
            try waitInPlace(app, first)
            let beside = try CGPoint(x: 1 + 3 / app.frame(of: .filmstrip(first)).width, y: 0.5)
            let menu = try app.rightClick(.filmstrip(first), at: beside, choosing: "Show Info Line")
            let items = ["Hide Automatically", "Show Info Line"] + FilmstripSize.allCases.map(\.title)
            try app.expect(
                menu.map(\.title) == items && menu.map(\.on) == [false, true, false, true, false],
                "The filmstrip's menu has \(menu)",
            )
            try app.wait("the info line hidden, the photo fitted above a shorter filmstrip") { model in
                !model.filmstripShowsInfoLine && model.filmstripHeight == small + 34 - 28 && fitted(model)
            }
            let line = try app.main { _ in
                UserDefaults.standard.object(forKey: "app.redlamp.filmstripShowsInfoLine") as? Bool
            }
            try app.expect(line == false, "The info line saved is \(String(describing: line))")
            try app.expect(try !app.exists(.identifier("filmstrip.status")), "The capsule shows for one photo")
            app.covered(.feature("library.filmstrip"), via: .mouse)

            // A ⌘-click makes a selection: Sync… comes in a capsule just above the filmstrip, which keeps its place.
            try app.tap(.filmstrip(second), modifiers: .command)
            try app.wait("\(second) open with \(first) selected", timeout: 30) { model in
                model.selectedPhotos.count == 2 && model.selection?.lastPathComponent == second && model.info != nil
                    && !model.isLoading
            }
            try waitInPlace(app, second)
            try app.wait("the capsule just above the filmstrip, the photo where it was") { model in
                guard let window = Views.editorWindow, let capsule = Views.find("filmstrip.status", in: window),
                      let around = filmstrip(around: second, model) else { return false }
                return capsule.minY >= around.maxY && capsule.minY <= around.maxY + 12 && fitted(model)
            }
            try app.tap(.identifier("filmstrip.sync"))
            try app.waitForSheet("Sync… from the capsule")
            try app.wait("the sync's checklist") { $0.settingsChooser?.purpose == .sync }
            try app.pressInSheet(KeyCombo(.escape))
            try app.waitForNoSheet("the sync's checklist")

            // In Library the capsule floats above the toolbar, which sits on the docked filmstrip's top edge.
            try app.press(.loupeView)
            let loupe = Sighting()
            try app.wait("Library's loupe, the capsule above its toolbar, Medium cells: \(loupe.seen)") { model in
                guard model.module == .library, model.libraryView == .loupe, let window = Views.editorWindow else {
                    loupe.seen = "in \(model.module), \(model.libraryView)"
                    return false
                }
                let capsule = inLibrary("filmstrip.status", in: window)
                let toolbar = Views.find("library.toolbar", in: window)
                let cell = inLibrary("filmstrip.\(second)", in: window)
                loupe.seen = [("the capsule", capsule), ("the toolbar", toolbar), ("\(second)", cell)]
                    .map { "\($0.0) at \($0.1.map { Views.describe($0) } ?? "nowhere")" }.joined(separator: ", ")
                guard let capsule, let toolbar, let cell else { return false }
                return capsule.minY > toolbar.maxY && cell.height == 104
            }
            try app.press(.developModule)
            try app.wait("Develop again") { $0.module == .develop && fitted($0) }
            try app.press(.deselectOtherPhotos)
            try app.wait("one photo selected, the capsule gone") { model in
                model.selectedPhotos.count == 1
                    && Views.editorWindow.flatMap { Views.find("filmstrip.status", in: $0) } == nil
            }

            // View › Filmstrip brings the line back, and the filmstrip's menu Small Thumbnails.
            try app.choose("Show Info Line")
            try app.wait("the info line back, the photo fitted above it") { model in
                model.filmstripShowsInfoLine && model.filmstripHeight == small + 34 && fitted(model)
            }
            try app.wait("View › Filmstrip › Show Info Line checked") { _ in Menus.isChecked("Show Info Line") == true }
            app.covered(.feature("library.filmstrip"), via: .menu)
            try waitInPlace(app, second)
            let besideSecond = try CGPoint(x: 1 + 3 / app.frame(of: .filmstrip(second)).width, y: 0.5)
            try app.rightClick(.filmstrip(second), at: besideSecond, choosing: FilmstripSize.small.title)
            try app.wait("Small Thumbnails, the filmstrip as it was at first") { model in
                model.filmstripSize == .small && model.filmstripHeight == small && fitted(model)
            }

            try app.choose("Hide Automatically")
            try app.wait("hiding automatically again, the photo given its room back") { model in
                model.filmstripHidesAutomatically && !model.makesRoomForFilmstrip
            }
        }

        /// Waits until `name`'s cell stays put inside the window: the filmstrip slides in, grows and centres the
        /// photo opened in steps.
        private static func waitInPlace(_ app: RunningApp, _ name: String) throws {
            let sighting = Sighting()
            try app.wait("\(name)'s cell in place, last seen \(sighting.seen)") { model in
                guard let window = Views.editorWindow, let cell = Views.find("filmstrip.\(name)", in: window) else {
                    sighting.seen = "nowhere: \(strip(model))"
                    return false
                }
                defer { sighting.last = cell }
                let bounds = window.contentView?.bounds ?? .zero
                guard bounds.contains(cell) else {
                    sighting.seen = "at \(Views.describe(cell)), not wholly in the window's \(Views.describe(bounds))"
                    return false
                }
                let from = sighting.last.map { Views.describe($0) } ?? "nowhere"
                sighting.seen = "moving, from \(from) to \(Views.describe(cell))"
                return sighting.last == cell
            }
        }

        /// Where the filmstrip on screen is scrolled, for a wait's failure, whose record is taken once the scenario
        /// has put everything back: the photos it shows and its clip.
        @MainActor private static func strip(_ model: EditorModel) -> String {
            func onScreen(_ view: NSView) -> Bool {
                var current: NSView? = view
                while let shown = current {
                    guard !shown.isHidden, shown.alphaValue > 0 else { return false }
                    current = shown.superview
                }
                return true
            }
            let open = "\(model.selection?.lastPathComponent ?? "no photo") open"
            guard let root = Views.editorWindow?.contentView?.superview,
                  let scrollView = Views.all(NSScrollView.self, in: root).first(where: { scrollView in
                      onScreen(scrollView) && scrollView.documentView?.subviews
                          .contains { $0.accessibilityIdentifier().hasPrefix("filmstrip.") } == true
                  }), let document = scrollView.documentView
            else { return "no filmstrip on screen, \(open)" }
            let clip = scrollView.contentView.bounds
            let cells = document.subviews.filter { !$0.isHidden && $0.frame.intersects(clip) }
                .sorted { $0.frame.minX < $1.frame.minX }
                .map { $0.accessibilityIdentifier().dropFirst("filmstrip.".count) }
            return "the filmstrip shows \(cells.first ?? "nothing") to \(cells.last ?? "nothing"), its clip at "
                + "\(Views.describe(clip)) of \(Int(document.frame.width)) points, \(open)"
        }

        /// The frame in the window of the view carrying `identifier` in Library's module, beside its toolbar. Library
        /// shows over Develop, which is left in place under it, opaque: `Views.find` finds Develop's filmstrip first.
        @MainActor private static func inLibrary(_ identifier: String, in window: NSWindow) -> NSRect? {
            guard let library = Views.shown("library.toolbar", in: window)?.superview else { return nil }
            return Views.all(NSView.self, in: library)
                .first { !$0.isHiddenOrHasHiddenAncestor && $0.accessibilityIdentifier() == identifier }
                .map { $0.convert($0.bounds, to: nil) }
        }

        /// Whether the filmstrip shows `name`'s cell whole, inside its clip view: a view that doesn't clip to its
        /// bounds has a visible rect beyond them.
        @MainActor private static func showsWhole(_ name: String) -> Bool {
            guard let window = Views.editorWindow, let cell = Views.shown("filmstrip.\(name)", in: window),
                  let clip = cell.enclosingScrollView?.contentView else { return false }
            return clip.bounds.contains(clip.convert(cell.bounds, from: cell))
        }

        /// The filmstrip in the editor window: the strip of photos `name`'s cell is in, and the line of text above
        /// it while that shows.
        @MainActor private static func filmstrip(around name: String, _ model: EditorModel) -> NSRect? {
            guard let window = Views.editorWindow,
                  let strip = Views.shown("filmstrip.\(name)", in: window)?.enclosingScrollView?.superview
            else { return nil }
            var frame = strip.convert(strip.bounds, to: nil)
            frame.size.height = model.filmstripHeight
            return frame
        }
    }

    /// What a wait last saw, for its failure, and the cell's frame `waitInPlace` last found; only touched on main until
    /// the wait is over.
    private final class Sighting: @unchecked Sendable {
        var last: NSRect?
        var seen = "nowhere"
    }
#endif
