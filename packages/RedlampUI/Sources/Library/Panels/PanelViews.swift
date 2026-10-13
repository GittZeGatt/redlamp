import AppKit
import RedlampDesign

/// A Library panel's rows as AppKit lays them out (LIB-21, LIB-22): a vertical stack, as tall as its rows at
/// the column's width. Rows hold one line each, so their heights don't depend on the width. The height is worked
/// out again only after `rowsChanged`: the column asks every panel for its height whenever one changes, and
/// working out the Metadata panel's takes milliseconds.
class PanelStackView: NSView, HeightProviding {
    let stack = NSStackView()
    private let width: NSLayoutConstraint
    private var measured: (width: CGFloat, height: CGFloat)?

    init(spacing: CGFloat = 6) {
        width = stack.widthAnchor.constraint(equalToConstant: 280)
        super.init(frame: CGRect(x: 0, y: 0, width: 280, height: 60))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            width,
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        if let measured, measured.width == width {
            return measured.height
        }
        if self.width.constant != width {
            self.width.constant = width
        }
        let height = ceil(stack.fittingSize.height)
        measured = (width, height)
        return height
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width))
    }

    override func layout() {
        super.layout()
        if width.constant != bounds.width {
            width.constant = bounds.width
        }
    }

    /// Adds `view` as a row as wide as the panel.
    func addFullWidth(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    /// The rows changed, or the height of one did: the column lays the panel out again.
    func rowsChanged() {
        measured = nil
        invalidateColumnLayout()
    }

    /// The rows' height changed by `delta` alone, as a panel that knows its rows' heights works it out: the column
    /// lays the panel out again without measuring it, which takes a layout pass over every row of its own.
    func rowsChanged(by delta: CGFloat) {
        guard let known = measured else { return rowsChanged() }
        measured = (known.width, known.height + delta)
        invalidateColumnLayout()
    }
}

/// The Library panels' controls as a Mac inspector has them (LIB-45): the system's controls at their regular size and
/// its fonts, the theme's colours as Develop's panels have them (values `value`, a form's labels `label`, notes
/// `secondaryLabel`), and forms laid out as the system lays out a form.
@MainActor
enum PanelControls {
    /// The text of the panels' controls and labels.
    static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    /// A note about a control or the selection.
    static let noteFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    /// Between a form's rows, and between a label and its control.
    static let rowSpacing: CGFloat = 7
    static let columnSpacing: CGFloat = 8

    static func label(_ text: String, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = (secondary ? Palette.secondaryLabel : Palette.value).nsColor
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// A line about the selection or a control, in the small size and the secondary colour.
    static func note(_ text: String) -> NSTextField {
        let note = NSTextField(labelWithString: text)
        note.font = noteFont
        note.textColor = Palette.secondaryLabel.nsColor
        note.lineBreakMode = .byTruncatingTail
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return note
    }

    /// A form's label: the name and a colon, its trailing edge against its control.
    static func formLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text + ":")
        label.font = font
        label.textColor = Palette.label.nsColor
        label.alignment = .right
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    /// Labels and their controls, as the system lays out a form: the labels' trailing edges in one column, the
    /// controls' leading edges in the next, each row's on its first baseline. A row without a label has its control
    /// in the second column.
    static func form(_ rows: [(label: String?, control: NSView)]) -> NSGridView {
        let labels = rows.map { $0.label.map(formLabel) }
        let grid = NSGridView(views: zip(labels, rows).map { label, row in
            [label ?? NSGridCell.emptyContentView, row.control]
        })
        grid.rowSpacing = rowSpacing
        grid.columnSpacing = columnSpacing
        grid.rowAlignment = .firstBaseline
        // As wide as its widest label, the controls taking the rest.
        grid.column(at: 0).width = ceil(labels.compactMap { $0?.intrinsicContentSize.width }.max() ?? 0)
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        for row in rows {
            row.control.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.control.trailingAnchor.constraint(lessThanOrEqualTo: grid.trailingAnchor).isActive = true
        }
        return grid
    }

    /// A text field as the system draws one at its regular size.
    static func field(placeholder: String? = nil) -> NSTextField {
        let field = NSTextField()
        field.font = font
        field.controlSize = .regular
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        return field
    }

    static func button(_ title: String, identifier: String, action: @escaping @MainActor () -> Void) -> NSButton {
        let button = ActionButton(title: title, action: action)
        button.bezelStyle = .push
        button.controlSize = .regular
        button.font = font
        button.setAccessibilityIdentifier(identifier)
        return button
    }

    static func symbolButton(
        _ symbol: String, _ description: String, identifier: String, action: @escaping @MainActor () -> Void,
    ) -> NSButton {
        let button = ActionButton(title: "", action: action)
        button.image = PixelSymbol.image(symbol, pointSize: 13, accessibilityDescription: description)
        button.isBordered = false
        button.toolTip = description
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(description)
        return button
    }

