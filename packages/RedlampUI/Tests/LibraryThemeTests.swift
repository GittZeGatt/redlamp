import AppKit
import RedlampDesign
import RedlampLibrary
import SwiftUI
import Testing
@testable import RedlampCanvas
@_spi(Harness) @testable import RedlampUI

/// The Library in the theme's colours, as Develop's panels are (LIB-45): a theme chosen while the Library is shown
/// reaches its grid's cells' text, its Keyword List's rows and its panels' labels, each in the token Develop's panels
/// draw the same role in. Its photos are on Develop's canvas grey in every theme, and no field shows the desktop's
/// tint.
@MainActor
@Suite(.serialized)
struct LibraryThemeTests {
    @Test func `a theme chosen reaches the grid's cells' text, the Keyword List's rows and the panels' labels`(
    ) async throws {
        let fixture = ModuleFixture()
        let suite = "redlamp-tests-theme-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let theme = ThemeSettings(defaults: defaults)
        defer {
            theme.selection = ThemeSelection()
            LibraryLook.follow(theme.selection)
            defaults.removePersistentDomain(forName: suite)
            fixture.cleanUp()
        }
        try await fixture.open(count: 6)
        let model = fixture.model
        model.libraryPanels.keywords = Self.keywords(["Birds", "Places/Portugal/Lisbon"])
        for panel in [LibraryPanels.Panel.photo, .keywordList] where !model.libraryPanels.isExpanded(panel) {
            model.libraryPanels.toggle(panel)
        }
        model.showLibrary(.grid)
        model.setCellStyle(.expanded)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.contentViewController = ModuleViews.make(model: model, theme: theme)
        window.setContentSize(NSSize(width: 1600, height: 1000))
        defer { window.contentViewController = nil }
        let grid = try #require(Self.find(LibraryGridView.self, in: window.contentView))
        try await Self.eventually { grid.cells.values.contains { $0.textImage != nil } }
        let shownKeywords = Self.find(KeywordListPanelView.self, in: window.contentView)

        var chosen = theme.selection
        chosen.familyID = "kanagawa"
        chosen.appearance = .dark
        chosen.tint = 1
        theme.selection = chosen
        let tokens = Palette.current
        #expect(tokens != PaletteTokens.standard, "Kanagawa's tokens, not the neutral ones")

        func named(_ cell: LibraryGridCell) -> Bool {
            cell.textImage.map { Self.inks($0).contains { Self.matches($0, tokens.value) } } == true
        }
        try await Self.eventually { grid.cells.values.contains(where: named) }
        let shown = grid.cells.values.filter { $0.textImage != nil }
        #expect(!shown.isEmpty && shown.allSatisfy(named), "every name on screen in the value colour")

        // The side columns are made again for the theme, as Develop's are.
        try await Self.eventually { Self.find(KeywordListPanelView.self, in: window.contentView) !== shownKeywords }
        window.contentView?.layoutSubtreeIfNeeded()
        let keywords = try #require(Self.find(KeywordListPanelView.self, in: window.contentView))
        let outline = try #require(Self.find(NSOutlineView.self, in: keywords))
        #expect(outline.numberOfRows == 2)
        let row = try #require(outline.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let name = try #require(Self.find(KeywordDragLabel.self, in: row))
        let count = try #require(Self.labels(in: row).first { $0 !== name && $0.alignment == .right })
        #expect(name.stringValue == "Birds" && Self.matches(name.textColor, tokens.label), "a keyword's name")
        #expect(Self.matches(count.textColor, tokens.secondaryLabel), "and its count")

        let photo = try #require(Self.view("photo", in: window.contentView))
        let formLabels = Self.labels(in: photo).filter { $0.stringValue.hasSuffix(":") }
        let value = try #require(Self.view("photo.name", in: photo) as? NSTextField)
        #expect(formLabels.count >= 5, "the Photo panel's form")
        #expect(formLabels.allSatisfy { Self.matches($0.textColor, tokens.label) }, "its labels in the label colour")
        #expect(Self.matches(value.textColor, tokens.value), "its values in the value colour")
    }

