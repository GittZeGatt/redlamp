import AppKit

/// The grid's layout: cells of one size in rows as wide as the grid, centred, each cell's place worked out
/// from its index, so a grid of a million photos lays out what's on screen and nothing more. A cell is as
/// wide as the thumbnail size; an expanded cell is taller, for the photo's name, date and settings above
/// its thumbnail and its badges below. Grouped (LIB-41), each group's header has a row of its own and its
/// cells rows of their own, placed from each group's rows before it (`GridSections`).
struct LibraryGridLayout: Equatable {
    var width: CGFloat = 0
    var count = 0
    var size = CGFloat(GridSize.standard)
    var style = GridCellStyle.compact
    /// The groups' headers and cells; nil for one run of cells.
    var sections: GridSections?
    /// Each group's cell rows before it, then all of them, as `prepare` counts them.
    private(set) var rowsBefore: [Int] = []

    static let insets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

    /// Counts the sections' rows for the width, size and style set.
    mutating func prepare() {
        rowsBefore = sections.map { Self.rowsBefore($0, columns: columns) } ?? []
    }

    var spacing: CGFloat {
        max(6, (size * 0.05).rounded())
    }

    var cellSize: CGSize {
        GridCellGeometry(size: size, style: style).cellSize
    }

    /// Cells in a row.
    var columns: Int {
        let usable = width - Self.insets.left - Self.insets.right
        return max(Int((usable + spacing) / (cellSize.width + spacing)), 1)
    }

    var rows: Int {
        (count + columns - 1) / columns
    }

    var contentHeight: CGFloat {
        if let sections, rowsBefore.count == sections.groups + 1 {
            guard sections.groups > 0 else { return Self.insets.top + Self.insets.bottom }
            return top(ofGroup: sections.groups) - spacing + Self.insets.bottom
        }
        return Self.insets.top + Self.insets.bottom + CGFloat(rows) * cellSize.height
            + CGFloat(max(rows - 1, 0)) * spacing
    }

    /// Whole rows in `height` points.
    func rows(in height: CGFloat) -> Int {
        max(Int((height + spacing) / (cellSize.height + spacing)), 1)
    }

    var left: CGFloat {
        let used = CGFloat(columns) * cellSize.width + CGFloat(columns - 1) * spacing
        return max((width - used) / 2, Self.insets.left)
    }

    /// Where cell `index` is, or grouped, the header or cell.
    func frame(forItem index: Int) -> CGRect {
        if let sections, rowsBefore.count == sections.groups + 1 {
            return groupedFrame(forItem: index, in: sections)
        }
        let (columns, cell, spacing) = (columns, cellSize, spacing)
        return CGRect(
            x: left + CGFloat(index % columns) * (cell.width + spacing),
            y: Self.insets.top + CGFloat(index / columns) * (cell.height + spacing),
            width: cell.width, height: cell.height,
        )
    }

    /// The cells in the rows that meet `rect`, or grouped, the headers and cells.
    func items(in rect: CGRect) -> Range<Int> {
        guard count > 0 else { return 0 ..< 0 }
        if let sections, rowsBefore.count == sections.groups + 1 {
            return groupedItems(in: rect, of: sections).clamped(to: 0 ..< count)
        }
        let pitch = cellSize.height + spacing
        let first = max(Int(((rect.minY - Self.insets.top) / pitch).rounded(.down)), 0)
        let last = min(Int(((rect.maxY - Self.insets.top) / pitch).rounded(.down)), rows - 1)
        guard first <= last else { return 0 ..< 0 }
        return first * columns ..< min((last + 1) * columns, count)
    }

    /// The cell under `point`; nil between cells and around them.
    func item(at point: CGPoint) -> Int? {
        let range = items(in: CGRect(x: point.x, y: point.y, width: 0, height: 0))
        return range.first { frame(forItem: $0).contains(point) }
    }

    /// Every cell `rect` meets, in order: a rubber band's.
    func items(meeting rect: CGRect) -> [Int] {
        items(in: rect).filter { frame(forItem: $0).intersects(rect) }
    }
}

/// Where a cell's parts are, for a cell `size` wide in `style`: its thumbnail, the text of an expanded
/// cell, and each badge's place, kept even where a photo has no such badge, for clicking them.
struct GridCellGeometry: Equatable {
    var size: CGFloat
    var style: GridCellStyle

    static let headerHeight: CGFloat = 46
    static let footerHeight: CGFloat = 22
    /// An expanded cell's three lines of text.
    static let textHeight: CGFloat = 38
    /// How far a compact cell's corner badges' middles are from its edges, clear of the selection's ring.
    static let corner: CGFloat = 11

