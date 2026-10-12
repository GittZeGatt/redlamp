import AppKit
import Foundation
import RedlampDesign
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// The small symbol buttons of the sidebars' headers and of the Library's filter field (LIB-45): each glyph drawn at
/// the symbol's own size and shape, its strokes on whole pixels, at 1x as well as 2x. For a 1x screen AppKit draws a
/// symbol stretched, and a button cell centres one by its alignment rect, which can leave it on half a pixel: the
/// source list header's + came out 11.5 pixels wide and 8.7 tall, its upright blurred across four columns.
@MainActor
@Suite(.serialized)
struct SymbolButtonPixelsTests {
    /// A window at a scale of its own on any screen.
    private final class ScaledWindow: NSWindow {
        var scale: CGFloat = 1

        override var backingScaleFactor: CGFloat {
            scale
        }
    }

    private func window(_ view: NSView, size: CGSize, scale: CGFloat) -> ScaledWindow {
        _ = NSApplication.shared
        let window = ScaledWindow(
            contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false,
        )
        window.scale = scale
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return window
    }

    /// A symbol as a control draws it: how much of each pixel it covers, from 0 to 1, the top row first.
    struct Glyph {
        let width: Int
        let height: Int
        /// Pixels to a point.
        let scale: Double
        let values: [Double]

        subscript(x: Int, y: Int) -> Double {
            x >= 0 && y >= 0 && x < width && y < height ? values[y * width + x] : 0
        }

        func row(_ y: Int) -> [Double] {
            (0 ..< width).map { self[$0, y] }
        }

        func column(_ x: Int) -> [Double] {
            (0 ..< height).map { self[x, $0] }
        }

        /// The ink's spread across and down, in points: the standard deviations of its coverage.
        var spread: (across: Double, down: Double) {
            var total = 0.0, x = 0.0, y = 0.0, xx = 0.0, yy = 0.0
            for row in 0 ..< height {
                for column in 0 ..< width {
                    let value = self[column, row], px = Double(column) + 0.5, py = Double(row) + 0.5
                    total += value
                    x += value * px
                    y += value * py
                    xx += value * px * px
                    yy += value * py * py
                }
            }
            let (mx, my) = (x / total, y / total)
            return ((xx / total - mx * mx).squareRoot() / scale, (yy / total - my * my).squareRoot() / scale)
        }

        /// Its columns `range`, their alpha as a share of their most opaque pixel's.
        func columns(_ range: Range<Int>) -> Glyph {
            let range = max(range.lowerBound, 0) ..< min(range.upperBound, width)
            let values = (0 ..< height).flatMap { y in range.map { self[$0, y] } }
            let most = max(values.max() ?? 0, 0.0001)
            return Glyph(width: range.count, height: height, scale: scale, values: values.map { $0 / most })
        }

        /// The runs of columns with ink in them, apart by two empty columns or more, from the left.
        var inkedColumns: [Range<Int>] {
            var runs: [Range<Int>] = []
            var run: (first: Int, last: Int)?
            for x in 0 ..< width where column(x).contains(where: { $0 > 0.02 }) {
                if let current = run, x - current.last > 2 {
                    runs.append(current.first ..< current.last + 1)
                    run = nil
                }
                run = (run?.first ?? x, x)
            }
            if let run {
                runs.append(run.first ..< run.last + 1)
            }
            return runs
        }

        /// Where its ink is centred, in pixels from its top left corner.
        var centroid: (x: Double, y: Double) {
            var total = 0.0, x = 0.0, y = 0.0
            for row in 0 ..< height {
                for column in 0 ..< width {
                    total += self[column, row]
                    x += self[column, row] * (Double(column) + 0.5)
                    y += self[column, row] * (Double(row) + 0.5)
                }
            }
            return (x / total, y / total)
        }

        /// The glyph moved `dx` and `dy` pixels right and down, each square of 2 by 2 pixels averaged into one.
        func halved(movedBy dx: Int, _ dy: Int) -> Glyph {
            let columns = (width + dx + 1) / 2, rows = (height + dy + 1) / 2
            var values = [Double](repeating: 0, count: columns * rows)
            for row in 0 ..< rows {
                for column in 0 ..< columns {
                    let (x, y) = (2 * column - dx, 2 * row - dy)
                    let sum = self[x, y] + self[x + 1, y] + self[x, y + 1] + self[x + 1, y + 1]
                    values[row * columns + column] = sum / 4
                }
            }
            return Glyph(width: columns, height: rows, scale: scale / 2, values: values)
        }

        /// Its coverage as a share of its most opaque pixel's, as a drawing's is measured.
        var normalized: Glyph {
            let most = max(values.max() ?? 0, 0.0001)
            return Glyph(width: width, height: height, scale: scale, values: values.map { $0 / most })
        }