    @Test func `the loupe, Compare and Survey are on Develop's canvas grey in a dark theme and a light one`(
    ) async throws {
        let fixture = ModuleFixture()
        // Develop's canvas in a window of its own, for a model of its own: one canvas to a model.
        let developing = ModuleFixture()
        let suite = "redlamp-tests-surround-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let theme = ThemeSettings(defaults: defaults)
        defer {
            fixture.model.lightsOut = 0
            theme.selection = ThemeSelection()
            LibraryLook.follow(theme.selection)
            defaults.removePersistentDomain(forName: suite)
            fixture.cleanUp()
            developing.cleanUp()
        }
        try await fixture.open(count: 4)
        try await developing.open(count: 1)
        let model = fixture.model
        model.showLibrary(.loupe)
        let library = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        library.contentViewController = ModuleViews.make(model: model, theme: theme)
        let develop = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        develop.contentView = NSHostingView(
            rootView: CanvasArea(onOpen: {}).environment(developing.model).environment(theme),
        )
        defer {
            library.contentViewController = nil
            develop.contentView = nil
        }
        let module = try #require(Self.find(LibraryModuleView.self, in: library.contentView))
        try await Self.eventually { Self.find(CanvasMetalView.self, in: develop.contentView) != nil }
        let canvas = try #require(Self.find(CanvasMetalView.self, in: develop.contentView))
        let views: [(String, NSView)] = [
            ("loupe", module.loupe),
            ("Compare", module.compare),
            ("Survey", module.survey),
        ]

        for (family, appearance) in [("kanagawa", ThemeAppearance.dark), ("solarized", .light)] {
            theme.selection = ThemeSelection(familyID: family, appearance: appearance)
            for level in 0 ... 2 {
                model.lightsOut = level
                developing.model.lightsOut = level
                try await Self.eventually {
                    Self.srgb(Self.behind(module.loupe)) == Self.srgb(Self.canvasGrey(canvas.surround))
                        && LibraryLook.tokens == theme.selection.tokens
                }
                let grey = try #require(Self.srgb(Self.canvasGrey(canvas.surround)))
                for (name, view) in views {
                    let behind = try #require(Self.srgb(Self.behind(view)))
                    #expect(Self.close(behind, grey), "\(family) \(appearance), Lights Out \(level): \(name)")
                }
            }
            model.lightsOut = 0
            try await Self.eventually { Self.srgb(Self.behind(module.loupe)) != Self.srgb(LibraryLook.background) }
            #expect(Self.srgb(Self.behind(module.loupe)) != Self.srgb(LibraryLook.background), "not the grid's")

            // What's drawn on the grey takes the family's dark colours, the theme's own in a dark theme.
            let dark = ThemeSelection(familyID: family, appearance: .dark).tokens
            let semibold = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            let name = try #require(Self.labels(in: module.loupe).first { $0.font == semibold })
            #expect(Self.matches(name.textColor, dark.value), "\(family) \(appearance): the loupe's name")
        }
    }

    /// The tint is drawn by the window server on screen, never in a view rendered off it, so this checks what AppKit
    /// reads: the preference behind "Allow wallpaper tinting in windows", in the argument domain, which every other
    /// domain (the app's own, the user's global one) is below.
    @Test func `the app takes the desktop's tint off every field, above the user's own setting, writing nothing`() {
        let key = "AppleReduceDesktopTinting"
        let standard = UserDefaults.standard
        let arguments = standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        var launched = arguments
        launched["redlamp.test.argument"] = true
        launched[key] = nil
        standard.setVolatileDomain(launched, forName: UserDefaults.argumentDomain)

        ThemeSettings.turnOffDesktopTinting()
        #expect(standard.volatileDomain(forName: UserDefaults.argumentDomain)[key] as? Bool == true)
        #expect(standard.bool(forKey: key), "AppKit reads the tint off")
        #expect(standard.bool(forKey: "redlamp.test.argument"), "the launch's other arguments kept")
        let own = Bundle.main.bundleIdentifier.flatMap { standard.persistentDomain(forName: $0) }
        #expect(own?[key] == nil, "nothing written to the app's defaults")
    }

