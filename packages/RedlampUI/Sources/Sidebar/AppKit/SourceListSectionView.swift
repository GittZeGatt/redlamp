import AppKit
import RedlampDesign

/// A section of the Library module's source list (LIB-45), as the Mac's sidebars have them: a header drawn as the
/// system's source-list group row, then the section's list. A click on the header collapses or expands the section,
/// Option-click leaves it the only one open, and its menu holds the section's commands. A collapsed section's list
/// leaves the window, so it costs nothing.
final class SourceListSectionView: NSView, HeightProviding {
    struct Actions {
        var isExpanded: @MainActor () -> Bool
        var toggle: @MainActor (_ solo: Bool) -> Void
        /// Whether the list has nothing in it yet, when the header's + always shows.
        var isEmpty: @MainActor () -> Bool = { false }
    }

    /// A source list's group row on macOS 26, as AppKit draws it.
    @MainActor enum Layout {
        static let headerHeight: CGFloat = 19
        /// Above the first section, and above each one after it.
        static let firstSpacing: CGFloat = 10
        static let spacing: CGFloat = 13
    }

    let header: SourceListHeaderView
    private let list: NSView
    private let actions: Actions
    private let topSpacing: CGFloat
    private var trackers: [Tracker] = []
    private(set) var isExpanded = false

    init(title: String, first: Bool = false, add: SourceListHeaderView.Add? = nil, list: NSView, actions: Actions) {
        header = SourceListHeaderView(title: title, add: add)
        self.list = list
        self.actions = actions
        topSpacing = first ? Layout.firstSpacing : Layout.spacing
        super.init(frame: CGRect(x: 0, y: 0, width: 250, height: topSpacing + Layout.headerHeight))
        addSubview(header)
        header.onToggle = { [weak self] solo in self?.actions.toggle(solo) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Names the section and its header for VoiceOver and the regression suite: `sidebar.folders` and
    /// `sidebar.folders.header`.
    func identify(as identifier: String) {
        setAccessibilityIdentifier(identifier)
        header.setAccessibilityIdentifier("\(identifier).header")
    }

    override var isFlipped: Bool {
        true
    }

    /// The room a source list leaves above its first row and below its last, which the header and the next section's
    /// spacing take instead.
    private var listPadding: (top: CGFloat, bottom: CGFloat) {
        (list as? SidebarOutlineView)?.padding ?? (0, 0)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard isExpanded else { return topSpacing + Layout.headerHeight }
        let padding = listPadding
        let rows = ColumnView.height(of: list, width: width) - padding.top - padding.bottom
        return topSpacing + Layout.headerHeight + max(rows, 0)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width))
    }

    override func layout() {
        super.layout()
        header.frame = CGRect(x: 0, y: topSpacing, width: bounds.width, height: Layout.headerHeight)
        guard list.superview === self else { return }
        list.frame = CGRect(
            x: 0, y: header.frame.maxY - listPadding.top, width: bounds.width,
            height: ColumnView.height(of: list, width: bounds.width),
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        trackers.forEach { $0.cancel() }
        trackers = []
        guard window != nil else { return }
        trackers = [
            Tracker { [weak self] in
                guard let self else { return }
                setExpanded(actions.isExpanded())
            },
            Tracker { [weak self] in
                guard let self else { return }
                header.showsAdd = actions.isEmpty()
            },
        ]
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded || (expanded && list.superview == nil) else { return }
        let animated = window != nil && isExpanded != expanded && header.hasBeenDisplayed
        isExpanded = expanded
        header.isExpanded = expanded
        if expanded, list.superview == nil {
            // Under the header, which takes the clicks where the list's room above its first row meets it.
            addSubview(list, positioned: .below, relativeTo: header)
        }
        invalidateColumnLayout()
        guard animated else {
            list.alphaValue = 1
            if !expanded {
                list.removeFromSuperview()
            }
            return
        }
        if expanded {
            list.alphaValue = 0
        }
        let column = enclosingColumn
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            list.animator().alphaValue = expanded ? 1 : 0
            column?.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isExpanded else { return }
                self.list.removeFromSuperview()
                self.list.alphaValue = 1
            }
        }
    }

    private var enclosingColumn: NSView? {
        sequence(first: superview, next: { $0?.superview }).lazy.compactMap(\.self)
            .first { $0 is PanelColumnScrollView } ?? superview
    }
}

