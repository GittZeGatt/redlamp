import AppKit
import Foundation
import QuartzCore
import RedlampDocument
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// The filter bar in the editor window's content (LIB-45): a key typed in its text through the field editor, as
/// the keyboard types it, timed on the main thread and until its photos are on screen; and pictures of the bar.
@MainActor
extension LibraryFilterTests {
    /// Photos enough for each key to change what the filter finds: four cameras, every rating, flags and labels.
    static let many: [Photo] = (0 ..< 400).map { index in
        let cameras = [
            ("FUJIFILM", "X-T5"),
            ("Canon", "Canon EOS R5"),
            ("NIKON CORPORATION", "NIKON Z 6"),
            ("SONY", "ILCE-7M4"),
        ]
        let (make, model) = cameras[index % cameras.count]
        let day = 1 + index % 28
        return Photo(
            path: String(format: "P%04d.JPG", index), make: make, model: model, iso: 100 << (index % 6),
            date: String(format: "2024:%02d:%02d 10:%02d:00", 1 + index % 12, day, index % 60),
            rating: index % 6, flag: index % 7 == 0 ? .pick : index % 11 == 0 ? .reject : nil,
            label: index % 5 == 0 ? .red : index % 5 == 1 ? .blue : nil,
        )
    }

    /// The editor window's content as the app builds it, 1,600 by 1,000 points, showing the Library grid with the
    /// filter bar.
    func barWindow(_ model: EditorModel) -> NSWindow {
        model.showLibrary(.grid)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false,
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = ModuleViews.make(model: model, theme: ThemeSettings())
        window.setContentSize(NSSize(width: 1600, height: 1000))
        return window
    }

