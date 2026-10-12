import AppKit
import CoreText
import QuartzCore
import RedlampDesign

/// A group's header in the grid (LIB-41), across it as Finder's groups have them: a disclosure chevron, the group's
/// name, how many photos and picks it has, and a rule under it. Layers only, recycled as the grid scrolls, as its
/// cells are; a click on it opens or closes the group. Its text is an image drawn off the main thread
/// (`GroupHeaderText`), and its chevron one of two images every header shares, so opening or closing a group draws no
/// text. While the active photo is in its closed group, it's ringed as a selected cell is.
@MainActor
final class GroupHeaderCell {
    let root = CALayer()
    private let background = CALayer()
    private let rule = CALayer()
    private let triangle = CALayer()
    private let text = CALayer()

    /// The group it shows.
    private(set) var group = -1
    /// What it shows, for VoiceOver and the tests.
    private(set) var title = ""
    private(set) var detail = ""
    private(set) var isOpen = true
    /// The active photo is in this closed group.
    private(set) var isFocused = false
    /// What its text image shows, or is to show once drawn.
    private(set) var textKey: GroupHeaderText.Key?

    init() {
        background.cornerRadius = 6
        rule.backgroundColor = LibraryLook.tokens.divider.cgColor
        for layer in [root, background, rule, triangle, text] {
            layer.actions = LibraryGridCell.noActions
        }
        root.addSublayer(background)
        root.addSublayer(rule)
        root.addSublayer(triangle)
        root.addSublayer(text)
    }

    /// Shows group `group`, named `title`, with `detail` (its photos and picks), at `frame`; its text follows
    /// as `setText` gives it.
    func show(
        group: Int, title: String, detail: String, open: Bool, focused: Bool, frame: CGRect, scale: CGFloat,
    ) {
        root.frame = frame
        root.isHidden = false
        (self.group, self.title, self.detail) = (group, title, detail)
        if background.frame.size != frame.size || rule.contentsScale != scale {
            background.frame = CGRect(origin: .zero, size: frame.size)
            rule.contentsScale = scale
            rule.frame = CGRect(x: 0, y: frame.height - 1 / scale, width: frame.width, height: 1 / scale)
        }
        if open != isOpen || triangle.contents == nil || triangle.contentsScale != scale {
            triangle.contentsScale = scale
            triangle.contents = GroupHeaderText.triangle(
                open: open,
                scale: scale,
                color: LibraryLook.headerText.chevron,
            )
            triangle.frame = CGRect(x: 8, y: (frame.height - 12) / 2, width: 12, height: 12)
        }
        isOpen = open
        if focused != isFocused {
            isFocused = focused
            refreshLook()
        }
        text.frame = CGRect(
            x: 26, y: (frame.height - GroupHeaderText.height) / 2, width: max(frame.width - 34, 1),
            height: GroupHeaderText.height,
        )
        text.contentsScale = scale
    }

    func setText(_ image: CGImage?, for key: GroupHeaderText.Key) {
        textKey = key
        text.contents = image
    }

    /// Ringed in the accent as it is now while it stands for the active photo, its rule hidden meanwhile.
    func refreshLook() {
        background.backgroundColor = isFocused ? LibraryLook.selectedTile : nil
        background.borderWidth = isFocused ? 2 : 0
        background.borderColor = isFocused ? LibraryLook.ring : nil
        rule.isHidden = isFocused
    }

    /// Takes the theme's colours as they are now: its rule's, its chevron's and the focus's.
    func followTheme() {
        rule.backgroundColor = LibraryLook.tokens.divider.cgColor
        if triangle.contents != nil {
            triangle.contents = GroupHeaderText.triangle(
                open: isOpen, scale: triangle.contentsScale, color: LibraryLook.headerText.chevron,
            )
        }
        refreshLook()
    }

    /// Out of sight, waiting to show another group.
    func recycle() {
        root.isHidden = true
        group = -1
    }

