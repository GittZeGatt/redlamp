import AppKit

/// A sheet of the source list's (LIB-23, LIB-45): New Collection…, Rename…, Add to a Collection… and the smart
/// collection
/// editor. On macOS 26 a sheet has no title bar, so its title heads it, as the Mac's own sheets do; then its fields,
/// each with its label before it, and at the bottom Cancel, then the default button, which Return presses and the
/// regression suite finds as `panelSheet.ok`. It holds the editor's other commands while it's up.
@MainActor
final class SourceSheet: NSObject {
    let window: NSWindow
    private let heading: NSTextField
    private let grid = NSGridView()
    private let model: EditorModel
    private var done: (@MainActor () -> Bool)?
    private static var shown: [SourceSheet] = []

    /// The Mac's spacing for a sheet: its margins, under its heading, between its rows, and above its buttons.
    @MainActor enum Layout {
        static let margin: CGFloat = 20
        static let belowHeading: CGFloat = 14
        static let rowSpacing: CGFloat = 10
        static let aboveButtons: CGFloat = 20
        static let buttonWidth: CGFloat = 76
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
        grid.columnSpacing = 8
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
    /// False when there's no window to show it over.
    @discardableResult
    func begin(button: String, first: NSView? = nil, done: @escaping @MainActor () -> Bool) -> Bool {
        guard let parent = EditorWindowController.frontWindow, !model.isModalDialogOpen else { return false }
        self.done = done
        let content = NSView()
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1B}"
        cancel.setAccessibilityIdentifier("panelSheet.cancel")
        let ok = NSButton(title: button, target: self, action: #selector(confirm))
        ok.keyEquivalent = "\r"
        ok.setAccessibilityIdentifier("panelSheet.ok")
        for button in [cancel, ok] {
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: Layout.buttonWidth).isActive = true
        }
        let buttons = NSStackView(views: [cancel, ok])
        buttons.spacing = 12
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
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: margin),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.initialFirstResponder = first
        model.isModalDialogOpen = true
        Self.shown.append(self)
        parent.beginSheet(window)
        return true
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