    var inset: CGFloat {
        max(6, (size * 0.07).rounded())
    }

    var cellSize: CGSize {
        let width = size
        guard style == .expanded else { return CGSize(width: width, height: width) }
        return CGSize(width: width, height: Self.headerHeight + width - 2 * inset + Self.footerHeight)
    }

    /// The thumbnail's area: the photo is fitted inside it.
    var image: CGRect {
        let side = size - 2 * inset
        let top = style == .expanded ? Self.headerHeight : inset
        return CGRect(x: inset, y: top, width: side, height: side)
    }

    /// An expanded cell's name, date and settings, below the colour label's bar.
    var text: CGRect {
        CGRect(x: inset, y: label.maxY, width: size - 2 * inset, height: Self.textHeight)
    }

    /// The colour label's bar, along the cell's top inside the selection's ring, as wide as the thumbnail's area.
    var label: CGRect {
        CGRect(x: inset, y: 4, width: size - 2 * inset, height: 2.5)
    }

    /// Each badge's centre or corner: the flag top left, the mark top right with a stack beside it, the
    /// rating bottom left and edits bottom right, over the thumbnail's corners in a compact cell; in an
    /// expanded one, the mark over the thumbnail's top right corner and the rest in the footer.
    var flag: CGPoint {
        style == .expanded ? CGPoint(x: size - inset - 7, y: footerMidY) : CGPoint(x: Self.corner, y: Self.corner)
    }

    var stack: CGPoint {
        style == .expanded ? CGPoint(x: size - inset - 23, y: footerMidY)
            : CGPoint(x: size - Self.corner - 18, y: Self.corner)
    }

    var mark: CGPoint {
        style == .expanded ? CGPoint(x: image.maxX - 10, y: image.minY + 10)
            : CGPoint(x: size - Self.corner, y: Self.corner)
    }

    /// The rating's left edge and middle.
    var rating: CGPoint {
        style == .expanded ? CGPoint(x: inset - 5, y: footerMidY) : CGPoint(x: 5, y: size - 12)
    }

    var edited: CGPoint {
        style == .expanded ? CGPoint(x: size - inset - 41, y: footerMidY) : CGPoint(x: size - 12, y: size - 12)
    }

    /// Where a compact cell shows a stack's count `width` points wide: along its top, left of the mark, and of a
    /// focus stack's badge `besideDocument`.
    func stackCount(width: CGFloat, besideDocument: Bool) -> CGRect {
        let right = size - Self.corner - (besideDocument ? 28 : 10)
        return CGRect(x: right - width, y: Self.corner - 8, width: width, height: 16)
    }

    /// Where a compact cell shows a raw and its JPEG's other extensions: right of the flag.
    var pairText: CGPoint {
        CGPoint(x: Self.corner + 10, y: Self.corner)
    }

    /// An expanded cell's colour label chip, after the stars, where the cell is wide enough to keep it clear
    /// of the edited badge.
    var labelChip: CGRect? {
        guard style == .expanded else { return nil }
        let chip = CGRect(
            x: rating.x + GridBadges.Kind.ratingSlots(0).size.width + 4,
            y: footerMidY - 5,
            width: 10,
            height: 10,
        )
        return chip.maxX + 2 <= edited.x - 8 ? chip : nil
    }

    private var footerMidY: CGFloat {
        cellSize.height - Self.footerHeight / 2
    }

    /// What a click at `point` (in the cell) sets in an expanded cell: a star, the flag, the label or the mark.
    enum Target: Equatable {
        case star(Int), flag, label, mark
    }

    func target(at point: CGPoint) -> Target? {
        guard style == .expanded else { return nil }
        func near(_ centre: CGPoint, _ reach: CGFloat) -> Bool {
            abs(point.x - centre.x) <= reach && abs(point.y - centre.y) <= reach
        }
        if near(mark, 9) {
            return .mark
        }
        guard point.y >= cellSize.height - Self.footerHeight else { return nil }
        let stars = GridBadges.Kind.ratingSlots(0).size.width
        if point.x >= rating.x, point.x < rating.x + stars {
            let first = rating.x + GridBadges.starInset - GridBadges.starPitch / 2
            return .star(min(max(Int((point.x - first) / GridBadges.starPitch) + 1, 1), 5))
        }
        if let chip = labelChip, chip.insetBy(dx: -3, dy: -5).contains(point) {
            return .label
        }
        return near(flag, 9) ? .flag : nil
    }
}