    /// What VoiceOver reads.
    var accessibilityText: String {
        "\(title), \(detail)"
    }
}

/// A header's text, drawn off the main thread into an image its layer shows: the group's name, then how many
/// photos and picks it has.
enum GroupHeaderText {
    static let height: CGFloat = 18

    /// The theme's colours for a header: its name the value colour, its detail the secondary label colour or, for a
    /// moment still to cull, the label colour, and its chevron the panels' chevrons' colour.
    struct Colors: Hashable, Sendable {
        var title: RGBA
        var detail: RGBA
        var unpicked: RGBA
        var chevron: RGBA

        init(_ tokens: PaletteTokens) {
            title = tokens.value
            detail = tokens.secondaryLabel
            unpicked = tokens.label
            chevron = tokens.secondaryLabel
        }
    }

    struct Key: Hashable, Sendable {
        var title: String
        var detail: String
        var width: CGFloat
        var scale: CGFloat
        /// A moment without a pick: its detail is drawn brighter, as one still to cull.
        var unpicked = false
        var colors: Colors
    }

    /// "42 photos · 3 picks", or "42 photos · no pick yet".
    static func detail(count: Int, picks: Int) -> String {
        let photos = "\(count.formatted()) \(count == 1 ? "photo" : "photos")"
        guard picks > 0 else { return photos + " · no pick yet" }
        return photos + " · \(picks.formatted()) \(picks == 1 ? "pick" : "picks")"
    }

    /// Drawn in `space`, the window's, so Core Animation shows it as it is.
    nonisolated static func render(_ key: Key, in space: CGColorSpace?) -> CGImage? {
        let pixels = (width: Int((key.width * key.scale).rounded(.up)), height: Int((height * key.scale).rounded(.up)))
        guard pixels.width > 0, let space = space ?? CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: nil, width: pixels.width, height: pixels.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
        ) else { return nil }
        context.scaleBy(x: key.scale, y: key.scale)
        let string = NSMutableAttributedString()
        string.append(NSAttributedString(string: key.title, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: CTFontCreateUIFontForLanguage(.emphasizedSystem, 13, nil)
                as Any,
            kCTForegroundColorAttributeName as NSAttributedString.Key: key.colors.title.cgColor,
        ]))
        let detail: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: CTFontCreateUIFontForLanguage(.system, 11.5, nil) as Any,
            kCTForegroundColorAttributeName as NSAttributedString.Key:
                (key.unpicked ? key.colors.unpicked : key.colors.detail).cgColor,
        ]
        string.append(NSAttributedString(string: "   " + key.detail, attributes: detail))
        let line = CTLineCreateWithAttributedString(string)
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: detail))
        let fitted = CTLineCreateTruncatedLine(line, Double(key.width), .end, ellipsis) ?? line
        context.textPosition = CGPoint(x: 0, y: 5)
        CTLineDraw(fitted, context)
        return context.makeImage()
    }

    /// The disclosure chevron, pointing down while the group is open, made once for each screen's scale and colour.
    @MainActor static func triangle(open: Bool, scale: CGFloat, color: RGBA) -> CGImage? {
        let key = TriangleKey(open: open, scale: scale, color: color)
        if let image = triangles[key] {
            return image
        }
        let side = Int((12 * scale).rounded(.up))
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
        ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: scale, y: -scale)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        Symbol.draw(
            open ? "chevron.down" : "chevron.right", pointSize: 9.5, weight: .bold, color: color,
            centeredAt: CGPoint(x: 6, y: 6), scale: scale,
        )
        NSGraphicsContext.current = previous
        let image = context.makeImage()
        triangles[key] = image
        return image
    }

    private struct TriangleKey: Hashable {
        var open: Bool
        var scale: CGFloat
        var color: RGBA
    }

    @MainActor private static var triangles: [TriangleKey: CGImage] = [:]
}
