import AppKit
import RedlampLibrary

/// The keywords of the photos selected in the Keywording panel (LIB-21), as the system draws a token field's tokens
/// (LIB-45): side by side and wrapped onto as many lines as they need. The tokens are kept from one selection to the
/// next, laid out by hand from their names' widths: a held arrow key shows another photo's keywords every few frames.
final class KeywordTokensView: NSView {
    static let spacing: CGFloat = 5
    private var tokens: [KeywordToken] = []
    private var shown = 0
    private var laidOutWidth: CGFloat = 0
    private lazy var height = heightAnchor.constraint(equalToConstant: 0)
    /// Takes the keyword off every photo selected.
    var onRemove: (KeywordPath) -> Void = { _ in }
    /// The tokens' height changed by this much.
    var onHeightChange: (CGFloat) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        height.isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Keywords")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    /// Shows `keywords`, each on `count` of the `selected` photos.
    func show(_ keywords: ArraySlice<(path: KeywordPath, count: Int)>, of selected: Int) {
        while tokens.count < keywords.count {
            let token = KeywordToken()
            token.onRemove = { [weak self] path in self?.onRemove(path) }
            addSubview(token)
            tokens.append(token)
        }
        for (place, token) in tokens.enumerated() {
            let index = keywords.startIndex + place
            if keywords.indices.contains(index) {
                token.show(keywords[index].path, on: keywords[index].count, of: selected)
            } else {
                token.hide()
            }
        }
        shown = keywords.count
        place(in: bounds.width > 0 ? bounds.width : laidOutWidth)
    }

    override func layout() {
        super.layout()
        if bounds.width != laidOutWidth {
            place(in: bounds.width)
        }
    }

    /// Lays the tokens out across `width`, a line after another, and says when their height changes.
    private func place(in width: CGFloat) {
        guard width > 0 else { return }
        laidOutWidth = width
        var (x, y): (CGFloat, CGFloat) = (0, 0)
        for token in tokens.prefix(shown) {
            let tokenWidth = min(token.width, width)
            if x > 0, x + tokenWidth > width {
                (x, y) = (0, y + KeywordToken.height + Self.spacing)
            }
            let frame = CGRect(x: x, y: y, width: tokenWidth, height: KeywordToken.height)
            if token.frame != frame {
                token.frame = frame
            }
            x += tokenWidth + Self.spacing
        }
        let total = shown == 0 ? 0 : y + KeywordToken.height
        guard total != height.constant else { return }
        let delta = total - height.constant
        height.constant = total
        onHeightChange(delta)
    }
}

/// A keyword as a token: its name on the accent colour's tint when every photo selected has it, or on grey with how
/// many do when only some do, and a button that takes it off them all.
final class KeywordToken: NSView {
    static let height: CGFloat = 22
    private static let inset: CGFloat = 8
    private static let removeSide: CGFloat = 16
    /// What a label adds to its text's width.
    private static let labelPadding: CGFloat = 4
    private let name = NSTextField(labelWithString: "")
    private let partial = NSTextField(labelWithString: "")
    private let remove = NSButton()
    private(set) var path: KeywordPath?
    private var isPartial = false
    /// Its width, from its texts' widths.
    private(set) var width: CGFloat = 0
    var onRemove: (KeywordPath) -> Void = { _ in }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 60, height: Self.height))
        name.font = PanelControls.font
        name.lineBreakMode = .byTruncatingMiddle
        partial.font = PanelControls.noteFont
        partial.textColor = .secondaryLabelColor
        let configuration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        remove.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove")?
            .withSymbolConfiguration(configuration)
        remove.isBordered = false
        remove.imagePosition = .imageOnly
        remove.contentTintColor = .secondaryLabelColor
        remove.target = self
        remove.action = #selector(removeClicked)
        for view in [name, partial, remove] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    /// Shows `path`, on `count` of the `selected` photos.
    func show(_ path: KeywordPath, on count: Int, of selected: Int) {
        isHidden = false
        let isPartial = count < selected
        let counted = "\(count) of \(selected)"
        guard path != self.path || isPartial != self.isPartial || isPartial && counted != partial.stringValue
        else { return }
        self.path = path
        self.isPartial = isPartial
        name.stringValue = path.displayName
        partial.stringValue = counted
        partial.isHidden = !isPartial
        toolTip = isPartial ? "On \(count) of \(selected) photos" : "On every photo selected"
        name.setAccessibilityIdentifier("keywording.keyword.\(path.text)")
        let description = "Remove “\(path.displayName)”"
        remove.toolTip = description
        remove.setAccessibilityLabel(description)
        remove.setAccessibilityIdentifier("keywording.remove.\(path.text)")
        width = Self.inset + Self.width(of: name.stringValue, PanelControls.font) + Self.labelPadding
            + (isPartial ? 3 + Self.width(of: counted, PanelControls.noteFont) + Self.labelPadding : 0) + Self
            .removeSide
            + 3
        needsLayout = true
        needsDisplay = true
    }

    /// Out of the panel until another keyword needs a token, its controls named for none.
    func hide() {
        guard !isHidden else { return }
        isHidden = true
        path = nil
        name.setAccessibilityIdentifier("")
        remove.setAccessibilityIdentifier("")
    }

    override func layout() {
        super.layout()
        let removeX = bounds.width - 3 - Self.removeSide
        remove.frame = CGRect(
            x: removeX, y: (bounds.height - Self.removeSide) / 2, width: Self.removeSide, height: Self.removeSide,
        )
        let nameHeight = name.intrinsicContentSize.height
        var end = removeX
        if isPartial {
            let partialWidth = Self.width(of: partial.stringValue, PanelControls.noteFont) + Self.labelPadding
            let partialHeight = partial.intrinsicContentSize.height
            partial.frame = CGRect(
                x: end - partialWidth, y: (bounds.height - partialHeight) / 2 + 0.5, width: partialWidth,
                height: partialHeight,
            )
            end -= partialWidth + 3
        }
        name.frame = CGRect(
            x: Self.inset - Self.labelPadding / 2, y: (bounds.height - nameHeight) / 2,
            width: max(end - Self.inset + Self.labelPadding / 2, 0), height: nameHeight,
        )
    }

    override func draw(_: NSRect) {
        let fill: NSColor = isPartial ? .quaternaryLabelColor : Self.tint
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }

    /// A token field's tokens' colour: the accent colour, lightened in light mode and greyed in dark mode.
    private static let tint = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? NSColor.controlAccentColor.blended(withFraction: 0.55, of: NSColor(white: 0.45, alpha: 1))
            ?? .controlAccentColor
            : NSColor.controlAccentColor.blended(withFraction: 0.7, of: .white) ?? .controlAccentColor
    }

    @objc private func removeClicked() {
        if let path {
            onRemove(path)
        }
    }

    private static var widths: [String: CGFloat] = [:]

    /// `text`'s width in `font`, measured once.
    private static func width(of text: String, _ font: NSFont) -> CGFloat {
        let key = "\(font.pointSize) \(text)"
        if let known = widths[key] {
            return known
        }
        if widths.count > 4000 {
            widths = [:]
        }
        let measured = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        widths[key] = measured
        return measured
    }
}