    // MARK: - Helpers

    /// The colour drawn behind `view`: its layer's, or the nearest view's under it that has one.
    static func behind(_ view: NSView) -> CGColor? {
        var current: NSView? = view
        while let shown = current {
            if let color = shown.layer?.backgroundColor {
                return color
            }
            current = shown.superview
        }
        return nil
    }

    /// The grey Develop's canvas clears to, `level` linear in the canvas's colour space (`CanvasMetalView`'s layer's).
    static func canvasGrey(_ level: Double) -> CGColor? {
        CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3).flatMap {
            CGColor(colorSpace: $0, components: [level, level, level, 1])
        }
    }

    /// A colour's sRGB components, to the nearest 1/1000.
    static func srgb(_ color: CGColor?) -> [Double]? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let components = color?.converted(to: space, intent: .defaultIntent, options: nil)?.components
        else { return nil }
        return components.map { ($0 * 1000).rounded() / 1000 }
    }

    static func close(_ color: [Double], _ other: [Double]) -> Bool {
        color.count == other.count && zip(color, other).allSatisfy { abs($0 - $1) < 0.004 }
    }

    /// The keywords `paths` as the library reads them, each on one photo.
    static func keywords(_ paths: [String]) -> PanelKeywords {
        var counts: [KeywordPath: KeywordCount] = [:]
        for path in paths {
            counts[KeywordPath(path)!] = KeywordCount(photos: 1, count: 1)
        }
        let list = KeywordList(counts: counts, definitions: KeywordDefinitions())
        let set = KeywordSet(name: KeywordSet.recentName, keywords: [])
        return PanelKeywords(list: list, completion: KeywordCompletion(list), sets: [set], active: set)
    }

    /// The colours an image's text is drawn in, in sRGB: its glyphs' cores, unblended from their coverage.
    static func inks(_ image: CGImage) -> [RGBA] {
        let (width, height) = (image.width, image.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ), let data = context.data else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let opaque = (0 ..< width * height).map { pixels[$0 * 4 + 3] }.max() ?? 0
        guard opaque > 8 else { return [] }
        return (0 ..< width * height).filter { pixels[$0 * 4 + 3] >= opaque - 8 }.map { index in
            let alpha = Double(pixels[index * 4 + 3])
            return RGBA(
                red: Double(pixels[index * 4]) / alpha, green: Double(pixels[index * 4 + 1]) / alpha,
                blue: Double(pixels[index * 4 + 2]) / alpha,
            )
        }
    }

    /// Whether `color` is `token`'s colour, its alpha left out, to within the rounding of 8-bit pixels.
    static func matches(_ color: RGBA, _ token: RGBA) -> Bool {
        abs(color.red - token.red) < 0.02 && abs(color.green - token.green) < 0.02 && abs(color.blue - token.blue) <
            0.02
    }

    static func matches(_ color: NSColor?, _ token: RGBA) -> Bool {
        guard let color = color?.usingColorSpace(.sRGB) else { return false }
        return matches(RGBA(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent), token)
            && abs(color.alphaComponent - token.alpha) < 0.02
    }

    static func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func find<View: NSView>(_: View.Type, in view: NSView?) -> View? {
        guard let view else { return nil }
        if let found = view as? View {
            return found
        }
        return view.subviews.lazy.compactMap { find(View.self, in: $0) }.first
    }

    static func view(_ identifier: String, in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        return view.subviews.lazy.compactMap { Self.view(identifier, in: $0) }.first
    }

    static func labels(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { subview in
            ((subview as? NSTextField).map { [$0] } ?? []) + labels(in: subview)
        }
    }
}
