import AppKit
import RedlampDesign

/// A button of the filter bar's Attribute row (LIB-45): the system's accessory bar button, which stays lit while it's
/// on, with a title or a symbol in a colour of its own (a label's); ⇧ and ⌘ held reach `onPress`. Its state follows
/// `isOn`, which the filter sets, rather than the click.
final class FilterToggle: NSButton {
    var onPress: ((NSEvent.ModifierFlags) -> Void)?
    var isOn = false {
        didSet {
            if isOn != oldValue {
                update()
            }
        }
    }

    var symbol: String? {
        didSet {
            if symbol != oldValue {
                image = symbol.map { Self.image($0) }
            }
        }
    }

    private let color: NSColor?

    init(symbol: String? = nil, title: String? = nil, color: NSColor? = nil, identifier: String, tip: String) {
        self.color = color
        super.init(frame: .zero)
        bezelStyle = .accessoryBar
        setButtonType(.pushOnPushOff)
        controlSize = .small
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        self.title = title ?? ""
        if let symbol {
            image = Self.image(symbol)
            imagePosition = title == nil ? .imageOnly : .imageLeading
        }
        self.symbol = symbol
        target = self
        action = #selector(pressed)
        toolTip = tip
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(tip)
        update()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The width its title or symbol needs, its bezel close around it so the row's every button fits beside the
    /// others in a window 1,600 points wide.
    var fittingWidth: CGFloat {
        let text = title.isEmpty ? 0 : ceil((title as NSString).size(withAttributes: [.font: font as Any]).width)
        return switch (image != nil, text > 0) {
        case (true, false): 24
        case (true, true): text + 32
        default: text + 14
        }
    }

    /// A colour of its own is drawn in its symbol's palette: the bezel draws a template image in its own colour.
    private func update() {
        state = isOn ? .on : .off
        if let color, let symbol {
            let tint = isOn ? color : color.withAlphaComponent(0.55)
            image = Self.image(symbol, palette: [tint])
        }
    }

    /// The symbol at a small control's size, 11 points, on whole pixels.
    private static func image(_ symbol: String, palette: [NSColor]? = nil) -> NSImage {
        PixelSymbol.image(symbol, pointSize: 11, palette: palette)
    }

    override func accessibilityValue() -> Any? {
        isOn ? "on" : "off"
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    @objc private func pressed() {
        state = isOn ? .on : .off
        onPress?(NSApp.currentEvent?.modifierFlags.intersection([.shift, .command]) ?? [])
    }
}

/// The width `label` needs for its text: its own padding included.
@MainActor
func filterWidth(_ label: NSTextField) -> CGFloat {
    ceil(label.intrinsicContentSize.width) + 4
}

/// A small text label for the bar.
@MainActor
func filterLabel(_ text: String, secondary: Bool = true) -> NSTextField {
    FilterLabel(text, secondary: secondary)
}

/// The bar's label, in the theme's label or secondary label colour as it changes.
final class FilterLabel: NSTextField, ThemeFollowing {
    private var secondary = true

    convenience init(_ text: String, secondary: Bool) {
        self.init(labelWithString: text)
        self.secondary = secondary
        font = Typography.caption.nsFont
        lineBreakMode = .byTruncatingTail
        followTheme()
    }

    func followTheme() {
        textColor = (secondary ? LibraryLook.tokens.secondaryLabel : LibraryLook.tokens.label).nsColor
    }
}

/// A pop-up of the bar, its menu's items calling back with their tags: `large`, the system's pop-up button at the
/// search field's size, for the bar's row (LIB-45); else a small one without a bezel, for a column's header.
final class FilterPopUp: NSPopUpButton {
    var onChoose: ((Int) -> Void)?
    /// The items' titles and tags as last set.
    private var shown: (titles: [String], tags: [Int]) = ([], [])

    init(identifier: String, tip: String, large: Bool = false) {
        super.init(frame: .zero, pullsDown: false)
        if large {
            controlSize = .large
            font = .systemFont(ofSize: NSFont.systemFontSize)
            bezelStyle = .push
        } else {
            controlSize = .small
            font = Typography.caption.nsFont
            bezelStyle = .flexiblePush
            isBordered = false
        }
        toolTip = tip
        target = self
        action = #selector(chose)
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(tip)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Sets its items, `(title, tag)`, a nil title for a separator, choosing the one tagged `chosen`.
    func set(_ items: [(title: String?, tag: Int)], chosen: Int?) {
        let titles = items.map { $0.title ?? "" }
        let tags = items.map(\.tag)
        if titles != shown.titles || tags != shown.tags {
            shown = (titles, tags)
            fill(items)
        }
        if let chosen, let index = menu?.items.firstIndex(where: { $0.tag == chosen && !$0.isSeparatorItem }),
           index != indexOfSelectedItem {
            selectItem(at: index)
        }
    }

    private func fill(_ items: [(title: String?, tag: Int)]) {
        let menu = NSMenu()
        for item in items {
            guard let title = item.title else {
                menu.addItem(.separator())
                continue
            }
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            entry.tag = item.tag
            menu.addItem(entry)
        }
        self.menu = menu
    }

    @objc private func chose() {
        if let tag = selectedItem?.tag {
            onChoose?(tag)
        }
    }
}

/// A button of the filter bar's row at the search field's size (LIB-45): a title, as an accessory bar's action
/// button, or a symbol, as a push button, tinted while it's on as the system's controls are
/// (`LibraryLook.nativeTint`).
final class FilterBarButton: NSButton, ThemeFollowing {
    var onPress: (() -> Void)?
    var isOn = false {
        didSet {
            if isOn != oldValue {
                followTheme()
                setAccessibilityValue(isOn ? "on" : "off")
            }
        }
    }

    var symbol: String? {
        didSet {
            if symbol != oldValue {
                image = symbol.map { PixelSymbol.image($0, pointSize: 13) }
            }
        }
    }

    /// A title is what VoiceOver says of it, as it's what it shows.
    override var title: String {
        didSet {
            if !title.isEmpty, title != oldValue {
                setAccessibilityLabel(title)
            }
        }
    }

    init(identifier: String, symbol: String? = nil, tip: String) {
        super.init(frame: .zero)
        controlSize = .large
        font = .systemFont(ofSize: NSFont.systemFontSize)
        bezelStyle = symbol == nil ? .accessoryBarAction : .push
        setButtonType(.momentaryPushIn)
        title = ""
        if let symbol {
            image = PixelSymbol.image(symbol, pointSize: 13)
            imagePosition = .imageOnly
            imageScaling = .scaleNone
        }
        self.symbol = symbol
        target = self
        action = #selector(pressed)
        toolTip = tip
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(tip)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func followTheme() {
        contentTintColor = isOn ? LibraryLook.nativeTint : nil
    }

    /// The width its title or symbol needs.
    var fittingWidth: CGFloat {
        ceil(fittingSize.width)
    }

    @objc private func pressed() {
        onPress?()
    }
}