/// A source-list section's header, drawn as AppKit draws a source list's group row on macOS 26: its title bold in
/// the tertiary label colour, and at its trailing edge the section's + and the chevron that collapses or expands it,
/// both shown while the pointer is over the header, as the Mac's sidebars show them; the + also while the section's
/// list is empty, for the line there that names it.
final class SourceListHeaderView: NSView {
    /// The header's +: what it does, its help, and its identifier.
    struct Add {
        var help: String
        var identifier: String?
        var action: @MainActor (NSView) -> Void
    }

    private let title: NSTextField
    private let chevron = NSButton()
    private let add: NSButton?
    var onToggle: (_ solo: Bool) -> Void = { _ in }
    var menuProvider: (@MainActor () -> NSMenu)?
    private(set) var hasBeenDisplayed = false
    private var hoverArea: NSTrackingArea?

    /// The title's leading edge, as a group row's; the controls end this far from the trailing edge.
    static let titleInset: CGFloat = 16
    static let trailingInset: CGFloat = 12
    static let controlSide: CGFloat = 16
    static let controlGap: CGFloat = 4

    var isExpanded = true {
        didSet {
            if isExpanded != oldValue {
                updateChevron()
            }
        }
    }

    /// The + shows without the pointer over the header.
    var showsAdd = false {
        didSet {
            if showsAdd != oldValue {
                updateControls()
            }
        }
    }

    private var isHovering = false {
        didSet {
            if isHovering != oldValue {
                updateControls()
            }
        }
    }

    init(title: String, add: Add?) {
        self.title = NSTextField(labelWithString: title)
        self.title.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        self.title.textColor = .tertiaryLabelColor
        self.title.lineBreakMode = .byTruncatingTail
        self.add = add.map { add in
            let button = Self.control("plus", help: add.help)
            button.setAccessibilityIdentifier(add.identifier)
            button.onAction { button in add.action(button) }
            return button
        }
        super.init(frame: .zero)
        addSubview(self.title)
        Self.style(chevron)
        chevron.target = self
        chevron.action = #selector(chevronClicked)
        addSubview(chevron)
        if let add = self.add {
            addSubview(add)
        }
        updateChevron()
        updateControls()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static func control(_ symbol: String, help: String) -> NSButton {
        let button = NSButton()
        style(button)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.toolTip = help
        button.setAccessibilityLabel(help)
        return button
    }

    private static func style(_ button: NSButton) {
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        button.contentTintColor = .secondaryLabelColor
        button.refusesFirstResponder = true
    }

    private func updateChevron() {
        let name = title.stringValue
        let help = isExpanded ? "Hide \(name)" : "Show \(name)"
        chevron.image = NSImage(
            systemSymbolName: isExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: help,
        )
        chevron.toolTip = help
        chevron.setAccessibilityLabel(help)
    }

    private func updateControls() {
        chevron.alphaValue = isHovering ? 1 : 0
        add?.alphaValue = isHovering || showsAdd ? 1 : 0
    }

    override var isFlipped: Bool {
        true
    }

    override func layout() {
        super.layout()
        let scale = backingScale
        let side = Self.controlSide
        var trailing = bounds.width - Self.trailingInset
        for control in [chevron, add].compactMap(\.self) {
            control.frame = PixelGrid.snap(
                CGRect(x: trailing - side, y: (bounds.height - side) / 2, width: side, height: side), scale: scale,
            )
            trailing -= side + Self.controlGap
        }
        let size = title.intrinsicContentSize
        // A label draws its text 2 points into its frame.
        let x = Self.titleInset - 2
        title.frame = PixelGrid.snap(
            CGRect(x: x, y: (bounds.height - size.height) / 2, width: max(trailing - x, 0), height: size.height),
            scale: scale,
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        hasBeenDisplayed = true
        super.draw(dirtyRect)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self,
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with _: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with _: NSEvent) {
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1 else { return }
        onToggle(event.modifierFlags.contains(.option))
    }

    @objc private func chevronClicked() {
        onToggle(NSApp.currentEvent?.modifierFlags.contains(.option) == true)
    }

    override func menu(for _: NSEvent) -> NSMenu? {
        menuProvider?()
    }
}