    /// A row of views side by side, the first one taking the room left.
    static func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = spacing
        row.distribution = .fill
        views.first?.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }
}

/// A button that runs a closure.
final class ActionButton: NSButton {
    var onPress: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        onPress = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(pressed)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func pressed() {
        onPress()
    }
}

/// A sheet of labelled fields with Cancel and a default button, over the editor window: the source list's (New
/// Collection…, Rename…, Add to a Collection…, the smart collection editor) and the panels' (Custom Labels, the
/// Keyword List's, Code Replacements, Edit Capture Time, Metadata Presets). On macOS 26 a sheet has no title bar, so
/// its title heads it, as the Mac's own sheets do; then its fields, each label trailing in its column at the field's
/// first baseline, and at the bottom any leading buttons, then Cancel and the default button, which Return presses
/// and the regression suite finds as `panelSheet.ok`. Shortcuts stay off while it's up.
@MainActor
final class PanelSheet: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let heading: NSTextField
    private let grid = NSGridView()
    private let model: EditorModel
    private var done: (@MainActor () -> Bool)?
    /// Buttons at the leading edge of the sheet's bottom row, such as Delete Preset.
    var leadingButtons: [NSView] = []
    private static var shown: [PanelSheet] = []

    /// The Mac's spacing for a sheet: its margins, under its heading, between its rows and their columns, and above
    /// its buttons; and its push buttons' least width, so a short title doesn't make a small target.
    @MainActor enum Layout {
        static let margin: CGFloat = 20
        static let belowHeading: CGFloat = 14
        static let rowSpacing: CGFloat = 10
        static let columnSpacing: CGFloat = 8
        static let aboveButtons: CGFloat = 20
        static let buttonSpacing: CGFloat = 12
        static let buttonWidth: CGFloat = 80
    }

    init(title: String, model: EditorModel) {
        self.model = model
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 440, height: 200), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.title = title
        heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        heading.lineBreakMode = .byTruncatingTail
        heading.setAccessibilityIdentifier("sourceSheet.heading")
        super.init()
        grid.rowSpacing = Layout.rowSpacing
        grid.columnSpacing = Layout.columnSpacing
        grid.translatesAutoresizingMaskIntoConstraints = false
    }

    /// A row: a label and a control, or a control alone, under the controls before it.
    func add(_ label: String?, _ control: NSView) {
        if let label {
            let text = NSTextField(labelWithString: label)
            text.alignment = .right
            let row = grid.addRow(with: [text, control])
            row.cell(at: 0).xPlacement = .trailing
            row.rowAlignment = .firstBaseline
        } else {
            let row = grid.addRow(with: [NSGridCell.emptyContentView, control])
            row.cell(at: 0).xPlacement = .trailing
        }
    }

    /// Shows the sheet over the editor window; `done` runs on the default button and says whether the sheet may close.
    /// With `lines`, the sheet holds text of many lines, where Return starts a new one, and ⌘Return is the default
    /// button's. False when there's no window to show it over.
    @discardableResult
    func begin(
        button: String, first: NSView? = nil, lines: Bool = false, done: @escaping @MainActor () -> Bool,
    ) -> Bool {
        guard let parent = EditorWindowController.frontWindow, !model.isModalDialogOpen else { return false }
        self.done = done
        let content = NSView()
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1B}"
        cancel.setAccessibilityIdentifier("panelSheet.cancel")
        let ok = NSButton(title: button, target: self, action: #selector(confirm))
        ok.keyEquivalent = "\r"
        if lines {
            ok.keyEquivalentModifierMask = [.command]
        }
        ok.setAccessibilityIdentifier("panelSheet.ok")
        let buttons = PanelSheet.buttons(cancel: cancel, ok: ok, leading: leadingButtons)
        for view in [heading, grid, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let margin = Layout.margin
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: margin),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -margin),
            grid.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: Layout.belowHeading),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            buttons.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: Layout.aboveButtons),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),
            leadingButtons.isEmpty
                ? buttons.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: margin)
                : buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.initialFirstResponder = first
        model.isModalDialogOpen = true
        Self.shown.append(self)
        parent.beginSheet(window)
        return true
    }

    /// A sheet's buttons as the system's dialogs place them: `leading` at the leading edge, then at the trailing edge
    /// Cancel and the default button.
    static func buttons(cancel: NSButton, ok: NSButton, leading: [NSView] = []) -> NSStackView {
        for button in [cancel, ok] {
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: Layout.buttonWidth).isActive = true
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: leading + (leading.isEmpty ? [] : [spacer]) + [cancel, ok])
        stack.orientation = .horizontal
        stack.spacing = Layout.buttonSpacing
        return stack
    }

    @objc private func confirm() {
        guard done?() ?? true else { return }
        close()
    }

    @objc private func cancel() {
        close()
    }

    /// Closes the sheet without its default button.
    func end() {
        close()
    }

    private func close() {
        model.isModalDialogOpen = false
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
        Self.shown.removeAll { $0 === self }
    }
}
