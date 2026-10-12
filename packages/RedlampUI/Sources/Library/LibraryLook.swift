import AppKit
import RedlampDesign

/// The Library's colours, each from the token Develop's panels draw the same role in (`Palette`): behind the grid the
/// panels' own background; a photo's cell a card on it, a step toward the theme's selection colour in the selection and
/// a full step for the active photo, ringed in the accent. Text takes `tokens` by role, as the panels do: names and
/// values `value`, what's said about them `secondaryLabel`. The loupe, Compare and Survey are drawn on Develop's canvas
/// grey instead (`PhotoSurround`), dark in every theme, so what's drawn on them takes `surroundTokens`.
///
/// They're made once for each theme (`follow`), so a cell scrolling in sets colours already made and reads no lock.
@MainActor
enum LibraryLook {
    struct Colors {
        let tokens: PaletteTokens
        let surroundTokens: PaletteTokens
        let background: CGColor
        let tile: CGColor
        let raised: CGColor
        let selectedTile: CGColor
        let activeTile: CGColor
        /// The theme's accent, or the system's.
        let ring: CGColor
        /// A filmstrip cell's edge: the active photo's, and another selected one's.
        let activeEdge: CGColor
        let selectedEdge: CGColor
        let chipEdge: CGColor
        let cellText: GridText.Colors
        let headerText: GroupHeaderText.Colors

        init(_ tokens: PaletteTokens, surround surroundTokens: PaletteTokens, ring: CGColor) {
            self.tokens = tokens
            self.surroundTokens = surroundTokens
            self.ring = ring
            activeEdge = tokens.value.cgColor
            selectedEdge = tokens.secondaryLabel.cgColor
            chipEdge = tokens.tertiaryLabel.cgColor
            cellText = GridText.Colors(tokens)
            headerText = GroupHeaderText.Colors(tokens)
            let base = tokens.panelBackground.over(RGBA(white: 0))
            let tile = tokens.card.over(base)
            background = base.cgColor
            self.tile = tile.cgColor
            raised = tokens.card.over(tile).cgColor
            selectedTile = tokens.selection.opacity(0.5).over(tile).cgColor
            activeTile = tokens.selection.over(tile).cgColor
        }
    }

    private(set) static var colors = Colors(
        Palette.current, surround: Palette.current.isDark ? Palette.current : .standard, ring: Palette.accent.cgColor,
    )

    /// The tokens the colours were made from, for text and glyphs drawn by role.
    static var tokens: PaletteTokens {
        colors.tokens
    }

    /// For text and glyphs drawn on a photo's surround: the theme's own tokens when it's dark, else its family's dark
    /// ones, so its hue stays and they read on the dark grey as Develop's info overlay does on its canvas.
    static var surroundTokens: PaletteTokens {
        colors.surroundTokens
    }

    /// Behind the grid.
    static var background: CGColor {
        colors.background
    }

    /// A photo's cell at rest.
    static var tile: CGColor {
        colors.tile
    }

    /// The filter bar's strip, a card on the background as a cell is.
    static var bar: CGColor {
        colors.tile
    }

    /// A card on the bar: the filter bar's Metadata columns.
    static var raised: CGColor {
        colors.raised
    }

    /// A cell in the selection with the active photo.
    static var selectedTile: CGColor {
        colors.selectedTile
    }

    /// The active photo's cell.
    static var activeTile: CGColor {
        colors.activeTile
    }

    /// The selection's ring, and what else the accent marks.
    static var ring: CGColor {
        colors.ring
    }

    /// The edge of the filmstrip's active photo, and of another selected one.
    static var activeEdge: CGColor {
        colors.activeEdge
    }

    static var selectedEdge: CGColor {
        colors.selectedEdge
    }

    /// The edge of an expanded cell's colour label chip without a label.
    static var chipEdge: CGColor {
        colors.chipEdge
    }

    /// An expanded cell's text.
    static var cellText: GridText.Colors {
        colors.cellText
    }

    /// A group's header's text and chevron.
    static var headerText: GroupHeaderText.Colors {
        colors.headerText
    }

    /// The tint of the system's own controls: the theme's when it tints them (`PaletteTokens.nativeTint`), else the
    /// system accent.
    static var nativeTint: NSColor {
        colors.tokens.nativeTint?.nsColor ?? .controlAccentColor
    }

    /// Makes the colours again from the theme and the system's accent as they are now, and the surround's from the
    /// family of `selection` when it's given; false when they're the ones already made.
    @discardableResult
    static func follow(_ selection: ThemeSelection? = nil) -> Bool {
        let tokens = Palette.current
        let ring = Palette.accent.cgColor
        let surround = selection.map(surroundTokens(for:)) ?? colors.surroundTokens
        guard tokens != colors.tokens || surround != colors.surroundTokens || ring != colors.ring else { return false }
        colors = Colors(tokens, surround: surround, ring: ring)
        return true
    }

    /// `selection`'s family in its dark appearance, at its tint.
    static func surroundTokens(for selection: ThemeSelection) -> PaletteTokens {
        var dark = selection
        dark.appearance = .dark
        return dark.tokens
    }
}

/// A view of the Library module built once with the window, which draws in the theme's colours: it takes them again
/// when the theme changes (`LibraryModuleView`), where Develop's panels are made again.
@MainActor
protocol ThemeFollowing: AnyObject {
    func followTheme()
}

extension NSView {
    /// Has every view under this one that follows the theme take its colours again, each after the views inside it,
    /// so a view that sets its subviews' colours itself has the last word.
    @MainActor func followThemeBelow() {
        for view in subviews {
            view.followThemeBelow()
            (view as? ThemeFollowing)?.followTheme()
        }
    }
}

/// A list's row with its selection in the theme's selection colour, as Develop's lists draw theirs, rather than the
/// system's accent; its cells keep their colours, as on a row that isn't emphasized.
final class ThemedRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawSelection(in _: NSRect) {
        Palette.selection.nsColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 0), xRadius: 5, yRadius: 5).fill()
    }
}

extension RGBA {
    /// This colour laid over `base`, as a layer over another composites.
    func over(_ base: RGBA) -> RGBA {
        let combined = alpha + base.alpha * (1 - alpha)
        guard combined > 0 else { return RGBA(white: 0, alpha: 0) }
        func channel(_ top: Double, _ bottom: Double) -> Double {
            (top * alpha + bottom * base.alpha * (1 - alpha)) / combined
        }
        return RGBA(
            red: channel(red, base.red), green: channel(green, base.green), blue: channel(blue, base.blue),
            alpha: combined,
        )
    }
}
