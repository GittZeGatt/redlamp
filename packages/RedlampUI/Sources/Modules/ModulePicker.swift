import AppKit
import RedlampDesign

/// The module picker in the toolbar, the modules by name as Lightroom Classic has them, drawn as a segmented control:
/// the module shown in a capsule, each a click away. A click switches at once: the picker takes the press itself
/// rather than tracking the mouse as a button would.
final class ModulePickerView: NSView {
    private let model: EditorModel
    private let buttons: [AppModule: NSButton]
    private let chosen = CALayer()
    private var tracker: Tracker?

    private static let spacing: CGFloat = 14
    private static let padding: CGFloat = 10
    private static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)

    init(model: EditorModel) {
        self.model = model
        var buttons: [AppModule: NSButton] = [:]
        for module in AppModule.allCases {
            let button = NSButton(title: module.title, target: nil, action: nil)
            button.isBordered = false
            button.setButtonType(.momentaryChange)
            button.font = Self.font
            button.toolTip = "\(module.title) (\(module.action.combos.first?.display ?? ""))"
            button.setAccessibilityIdentifier("module.\(module.rawValue)")
            buttons[module] = button
        }
        self.buttons = buttons
        super.init(frame: .zero)
        wantsLayer = true
        chosen.backgroundColor = ToolbarLook.chosen
        chosen.actions = LibraryGridCell.noActions
        layer?.addSublayer(chosen)
        for module in AppModule.allCases {
            guard let button = buttons[module] else { continue }
            button.target = self
            button.action = #selector(choose(_:))
            addSubview(button)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Module")
        setFrameSize(fittingSize)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        let widths = AppModule.allCases.compactMap { buttons[$0]?.intrinsicContentSize.width }
        let height = buttons.values.map(\.intrinsicContentSize.height).max() ?? 22
        return NSSize(
            width: widths.reduce(0, +) + Self.spacing * CGFloat(max(widths.count - 1, 0)) + Self.padding * 2,
            height: max(height, 24),
        )
    }

    override func layout() {
        super.layout()
        var x = Self.padding
        for module in AppModule.allCases {
            guard let button = buttons[module] else { continue }
            let size = button.intrinsicContentSize
            button.frame = CGRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            x += size.width + Self.spacing
        }
        placeChosen()
    }

    /// The capsule behind the module shown.
    private func placeChosen() {
        guard let button = buttons[model.module] else { return }
        let height = min(bounds.height - 2, 24)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chosen.frame = CGRect(
            x: button.frame.minX - Self.spacing / 2 + 1, y: (bounds.height - height) / 2,
            width: button.frame.width + Self.spacing - 2, height: height,
        )
        chosen.cornerRadius = height / 2
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        tracker = Tracker { [weak self] in
            guard let self else { return }
            let shown = model.module
            placeChosen()
            for (module, button) in buttons {
                let color = (module == shown ? Palette.value : Palette.secondaryLabel).nsColor
                button.attributedTitle = NSAttributedString(
                    string: module.title, attributes: [.foregroundColor: color, .font: Self.font],
                )
                button.setAccessibilityValue(module == shown ? "shown" : nil)
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let button = buttons.values
            .first(where: { $0.frame.insetBy(dx: -Self.spacing / 2, dy: -6).contains(point) })
        else { return }
        choose(button)
    }

    @objc private func choose(_ sender: NSButton) {
        guard let module = buttons.first(where: { $0.value === sender })?.key else { return }
        model.perform(module.action)
    }
}

/// The picker's place in the toolbar: all the room between the window's title and the buttons after it, with the
/// picker in the middle of the window, or as near it as that room allows. The toolbar's sections follow the panels,
/// so the middle of the picker's section is the window's only while neither panel shows. The toolbar's glass would
/// span the whole slot, so the slot draws its own behind the picker, as the toolbar draws it behind an item.
final class ModulePickerSlot: NSView {
    /// The toolbar's glass behind an item: as tall and as round as AppKit's.
    private static let platterHeight: CGFloat = 36
    private let picker: ModulePickerView
    private let platter = NSGlassEffectView()

    init(picker: ModulePickerView) {
        self.picker = picker
        let width = picker.intrinsicContentSize.width
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: Self.platterHeight))
        platter.cornerRadius = Self.platterHeight / 2
        platter.contentView = picker
        addSubview(platter)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: width),
            widthAnchor.constraint(lessThanOrEqualToConstant: 4000),
            heightAnchor.constraint(equalToConstant: Self.platterHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Where the picker goes depends on where the slot is in the window, not only on its size.
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = picker.intrinsicContentSize.width
        let middle = window.map { convert(CGPoint(x: $0.frame.width / 2, y: 0), from: nil).x } ?? bounds.midX
        let x = min(max(middle - width / 2, 0), max(bounds.width - width, 0))
        platter.frame = CGRect(x: x.rounded(), y: 0, width: width, height: bounds.height)
    }

    /// Clicks beside the picker reach the toolbar, which moves the window, as they would on an empty part of it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit?.isDescendant(of: picker) == true ? hit : nil
    }
}

@MainActor
enum ModulePicker {
    static func item(_ identifier: NSToolbarItem.Identifier, model: EditorModel) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Module"
        let picker = ModulePickerView(model: model)
        picker.toolTip = "Library (⌥⌘1) or Develop (⌥⌘2)"
        item.view = ModulePickerSlot(picker: picker)
        item.isBordered = false
        return item
    }
}