/// The keywords the Keywording panel's field completes to, best first, in a list under it as the system draws a
/// completion list: each keyword's name, the synonym typed or the keyword it's inside, and its count; the one ↓
/// and ↑ reach in the selection's colour. A click puts the keyword in the field and adds it.
final class KeywordCompletionList: NSView {
    private static let inset: CGFloat = 4
    private var rows: [KeywordCompletionRow] = []
    private var shown = 0
    /// The place of the keyword chosen, among those shown.
    var onChoose: (Int) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: shown == 0 ? 0 : CGFloat(shown) * KeywordCompletionRow.height + 2 * Self.inset,
        )
    }

    func show(_ matches: [KeywordCompletion.Match], highlighted: Int?) {
        while rows.count < matches.count {
            let place = rows.count
            let row = KeywordCompletionRow { [weak self] in self?.onChoose(place) }
            row.setAccessibilityIdentifier("keywording.completion.\(place)")
            addSubview(row)
            rows.append(row)
        }
        for (place, row) in rows.enumerated() {
            row.isHidden = place >= matches.count
            if place < matches.count {
                row.show(matches[place], highlighted: place == highlighted)
            }
        }
        if shown != matches.count {
            shown = matches.count
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        for (place, row) in rows.enumerated() {
            row.frame = CGRect(
                x: Self.inset, y: Self.inset + CGFloat(place) * KeywordCompletionRow.height,
                width: max(bounds.width - 2 * Self.inset, 0), height: KeywordCompletionRow.height,
            )
        }
    }
}

/// A keyword the field completes to: its name, what tells it apart and its count, drawn on the selection's colour
/// when ↓ and ↑ reach it.
final class KeywordCompletionRow: NSButton {
    static let height: CGFloat = 22
    private var match: KeywordCompletion.Match?
    private var isReached = false
    private let onPress: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        onPress = action
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        self.action = #selector(pressed)
    }

    @objc private func pressed() {
        onPress()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ match: KeywordCompletion.Match, highlighted: Bool) {
        self.match = match
        isReached = highlighted
        title = match.synonym ?? match.path.name
        setAccessibilityLabel(match.path.displayName)
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        guard let match else { return }
        if isReached {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        let primary: NSColor = isReached ? .alternateSelectedControlTextColor : .labelColor
        let secondary: NSColor = isReached ? .alternateSelectedControlTextColor : .secondaryLabelColor
        let count = NSAttributedString(string: match.count.formatted(), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: secondary,
        ])
        let countWidth = ceil(count.size().width)
        let line = NSMutableAttributedString(string: match.synonym ?? match.path.name, attributes: [
            .font: PanelControls.font, .foregroundColor: primary,
        ])
        let detail = match.synonym.map { _ in "synonym of \(match.path.name)" } ?? match.path.parent?.displayName
        if let detail {
            line.append(NSAttributedString(string: "  " + detail, attributes: [
                .font: PanelControls.noteFont, .foregroundColor: secondary,
            ]))
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
        let lineHeight = ceil(line.size().height)
        line.draw(in: CGRect(
            x: 6, y: (bounds.height - lineHeight) / 2, width: max(bounds.width - countWidth - 18, 0),
            height: lineHeight,
        ))
        let countHeight = ceil(count.size().height)
        count.draw(at: CGPoint(x: bounds.width - countWidth - 6, y: (bounds.height - countHeight) / 2))
    }

    override var isFlipped: Bool {
        true
    }
}