        /// The mean coverage of its ink, weighted by coverage: 1 when every pixel it touches is whole.
        var sharpness: Double {
            values.reduce(0.0) { $0 + $1 * $1 } / values.reduce(0.0, +)
        }

        /// The largest difference in any pixel's coverage from `other` moved by whole pixels to line up with it,
        /// counting `other`'s ink that falls outside.
        func difference(from other: Glyph) -> Double {
            let (mine, theirs) = (centroid, other.centroid)
            let (x0, y0) = (Int((mine.x - theirs.x).rounded()), Int((mine.y - theirs.y).rounded()))
            let total = other.values.reduce(0.0, +)
            var closest = Double.infinity
            for dy in y0 - 1 ... y0 + 1 {
                for dx in x0 - 1 ... x0 + 1 {
                    var largest = 0.0, inside = 0.0
                    for row in 0 ..< height {
                        for column in 0 ..< width {
                            let value = other[column - dx, row - dy]
                            inside += value
                            largest = max(largest, abs(self[column, row] - value))
                        }
                    }
                    closest = min(closest, max(largest, total - inside))
                }
            }
            return closest
        }

        /// A + measured in pixels: its arms' lengths, and its upright's and bar's coverage across them, a third of
        /// the way along an arm.
        var plus: (arms: (across: Double, down: Double), upright: [Double], bar: [Double]) {
            let columnInk = (0 ..< width).map { column($0).reduce(0.0, +) }
            let rowInk = (0 ..< height).map { row($0).reduce(0.0, +) }
            let centerX = columnInk.indices.max { columnInk[$0] < columnInk[$1] } ?? 0
            let centerY = rowInk.indices.max { rowInk[$0] < rowInk[$1] } ?? 0
            let inked = rowInk.indices.filter { rowInk[$0] > 0.02 }
            let reach = ((inked.last ?? 0) - (inked.first ?? 0)) / 3
            let across = row(centerY - reach), down = column(centerX - reach)
            let uprightColumns = across.indices.filter { across[$0] > 0.02 }
            let barRows = down.indices.filter { down[$0] > 0.02 }
            let upright = uprightColumns.map { across[$0] }, bar = barRows.map { down[$0] }
            let uprightWidth = upright.reduce(0.0, +), barWidth = bar.reduce(0.0, +)
            var arms = (across: 0.0, down: 0.0)
            for x in 0 ..< width {
                arms.across += min(1, barRows.reduce(0.0) { $0 + self[x, $1] } / barWidth)
            }
            for y in 0 ..< height {
                arms.down += min(1, uprightColumns.reduce(0.0) { $0 + self[$1, y] } / uprightWidth)
            }
            return (arms, upright, bar)
        }
    }

    /// Displays every layer that needs it, so a layer-drawn view's drawing is in its layer before a snapshot.
    private func display(_ layer: CALayer) {
        layer.drawsAsynchronously = false
        layer.displayIfNeeded()
        layer.sublayers?.forEach(display)
    }

