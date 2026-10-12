import AppKit
import Foundation
import Testing
@testable import RedlampUI

/// The small symbol buttons of the sidebars' headers (LIB-45): each glyph drawn at the symbol's own size and shape,
/// its strokes on whole pixels, at 1x as well as 2x. For a 1x screen AppKit draws a symbol stretched, and a button
/// cell centres one by its alignment rect, which can leave it on half a pixel: the source list header's + came out
/// 11.5 pixels wide and 8.7 tall, its upright blurred across four columns.
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

    /// `view`'s drawing at its window's scale, each pixel's alpha as a share of its most opaque one's.
    private func glyph(of view: NSView) throws -> Glyph {
        let scale = try #require(view.window).backingScaleFactor
        view.superview?.layoutSubtreeIfNeeded()
        if let layer = view.layer {
            display(layer)
        }
        let size = view.bounds.size
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded()),
            pixelsHigh: Int((size.height * scale).rounded()), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
        ))
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        let alphas = (0 ..< rep.pixelsHigh).flatMap { y in
            (0 ..< rep.pixelsWide).map { x in Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) }
        }
        let most = alphas.max() ?? 0
        try #require(most > 0, "\(view) draws its glyph")
        return Glyph(
            width: rep.pixelsWide, height: rep.pixelsHigh, scale: Double(scale), values: alphas.map { $0 / most },
        )
    }

    /// The symbol as AppKit draws it at 2x, where it keeps its shape.
    private func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight) throws -> Glyph {
        let image = try #require(NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)))
        let size = CGSize(width: ceil(image.size.width) + 4, height: ceil(image.size.height) + 4)
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0,
        ))
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: CGPoint(x: 2, y: 2), size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        let alphas = (0 ..< rep.pixelsHigh).flatMap { y in
            (0 ..< rep.pixelsWide).map { x in Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) }
        }
        let most = try #require(alphas.max())
        return Glyph(width: rep.pixelsWide, height: rep.pixelsHigh, scale: 2, values: alphas.map { $0 / most })
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

    /// Checks `control`'s glyph against the symbol's own: the same size and shape (its spread within a tenth of a
    /// point) and the same pixels as the symbol's drawing (at 2x as AppKit draws it, at 1x that drawing averaged 2 by
    /// 2 from whichever of its half-point offsets leaves the most of it on whole pixels); a + with arms of equal
    /// length and both strokes on whole pixels and the same width; and the control itself on whole pixels in its
    /// window.
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
        let drawn = try glyph(of: control)
        let symbol = try symbol(name, pointSize: pointSize, weight: weight)
        let (spread, own) = (drawn.spread, symbol.spread)
        let spreads = "\(text([spread.across, spread.down])) points, the symbol's own \(text([own.across, own.down]))"
        #expect(
            abs(spread.across - own.across) <= 0.1 && abs(spread.down - own.down) <= 0.1,
            "\(label): spread \(spreads)", sourceLocation: sourceLocation,
        )
        let offsets: [(Int, Int)] = [(0, 0), (1, 0), (0, 1), (1, 1)]
        let halves = offsets.map { symbol.halved(movedBy: $0.0, $0.1) }
        let sharpest = halves.map(\.sharpness).max() ?? 0
        let references = scale == 2 ? [symbol] : halves.filter { $0.sharpness >= sharpest - 0.005 }
        let difference = references.map { drawn.difference(from: $0) }.min() ?? 1
        #expect(
            difference <= 0.05, "\(label): \(text([difference])) of a pixel off the symbol's own drawing",
            sourceLocation: sourceLocation,
        )
        guard name == "plus" else { return }
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
            isWhole(plus.upright) && isWhole(plus.bar),
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

    private func views(in root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + views(in: $0) }
    }

    /// Writes the source list's header under the pointer and the panel look's sidebar at 1x and 2x as PNGs to the
    /// folder in `REDLAMP_POLISH_SHOTS`, each called `REDLAMP_POLISH_SHOTS_PREFIX`-name-scale.png.
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
        }
    }
}