    @Test func `a query's text splits into terms at spaces outside quotes and parentheses`() {
        #expect(FilterQueryTerms.split("camera:\"Canon EOS R5\"  rating>=3 (kw:a OR kw:b) -flag:reject OR x") == [
            "camera:\"Canon EOS R5\"", "rating>=3", "(kw:a OR kw:b)", "-flag:reject", "OR", "x",
        ])
        #expect(FilterQueryTerms.joined(["rating>=3", " tr"]) == "rating>=3 tr")
        #expect(FilterQueryTerms.joined(["is:soft "]) == "is:soft ", "a term finished by a space keeps it")
        #expect(FilterQueryTerms.isOpen("camera:\"Canon E") && FilterQueryTerms.isOpen("(kw:a OR"))
        #expect(!FilterQueryTerms.isOpen("camera:\"Canon EOS\""))
        #expect(FilterQueryTerms.isFinished("kw:a ") && !FilterQueryTerms.isFinished("kw:a"))
        #expect(!FilterQueryTerms.isFinished("camera:\"Canon "), "a space inside quotes doesn't end the term")
        #expect(FilterQueryTerms.closed("camera:\"Canon E") == "camera:\"Canon E\"")
        #expect(FilterQueryTerms.closed("(kw:a OR (kw:b") == "(kw:a OR (kw:b))")
    }

    @Test func `terms typed become tokens at a space, a quoted value one token, and a token taken out changes the text`(
    ) async throws {
        defer { cleanUp() }
        let (model, _) = try await open()
        let filters = try #require(model.libraryFilters)
        let window = barWindow(model)
        defer { window.contentViewController = nil }
        let bar = try #require(Self.find(LibraryFilterBarView.self, in: window.contentView))
        for character in "camera:\"Canon EOS R5\" rating>=3 dsc" {
            #expect(LibraryFilterBars.type(String(character), in: window))
        }
        #expect(bar.field.pieces == [.token("camera:\"Canon EOS R5\""), .token("rating>=3"), .typing("dsc")])
        #expect(filters.filter.text == "camera:\"Canon EOS R5\" rating>=3 dsc")
        try await listed(model)
        #expect(names(model) == ["DSC_0005.JPG"])

        let editor = try #require(bar.field.currentEditor() as? NSTextView)
        editor.selectedRange = NSRange(location: 1, length: 1)
        editor.deleteBackward(nil)
        // A selection away from the text being typed makes it a token, as a token field does.
        #expect(bar.field.pieces == [.token("camera:\"Canon EOS R5\""), .token("dsc")])
        #expect(filters.filter.text == "camera:\"Canon EOS R5\" dsc")

        // Return gives the grid the keyboard, the term being typed a token.
        editor.selectedRange = NSRange(location: editor.string.utf16.count, length: 0)
        filters.endCompletion()
        try await eventually { bar.completions.isHidden }
        _ = bar.control(bar.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect((window.firstResponder as? NSTextView)?.delegate !== bar.field)
        #expect(bar.field.pieces == [.token("camera:\"Canon EOS R5\""), .token("dsc")])
        #expect(filters.filter.text == "camera:\"Canon EOS R5\" dsc")
    }

    @Test func `a completion taken with Tab is a token, and a field's stays text for its value`() async throws {
        defer { cleanUp() }
        let (model, _) = try await open()
        let filters = try #require(model.libraryFilters)
        let window = barWindow(model)
        defer { window.contentViewController = nil }
        let bar = try #require(Self.find(LibraryFilterBarView.self, in: window.contentView))
        for character in "rating>=3 camera:fu" {
            LibraryFilterBars.type(String(character), in: window)
        }
        try await eventually { filters.completions.first?.title == "Fujifilm X-T5" && !bar.completions.isHidden }
        #expect(
            !bar.completions.isHidden && bar.completions.frame.minX > bar.field.frame.minX + 40,
            "the completions under the term being typed, past the token before it",
        )
        let editor = try #require(bar.field.currentEditor() as? NSTextView)
        #expect(bar.control(bar.field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(filters.filter.text == "rating>=3 camera:\"Fujifilm X-T5\" ")
        #expect(bar.field.pieces == [.token("rating>=3"), .token("camera:\"Fujifilm X-T5\"")])
        try await eventually { bar.completions.isHidden }

        // ⌫ after a token takes it out, as it takes out a character.
        editor.deleteBackward(nil)
        #expect(bar.field.pieces == [.token("rating>=3")] && filters.filter.text == "rating>=3")
        for character in " camera:fu" {
            LibraryFilterBars.type(String(character), in: window)
        }
        try await eventually { filters.completions.first?.title == "Fujifilm X-T5" && !bar.completions.isHidden }
        #expect(bar.control(bar.field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))

        for character in "ori" {
            LibraryFilterBars.type(String(character), in: window)
        }
        try await eventually { filters.completions.first?.text == "orientation:" && !bar.completions.isHidden }
        #expect(bar.control(bar.field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(bar.field.pieces.last == .typing("orientation:"), "the field's name stays text, its value to come")
        #expect(filters.filter.text == "rating>=3 camera:\"Fujifilm X-T5\" orientation:")
    }

    @Test func `tokens dragged or pasted go as the query's text, and come back as its terms`() async throws {
        defer { cleanUp() }
        let (model, _) = try await open()
        let window = barWindow(model)
        defer { window.contentViewController = nil }
        let bar = try #require(Self.find(LibraryFilterBarView.self, in: window.contentView))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("redlamp-filter-bar-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(bar.tokenField(bar.field, writeRepresentedObjects: ["kw:a", "camera:\"Canon EOS\""], to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "kw:a camera:\"Canon EOS\"")
        let read = bar.tokenField(bar.field, readFrom: pasteboard) as? [String]
        #expect(read == ["kw:a", "camera:\"Canon EOS\""])
        let added = bar.tokenField(bar.field, shouldAdd: ["camera:\"Canon", "EOS\"", "(kw:a"], at: 0) as? [String]
        #expect(added == ["camera:\"Canon EOS\"", "(kw:a)"], "split at the space inside quotes, then closed")
        #expect(bar.tokenField(bar.field, styleForRepresentedObject: "rating>=3") == .rounded)
        #expect(bar.tokenField(bar.field, styleForRepresentedObject: "OR") == .plainSquared)
        #expect(
            bar.tokenField(bar.field, styleForRepresentedObject: "rating>=9") == .plainSquared,
            "what can't be read",
        )
    }

    @Test func `the bar offers the whole library's count beside the field, which searches All Photographs`(
    ) async throws {
        defer { cleanUp() }
        let (model, _) = try await open()
        let filters = try #require(model.libraryFilters)
        let window = barWindow(model)
        defer { window.contentViewController = nil }
        let bar = try #require(Self.find(LibraryFilterBarView.self, in: window.contentView))
        let button = try #require(Self.view("library.filter.search-all", in: bar) as? NSButton)
        #expect(button.isHidden, "no query, nothing to search everywhere")
        try await filtered(model, "camera:X-T5")
        try await eventually { !button.isHidden }
        #expect(button.title == "Search All Photographs", "the library not counted yet")
        // The Library panel counts the library while it's in the window.
        model.librarySources.recount()
        await model.librarySources.counted()
        try await eventually { !button.isHidden && button.title == "Search All 6" }
        #expect(!button.isHidden && button.title == "Search All 6", "the library's six, the one in Below among them")
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(button.frame.minX >= bar.field.frame.maxX, "beside the field")

        button.performClick(nil)
        try await eventually { model.library.shownSource == .allPhotographs && !model.library.isListing }
        try await listed(model)
        #expect(model.library.shownSource == .allPhotographs && filters.filter.text == "camera:X-T5")
        #expect(Set(names(model)) == ["IMG_0001.JPG", "IMG_0002.JPG", "IMG_0006.JPG"])
        try await eventually { button.isHidden }
        #expect(button.isHidden, "All Photographs is the whole library")
    }

    @Test(.measuresSpeed)
    func `a key typed in the bar is on screen soon, and costs the main thread little`() async throws {
        defer { cleanUp() }
        let (model, _) = try await open(Self.many)
        let filters = try #require(model.libraryFilters)
        let window = barWindow(model)
        defer { window.contentViewController = nil }
        model.perform(.toggleFilterBar)
        try await eventually { filters.isBarShown }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let queries = ["camera:\"EOS R5\" rating>=2 -flag:reject", "P01", "label:red rating>=4", "iso>=800 -label:blue"]
        var keys: [Double] = []
        var drawn: [Double] = []
        var onScreen: [Double] = []
        var missed = 0
        for pass in 0 ..< 3 {
            for query in queries {
                LibraryFilterBars.clear(in: window)
                try await eventually { filters.lastListed?.query == nil }
                var typed = ""
                for character in query {
                    let before = (try? LibraryQuery(parsing: typed, asYouType: true)) ?? .all
                    typed.append(character)
                    let started = CACurrentMediaTime()
                    #expect(LibraryFilterBars.type(String(character), in: window))
                    let typedAt = CACurrentMediaTime()
                    window.displayIfNeeded()
                    CATransaction.flush()
                    let drawnAt = CACurrentMediaTime()
                    // The first pass warms the views and the engine up; it isn't counted.
                    if pass > 0 {
                        keys.append((typedAt - started) * 1000)
                        drawn.append((drawnAt - started) * 1000)
                    }
                    guard let after = try? LibraryQuery(parsing: typed, asYouType: true), after != before else {
                        continue
                    }
                    let wanted = after == .all ? nil : after
                    while filters.lastListed?.query != wanted, CACurrentMediaTime() - started < 1 {
                        try await Task.sleep(for: .microseconds(250))
                    }
                    guard filters.lastListed?.query == wanted else {
                        missed += 1
                        continue
                    }
                    window.displayIfNeeded()
                    CATransaction.flush()
                    if pass > 0 {
                        onScreen.append((CACurrentMediaTime() - started) * 1000)
                    }
                }
            }
        }
        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
        }
        let summary = String(
            format: "LIB-45 typing, %d photos: %d keys, the key's own work p50 %.2f ms, p95 %.2f ms; drawn p50 %.2f ms, "
                +
                "p95 %.2f ms; %d keys changing the photos, on screen p50 %.2f ms, p95 %.2f ms, max %.2f ms; %d missed",
            Self.many.count, keys.count, percentile(keys, 0.5), percentile(keys, 0.95), percentile(drawn, 0.5),
            percentile(drawn, 0.95), onScreen.count, percentile(onScreen, 0.5), percentile(onScreen, 0.95),
            onScreen.max() ?? 0, missed,
        )
        print(summary)
        if let path = ProcessInfo.processInfo.environment["REDLAMP_FILTER_TYPING_LOG"] {
            let line = Data((summary + "\n").utf8)
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            } else {
                FileManager.default.createFile(atPath: path, contents: line)
            }
        }
        #expect(missed == 0, "every key's photos listed within a second")
        #expect(percentile(drawn, 0.95) < 50, "\(summary)")
    }

    /// Pictures of the bar for the polish's record (LIB-45), when `REDLAMP_POLISH_SHOTS` names a folder: the window
    /// and the bar alone, with a query typed, with its sections open, with completions, and finding nothing. Each
    /// is called `REDLAMP_POLISH_SHOTS_PREFIX`-name.png.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_POLISH_SHOTS"] != nil))
    func `pictures of the bar`() async throws {
        defer { cleanUp() }
        let folder = try #require(ProcessInfo.processInfo.environment["REDLAMP_POLISH_SHOTS"])
        let prefix = ProcessInfo.processInfo.environment["REDLAMP_POLISH_SHOTS_PREFIX"] ?? "shot"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let (model, _) = try await open()
        let filters = try #require(model.libraryFilters)
        let window = barWindow(model)
        defer { window.contentViewController = nil }
        model.perform(.toggleFilterBar)
        try await eventually { filters.isBarShown }

        func shoot(_ name: String) async throws {
            try await Task.sleep(for: .milliseconds(300))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            guard let root = window.contentView?.superview ?? window.contentView,
                  let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
            root.cacheDisplay(in: root.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appending(path: "\(prefix)-\(name)-window.png"))
            guard let bar = Self.find(LibraryFilterBarView.self, in: window.contentView) else { return }
            var frame = bar.convert(bar.bounds, to: root)
            frame = frame.insetBy(dx: 0, dy: -60).intersection(root.bounds)
            guard let crop = root.bitmapImageRepForCachingDisplay(in: frame) else { return }
            root.cacheDisplay(in: frame, to: crop)
            try crop.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appending(path: "\(prefix)-\(name).png"))
        }

        filters.setText("camera:X-T5 rating>=2 -flag:reject")
        try await listed(model)
        try await shoot("query")

        filters.setFilter(LibraryFilter(text: "rating>=3", sections: [.text, .attribute, .metadata]))
        try await eventually { filters.columns.count == 4 }
        try await shoot("sections")

        filters.setFilter(LibraryFilter(text: "camera:f", sections: [.text]))
        filters.complete("camera:f", cursor: 8)
        try await eventually { !filters.completions.isEmpty }
        try await shoot("completions")
        filters.endCompletion()

        filters.setText("camera:X-T5 kw:zzzz")
        try await eventually { filters.removal != nil }
        try await shoot("nothing-found")
    }
}