    /// A bitmap's alpha, as a share of its most opaque pixel's.
    private func glyph(_ rep: NSBitmapImageRep, scale: CGFloat) throws -> Glyph {
        let alphas = (0 ..< rep.pixelsHigh).flatMap { y in
            (0 ..< rep.pixelsWide).map { x in Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) }
        }
        let most = alphas.max() ?? 0
        try #require(most > 0, "the glyph is drawn")
        return Glyph(
            width: rep.pixelsWide, height: rep.pixelsHigh, scale: Double(scale), values: alphas.map { $0 / most },
        )
    }

    /// A bitmap of `size` points at `scale`, drawn into by `body` in a flipped context.
    private func drawing(size: CGSize, scale: CGFloat, _ body: () -> Void) throws -> NSBitmapImageRep {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded()),
            pixelsHigh: Int((size.height * scale).rounded()), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
        ))
        rep.size = size
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep)).cgContext
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// `view`'s drawing at its window's scale.
    private func glyph(of view: NSView) throws -> Glyph {
        let scale = try #require(view.window).backingScaleFactor
        view.superview?.layoutSubtreeIfNeeded()
        if let layer = view.layer {
            display(layer)
        }
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((view.bounds.width * scale).rounded()),
            pixelsHigh: Int((view.bounds.height * scale).rounded()), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
        ))
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return try glyph(rep, scale: scale)
    }

    /// The image `button`'s cell draws, where it draws it, at its window's scale: without the bezel.
    private func glyph(ofImageIn button: NSButton) throws -> Glyph {
        let scale = try #require(button.window).backingScaleFactor
        let cell = try #require(button.cell as? NSButtonCell)
        let image = try #require(button.image)
        let rep = try drawing(size: button.bounds.size, scale: scale) {
            cell.drawImage(image, withFrame: cell.imageRect(forBounds: button.bounds), in: button)
        }
        return try glyph(rep, scale: scale)
    }

    /// The symbol as AppKit draws it at 2x, where it keeps its shape, turned clockwise by `degrees`.
    private func symbol(
        _ name: String, pointSize: CGFloat, weight: NSFont.Weight, scale: NSImage.SymbolScale? = nil,
        turned degrees: CGFloat = 0, palette: [NSColor]? = nil,
    ) throws -> Glyph {
        var configuration = scale.map { NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight, scale: $0) }
            ?? NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        if let palette {
            configuration = configuration.applying(NSImage.SymbolConfiguration(paletteColors: palette))
        }
        let image = try #require(NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration))
        let side = ceil(hypot(image.size.width, image.size.height)) + 4
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(side * 2), pixelsHigh: Int(side * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0,
        ))
        rep.size = CGSize(width: side, height: side)
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        context.cgContext.translateBy(x: side / 2, y: side / 2)
        context.cgContext.rotate(by: -degrees * .pi / 180)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let origin = CGPoint(x: -image.size.width.rounded() / 2, y: -image.size.height.rounded() / 2)
        image.draw(in: CGRect(origin: origin, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return try glyph(rep, scale: 2)
    }

    /// Whether a stroke's coverage across it is on whole pixels: a run of pixels it covers whole, or nearly, with
    /// less than half of each pixel beside them.
    private func isWhole(_ stroke: [Double]) -> Bool {
        guard let first = stroke.firstIndex(where: { $0 >= 0.8 }), let last = stroke.lastIndex(where: { $0 >= 0.8 })
        else { return false }
        return stroke[first ... last].allSatisfy { $0 >= 0.8 } && stroke[..<first].allSatisfy { $0 < 0.5 }
            && stroke[(last + 1)...].allSatisfy { $0 < 0.5 }
    }

    private func text(_ values: [Double]) -> String {
        values.map { String(format: "%.2f", $0) }.joined(separator: " ")
    }

    /// Checks `control`'s glyph against the symbol's own, as `check(_:against:)` does, and the control itself on
    /// whole pixels in its window.
    private func check(
        _ control: NSView, _ name: String, pointSize: CGFloat, weight: NSFont.Weight,
        sourceLocation: SourceLocation = #_sourceLocation,
    ) throws {
        let scale = try #require(control.window).backingScaleFactor
        let label = "\(name) at \(Int(scale))x"
        let frame = control.convert(control.bounds, to: nil)
        let edges = [frame.minX, frame.minY, frame.maxX, frame.maxY].map { $0 * scale }
        #expect(
            edges.allSatisfy { $0.rounded() == $0 }, "\(label): the control, \(frame), is on whole pixels",
            sourceLocation: sourceLocation,
        )
        try check(
            glyph(of: control), against: symbol(name, pointSize: pointSize, weight: weight), label: label,
            plus: name == "plus", sourceLocation: sourceLocation,
        )
    }

    /// Checks a glyph against the symbol's own: the same size and shape (its spread within a tenth of a point) and
    /// the same pixels as the symbol's drawing (at 2x as AppKit draws it, at 1x that drawing averaged 2 by 2 from
    /// whichever of its half-point offsets leaves the most of it on whole pixels); and a + with arms of equal length,
    /// both strokes the same width and, at 1x, on whole pixels (at 2x they're where AppKit's drawing has them).
    private func check(
        _ drawn: Glyph, against symbol: Glyph, label: String, plus isPlus: Bool = false,
        sourceLocation: SourceLocation = #_sourceLocation,
    ) {
        let (spread, own) = (drawn.spread, symbol.spread)
        let spreads = "\(text([spread.across, spread.down])) points, the symbol's own \(text([own.across, own.down]))"
        #expect(
            abs(spread.across - own.across) <= 0.1 && abs(spread.down - own.down) <= 0.1,
            "\(label): spread \(spreads)", sourceLocation: sourceLocation,
        )
        let offsets: [(Int, Int)] = [(0, 0), (1, 0), (0, 1), (1, 1)]
        let halves = offsets.map { symbol.halved(movedBy: $0.0, $0.1) }
        let sharpest = halves.map(\.sharpness).max() ?? 0
        let references = drawn.scale == 2
            ? [symbol] : halves.filter { $0.sharpness >= sharpest - 0.005 }.map(\.normalized)
        let difference = references.map { drawn.difference(from: $0) }.min() ?? 1
        #expect(
            difference <= 0.05, "\(label): \(text([difference])) of a pixel off the symbol's own drawing",
            sourceLocation: sourceLocation,
        )
        guard isPlus else { return }
        let plus = drawn.plus
        let (upright, bar) = (plus.upright.reduce(0.0, +), plus.bar.reduce(0.0, +))
        #expect(
            abs(plus.arms.across - plus.arms.down) <= 0.3,
            "\(label): arms \(text([plus.arms.across, plus.arms.down])) pixels long", sourceLocation: sourceLocation,
        )
        #expect(
            abs(upright - bar) <= 0.15, "\(label): strokes \(text([upright, bar])) pixels wide",
            sourceLocation: sourceLocation,
        )
        #expect(
            drawn.scale > 1 || isWhole(plus.upright) && isWhole(plus.bar),
            "\(label): upright [\(text(plus.upright))], bar [\(text(plus.bar))]", sourceLocation: sourceLocation,
        )
    }

    @Test func `a source list header's + and chevron are the symbols' own shape, on whole pixels, at 1x and 2x`(
    ) throws {
        for scale in [1, 2] as [CGFloat] {
            let header = SourceListHeaderView(
                title: "Folders", add: SourceListHeaderView.Add(help: "Add Folder…", identifier: nil) { _ in },
            )
            let window = window(header, size: CGSize(width: 260, height: 19), scale: scale)
            defer { window.contentView = nil }
            let buttons = header.subviews.compactMap { $0 as? NSButton }
            let add = try #require(buttons.first { $0.toolTip == "Add Folder…" })
            let chevron = try #require(buttons.first { $0.toolTip == "Hide Folders" })
            #expect(chevron.alphaValue == 0, "the chevron waits for the pointer")
            let entered = try #require(NSEvent.enterExitEvent(
                with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil,
            ))
            header.mouseEntered(with: entered)
            #expect(chevron.alphaValue == 1 && add.alphaValue == 1, "both show while the pointer is over the header")
            #expect([add, chevron].allSatisfy { $0.frame.size == CGSize(width: 16, height: 16) })
            try check(add, "plus", pointSize: 11, weight: .semibold)
            try check(chevron, "chevron.down", pointSize: 11, weight: .semibold)
            header.isExpanded = false
            #expect(chevron.toolTip == "Show Folders")
            try check(chevron, "chevron.right", pointSize: 11, weight: .semibold)
        }
    }

    @Test func `the panel look's header buttons are the symbols' own shape, on whole pixels, at 1x and 2x`() throws {
        for scale in [1, 2] as [CGFloat] {
            let list = SidebarListView(model: EditorModel(engine: StubEngine()))
            let window = window(list, size: CGSize(width: 260, height: 900), scale: scale)
            defer { window.contentView = nil }
            @MainActor func control(_ help: String) throws -> NSView {
                try #require(views(in: list).first { $0.toolTip == help })
            }
            for help in ["Add Folder…", "Create or Import a Recipe", "Create Snapshot (⌘N)"] {
                try check(control(help), "plus", pointSize: 11, weight: .regular)
            }
            try check(control("Clear History"), "xmark", pointSize: 11, weight: .regular)
        }
    }

    @Test func `the filter field's buttons are the symbols' own shape, on whole pixels, at 1x and 2x`() throws {
        for scale in [1, 2] as [CGFloat] {
            let root = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 40))
            let field = FilterSearchField()
            root.addSubview(field)
            field.frame = CGRect(x: 12, y: 6, width: 600, height: FilterSearchField.height)
            let window = window(root, size: root.frame.size, scale: scale)
            defer { window.contentView = nil }
            try check(
                field.attributeButton, "line.3.horizontal.decrease.circle", pointSize: 13, weight: .regular,
            )
            try check(field.metadataButton, "tablecells", pointSize: 13, weight: .regular)
            try check(field.clearButton, "xmark.circle.fill", pointSize: 13, weight: .regular)
        }
    }

    /// Every symbol the app draws through `Symbol.draw`, at its size, weight and turn: the panels' and rows'
    /// chevrons, eyes and symbols, the histogram's and tone curve's triangles, the tool strip's tools, and the grid's
    /// and filmstrip's badges.
    private static let drawnSymbols: [(String, CGFloat, FontSpec.Weight, CGFloat)] = [
        ("chevron.right", 9, .bold, 0), ("chevron.right", 9, .bold, 90), ("chevron.right", 9.5, .bold, 0),
        ("chevron.down", 9.5, .bold, 0), ("eye", 12, .regular, 0), ("eye.slash", 12, .regular, 0),
        ("map", 11, .regular, 0), ("folder", 11, .regular, 0), ("camera", 11, .regular, 0),
        ("sun.max", 11, .regular, 0), ("magnifyingglass", 11, .regular, 0), ("perspective", 11, .regular, 0),
        ("swatchpalette", 11, .regular, 0), ("sparkles", 11, .regular, 0),
        ("point.bottomleft.forward.to.point.topright.scurvepath", 11, .regular, 0),
        ("arrowtriangle.up.fill", 8, .regular, 45), ("arrowtriangle.up.fill", 8, .regular, -45),
        ("arrowtriangle.up.fill", 9, .regular, 0), ("crop", 13, .regular, 0), ("bandage", 13, .regular, 0),
        ("eye", 13, .regular, 0), ("flag.fill", 8.5, .regular, 0), ("xmark", 8.5, .bold, 0),
        ("star.fill", 7.5, .regular, 0), ("star", 7.5, .regular, 0), ("circle.fill", 7.5, .regular, 0),
        ("circle", 8.5, .regular, 0), ("flag", 7, .semibold, 0), ("xmark", 7, .semibold, 0),
        ("slider.horizontal.3", 8.5, .semibold, 0), ("square.stack.3d.down.right.fill", 8, .regular, 0),
        ("ellipsis", 8, .bold, 0), ("star.fill", 6, .regular, 0), ("icloud.and.arrow.down", 14, .regular, 0),
        ("trash.fill", 8, .semibold, 0), ("hand.raised.fill", 8, .semibold, 0), ("star.fill", 9, .regular, 0),
        ("cube", 9, .regular, 0), ("questionmark.circle", 10, .regular, 0),
    ]

    @Test func `every symbol drawn through Symbol.draw is its own shape, on whole pixels, at 1x and 2x`() throws {
        for (name, size, weight, degrees) in Self.drawnSymbols {
            let own = try symbol(name, pointSize: size, weight: weight.nsWeight, turned: degrees)
            for scale in [1, 2] as [CGFloat] {
                let rep = try drawing(size: CGSize(width: 40, height: 40), scale: scale) {
                    Symbol.draw(
                        name, pointSize: size, weight: weight, color: RGBA(white: 1, alpha: 0.6),
                        centeredAt: CGPoint(x: 20.3, y: 19.6), rotation: degrees, scale: scale,
                    )
                }
                let label = "\(name) \(size) pt turned \(Int(degrees)) at \(Int(scale))x"
                try check(glyph(rep, scale: scale), against: own, label: label)
            }
        }
    }

    @Test func `the panel headers' chevrons, symbols and eyes are their own shape, on whole pixels, at 1x and 2x`(
    ) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = EditorModel(engine: StubEngine())
        model.select(folder.appending(path: "IMG_0001.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        model.expandedPanels = [.basic]
        for scale in [1, 2] as [CGFloat] {
            let column = NSView(frame: CGRect(x: 0, y: 0, width: 316, height: 1000))
            let inspector = [PanelID.basic, .detail].map { PanelSectionView(
                panel: $0,
                model: model,
                rows: [NSView()],
            ) }
            for (index, panel) in inspector.enumerated() {
                panel.frame = CGRect(x: 0, y: CGFloat(index) * 60, width: 316, height: 40)
                column.addSubview(panel)
            }
            let sidebar = SidebarListView(model: model)
            sidebar.frame = CGRect(x: 0, y: 120, width: 260, height: 700)
            column.addSubview(sidebar)
            let window = window(column, size: column.frame.size, scale: scale)
            defer { window.contentView = nil }
            column.layoutSubtreeIfNeeded()
            let headers = views(in: column).filter { String(describing: type(of: $0)) == "PanelHeaderView" }
            let expected: [(String, Bool)] = [PanelID.basic, .detail].map { (
                $0.symbol,
                model.expandedPanels.contains($0),
            ) }
                + [SidebarSection.folders, .recipes, .snapshots, .history].map {
                    ($0.symbol, model.expandedSidebarSections.contains($0))
                }
            try #require(headers.count == expected.count, "\(headers.count) panel headers")
            for (header, (name, open)) in zip(headers, expected) {
                let label = "\(name)'s header at \(Int(scale))x"
                let drawn = try glyph(of: header)
                let runs = drawn.inkedColumns
                try #require(runs.count >= 2, "\(label): a chevron and a symbol, in \(runs)")
                let chevron = try symbol("chevron.right", pointSize: 9, weight: .bold, turned: open ? 90 : 0)
                check(drawn.columns(runs[0].lowerBound - 2 ..< runs[0].upperBound + 2), against: chevron, label: label)
                let own = try symbol(name, pointSize: 11, weight: .regular)
                check(drawn.columns(runs[1].lowerBound - 2 ..< runs[1].upperBound + 2), against: own, label: label)
            }
            // Detail's eye, on and then, clicked, off.
            let eye = try #require(views(in: inspector[1])
                .first { $0.accessibilityIdentifier() == "panel.detail.switch" })
            for on in [true, false] {
                if !on {
                    try eye.mouseDown(with: #require(NSEvent.mouseEvent(
                        with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1,
                    )))
                    try await Task.sleep(for: .milliseconds(20))
                }
                try check(
                    glyph(of: eye), against: symbol(on ? "eye" : "eye.slash", pointSize: 12, weight: .regular),
                    label: "Detail's eye, \(on ? "on" : "off"), at \(Int(scale))x",
                )
            }
            model.setPanel(.detail, on: true)
        }
    }

    @Test func `a row's icon and chevron are their own shape, on whole pixels, at 1x and 2x, in both looks`() throws {
        let model = EditorModel(engine: StubEngine())
        for scale in [1, 2] as [CGFloat] {
            for look in [SidebarOutlineView.Look.panel, .sourceList] {
                let cell = SidebarCellView(
                    node: SidebarNode(.group("Favorites")),
                    model: model,
                    look: look,
                    rowSize: .medium,
                )
                let window = window(cell, size: CGSize(width: 220, height: look == .panel ? 24 : 28), scale: scale)
                defer { window.contentView = nil }
                let label = "the \(look) row at \(Int(scale))x"
                if look == .panel {
                    let icon = try #require(views(in: cell).first { $0 is SymbolImageView })
                    try check(icon, "folder", pointSize: 11, weight: .regular)
                } else {
                    let icon = try #require(views(in: cell).compactMap { $0 as? NSImageView }.first)
                    try check(
                        glyph(of: icon), against: symbol("folder", pointSize: 13, weight: .regular, scale: .large),
                        label: "\(label): its icon",
                    )
                }
                let chevron = try #require(views(in: cell).first { String(describing: type(of: $0)) == "ChevronView" })
                try check(
                    glyph(of: chevron), against: symbol("chevron.right", pointSize: 9, weight: .bold),
                    label: "\(label): its chevron",
                )
            }
        }
    }

    @Test func `the filter bar's toggles and sort arrow are their own shape, on whole pixels, at 1x and 2x`() throws {
        for scale in [1, 2] as [CGFloat] {
            let root = NSView(frame: CGRect(x: 0, y: 0, width: 160, height: 40))
            let flag = FilterToggle(symbol: "flag.fill", identifier: "test.flag", tip: "Picked")
            let red = FilterToggle(symbol: "circle.fill", color: .systemRed, identifier: "test.red", tip: "Red")
            let direction = FilterBarButton(identifier: "test.direction", symbol: "arrow.up", tip: "Ascending")
            flag.frame = CGRect(x: 10, y: 9, width: 24, height: 22)
            red.frame = CGRect(x: 40, y: 9, width: 24, height: 22)
            direction.frame = CGRect(x: 80, y: 6, width: 32, height: 28)
            [flag, red, direction].forEach(root.addSubview)
            let window = window(root, size: root.frame.size, scale: scale)
            defer { window.contentView = nil }
            let suffix = "at \(Int(scale))x"
            try check(
                glyph(ofImageIn: flag), against: symbol("flag.fill", pointSize: 11, weight: .regular),
                label: "flag.fill \(suffix)",
            )
            for on in [false, true] {
                red.isOn = on
                let tint = on ? NSColor.systemRed : NSColor.systemRed.withAlphaComponent(0.55)
                try check(
                    glyph(ofImageIn: red), against: symbol(
                        "circle.fill",
                        pointSize: 11,
                        weight: .regular,
                        palette: [tint],
                    ),
                    label: "circle.fill \(on ? "on" : "off") \(suffix)",
                )
            }
            try check(
                glyph(ofImageIn: direction), against: symbol("arrow.up", pointSize: 13, weight: .regular),
                label: "arrow.up \(suffix)",
            )
        }
    }

    @Test func `the Library's other symbol buttons and images are their own shape, on whole pixels, at 1x and 2x`(
    ) throws {
        let model = EditorModel(engine: StubEngine())
        for scale in [1, 2] as [CGFloat] {
            let root = NSView(frame: CGRect(x: 0, y: 0, width: 700, height: 200))
            let field = FilterSearchField()
            field.frame = CGRect(x: 12, y: 160, width: 600, height: FilterSearchField.height)
            let token = KeywordToken()
            token.frame = CGRect(x: 10, y: 120, width: 90, height: 20)
            let strip = CullingProblemStrip(model: model)
            strip.frame = CGRect(x: 120, y: 110, width: 560, height: 40)
            let judging = ToolbarButton(symbol: "chart.bar.xaxis", identifier: "test.judging")
            judging.frame = CGRect(x: 10, y: 80, width: 26, height: 22)
            let palette = [NSColor(white: 0.1, alpha: 0.9), NSColor(white: 0.72, alpha: 0.9)]
            let survey = ToolbarButton(symbol: "xmark.circle.fill", identifier: "test.survey", palette: palette)
            survey.frame = CGRect(x: 70, y: 80, width: 22, height: 20)
            let slider = ToolbarSlider(identifier: "test.slider")
            slider.frame = CGRect(x: 100, y: 80, width: 200, height: 22)
            let painter = KeywordPainterButton(model: nil)
            painter.frame = CGRect(x: 310, y: 80, width: 32, height: 22)
            let plus = PanelControls.symbolButton("plus", "Create", identifier: "test.plus") {}
            plus.frame = CGRect(origin: CGPoint(x: 350, y: 80), size: plus.fittingSize)
            [field, token, strip, judging, survey, slider, painter, plus].forEach(root.addSubview)
            let window = window(root, size: root.frame.size, scale: scale)
            defer { window.contentView = nil }
            root.layoutSubtreeIfNeeded()
            let suffix = "at \(Int(scale))x"
            let glass = try #require(field.subviews.compactMap { $0 as? NSImageView }.first)
            try check(glass, "magnifyingglass", pointSize: 13, weight: .regular)
            let remove = try #require(token.subviews.compactMap { $0 as? NSButton }.first)
            try check(remove, "xmark", pointSize: 8, weight: .bold)
            let icon = try #require(views(in: strip).compactMap { $0 as? NSImageView }.first)
            try check(icon, "exclamationmark.triangle.fill", pointSize: 13, weight: .regular)
            let close = try #require(views(in: strip).compactMap { $0 as? NSButton }.first { $0.title.isEmpty })
            try check(close, "xmark", pointSize: 13, weight: .regular)
            let buttons: [(ToolbarButton, String, CGFloat, [NSColor]?)] = [
                (judging, "chart.bar.xaxis", 13, nil), (survey, "xmark.circle.fill", 15, palette),
            ]
            for (button, name, size, colors) in buttons {
                let image = try #require(button.subviews.compactMap { $0 as? NSImageView }.first)
                let fitted = size * fitting(name, pointSize: size, in: image.frame.size)
                try check(
                    glyph(of: image), against: symbol(name, pointSize: fitted, weight: .regular, palette: colors),
                    label: "\(name) in a toolbar button \(suffix)",
                )
            }
            let icons = slider.subviews.compactMap { $0 as? NSImageView }.sorted { $0.frame.minX < $1.frame.minX }
            try #require(icons.count == 2)
            try check(icons[0], "photo", pointSize: 9, weight: .regular)
            try check(icons[1], "photo", pointSize: 13, weight: .regular)
            try check(
                glyph(ofImageIn: painter), against: symbol("paintbrush.pointed", pointSize: 13, weight: .regular),
                label: "the painter's button \(suffix)",
            )
            try check(plus, "plus", pointSize: 13, weight: .regular)
            let cursor = KeywordPainter.cursor.image
            let rep = try drawing(size: CGSize(width: 30, height: 30), scale: scale) {
                cursor.draw(in: CGRect(origin: CGPoint(x: 4, y: 4), size: cursor.size))
            }
            try check(
                glyph(rep, scale: scale),
                against: symbol("paintbrush.pointed.fill", pointSize: 16, weight: .regular, palette: [.white]),
                label: "the painter's pointer \(suffix)",
            )
        }
    }

    /// The share of `pointSize` an image view `size` across draws a symbol at: as it scales one down to fit.
    private func fitting(_ name: String, pointSize: CGFloat, in size: CGSize) -> CGFloat {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))
        let own = CGSize(width: ceil(image?.size.width ?? 1), height: ceil(image?.size.height ?? 1))
        return min(1, size.width / own.width, size.height / own.height)
    }

    private func views(in root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + views(in: $0) }
    }

    /// Writes the source list's header under the pointer, the panel look's sidebar, the filter field, the inspector's
    /// headers, rows in both looks, the filter bar's toggles and buttons and a strip of the symbols drawn through
    /// `Symbol.draw`, at 1x and 2x, as PNGs to the folder in `REDLAMP_POLISH_SHOTS`, each called
    /// `REDLAMP_POLISH_SHOTS_PREFIX`-name-scale.png.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_POLISH_SHOTS"] != nil))
    func `pictures of the buttons`() throws {
        let folder = try #require(ProcessInfo.processInfo.environment["REDLAMP_POLISH_SHOTS"])
        let prefix = ProcessInfo.processInfo.environment["REDLAMP_POLISH_SHOTS_PREFIX"] ?? "shot"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        func save(_ view: NSView, _ name: String) throws {
            let scale = try #require(view.window).backingScaleFactor
            view.layoutSubtreeIfNeeded()
            if let layer = view.layer {
                display(layer)
            }
            let rep = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale),
                pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
            ))
            rep.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: folder).appending(path: "\(prefix)-\(name)-\(Int(scale))x.png")
            try rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        for scale in [1, 2] as [CGFloat] {
            let header = SourceListHeaderView(
                title: "Folders", add: SourceListHeaderView.Add(help: "Add Folder…", identifier: nil) { _ in },
            )
            let headerWindow = window(header, size: CGSize(width: 260, height: 19), scale: scale)
            defer { headerWindow.contentView = nil }
            try header.mouseEntered(with: #require(NSEvent.enterExitEvent(
                with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: headerWindow.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil,
            )))
            try save(header, "source-list-header")
            header.isExpanded = false
            try save(header, "source-list-header-collapsed")

            let list = SidebarListView(model: EditorModel(engine: StubEngine()))
            let listWindow = window(list, size: CGSize(width: 260, height: 900), scale: scale)
            defer { listWindow.contentView = nil }
            try save(list, "panel-sidebar")

            let root = NSView(frame: CGRect(x: 0, y: 0, width: 624, height: 40))
            let field = FilterSearchField()
            root.addSubview(field)
            field.frame = CGRect(x: 12, y: 6, width: 600, height: FilterSearchField.height)
            let fieldWindow = window(root, size: root.frame.size, scale: scale)
            defer { fieldWindow.contentView = nil }
            try save(root, "filter-field")

            let model = EditorModel(engine: StubEngine())
            let inspector = NSView(frame: CGRect(x: 0, y: 0, width: 316, height: 80))
            for (index, panel) in [PanelID.basic, .detail].enumerated() {
                let view = PanelSectionView(panel: panel, model: model, rows: [NSView()])
                view.frame = CGRect(x: 0, y: CGFloat(index) * 40, width: 316, height: 40)
                inspector.addSubview(view)
            }
            let inspectorWindow = window(inspector, size: inspector.frame.size, scale: scale)
            defer { inspectorWindow.contentView = nil }
            try save(inspector, "inspector-headers")

            let rows = NSView(frame: CGRect(x: 0, y: 0, width: 220, height: 52))
            for (index, look) in [SidebarOutlineView.Look.panel, .sourceList].enumerated() {
                let cell = SidebarCellView(
                    node: SidebarNode(.group("Favorites")),
                    model: model,
                    look: look,
                    rowSize: .medium,
                )
                cell.frame = CGRect(x: 0, y: CGFloat(index) * 24, width: 220, height: look == .panel ? 24 : 28)
                rows.addSubview(cell)
            }
            let rowsWindow = window(rows, size: rows.frame.size, scale: scale)
            defer { rowsWindow.contentView = nil }
            try save(rows, "rows")

            let bar = NSView(frame: CGRect(x: 0, y: 0, width: 330, height: 40))
            let toggles = [
                FilterToggle(symbol: "flag.fill", identifier: "pictures.flag", tip: "Picked"),
                FilterToggle(symbol: "star", identifier: "pictures.star", tip: "Star"),
                FilterToggle(symbol: "circle.fill", color: .systemRed, identifier: "pictures.red", tip: "Red"),
                FilterToggle(symbol: "circle.slash", identifier: "pictures.none", tip: "No Label"),
            ]
            for (index, toggle) in toggles.enumerated() {
                toggle.frame = CGRect(x: 10 + CGFloat(index) * 28, y: 9, width: 24, height: 22)
                bar.addSubview(toggle)
            }
            let direction = FilterBarButton(identifier: "pictures.direction", symbol: "arrow.up", tip: "Ascending")
            direction.frame = CGRect(x: 130, y: 6, width: 32, height: 28)
            let judging = ToolbarButton(symbol: "camera.aperture", identifier: "pictures.judging")
            judging.frame = CGRect(x: 170, y: 9, width: 26, height: 22)
            let survey = ToolbarButton(
                symbol: "xmark.circle.fill", identifier: "pictures.survey",
                palette: [NSColor(white: 0.1, alpha: 0.9), NSColor(white: 0.72, alpha: 0.9)],
            )
            survey.frame = CGRect(x: 200, y: 10, width: 22, height: 20)
            let slider = ToolbarSlider(identifier: "pictures.slider")
            slider.frame = CGRect(x: 226, y: 9, width: 100, height: 22)
            [direction, judging, survey, slider].forEach(bar.addSubview)
            let barWindow = window(bar, size: bar.frame.size, scale: scale)
            defer { barWindow.contentView = nil }
            try save(bar, "filter-bar")

            let symbols = try drawing(size: CGSize(width: 330, height: 24), scale: scale) {
                for (index, (name, size, weight, degrees)) in Self.drawnSymbols.prefix(24).enumerated() {
                    Symbol.draw(
                        name, pointSize: size, weight: weight, color: RGBA(white: 1, alpha: 0.85),
                        centeredAt: CGPoint(x: 10 + CGFloat(index) * 13.5, y: 12), rotation: degrees, scale: scale,
                    )
                }
            }
            let url = URL(fileURLWithPath: folder).appending(path: "\(prefix)-symbols-\(Int(scale))x.png")
            try symbols.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
