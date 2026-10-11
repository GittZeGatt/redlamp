import AppKit
import RedlampLibrary

/// The import window's From (LIB-27): the cards on this Mac and the folders added, each with a box to
/// import from it, its count with the photos the library has counted apart, its part of the import as it
/// copies, and at the end whether it's safe to erase, with Eject for a card. Choosing one shows its photos.
/// It's a sidebar as the system draws one (LIB-45), its + and − adding a folder and removing the source chosen.
@MainActor
final class ImportSourcesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let model: ImportWindowModel
    /// Add Folder…: the window asks for the folder.
    var onAddFolder: (() -> Void)?
    let table = NSTableView()
    private let addButton = ImportSourcesViewController.barButton("plus", "Add Folder…")
    private let removeButton = ImportSourcesViewController.barButton("minus", "Remove")
    private var reloading = false
    /// What each row showed when the table was last loaded: it's loaded again only when that changes.
    private var shownRows: [String] = []

    init(model: ImportWindowModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let title = NSTextField(labelWithString: "From")
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        title.textColor = .secondaryLabelColor
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 54
        table.style = .sourceList
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityIdentifier("import.sources")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addButton.target = self
        addButton.action = #selector(addFolder)
        addButton.setAccessibilityIdentifier("import.add-folder")
        removeButton.target = self
        removeButton.action = #selector(removeSource)
        removeButton.setAccessibilityIdentifier("import.remove-source")
        let buttons = NSStackView(views: [addButton, removeButton])
        buttons.spacing = 12
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .followsWindowActiveState
        for view in [title, scroll, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            buttons.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            buttons.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -10),
        ])
        view = sidebar
        view.setFrameSize(NSSize(width: 240, height: 500))
    }

    /// A borderless symbol button at the sidebar's foot, as the system's sidebars have them.
    private static func barButton(_ symbol: String, _ title: String) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.isBordered = false
        button.toolTip = title
        button.setAccessibilityLabel(title)
        return button
    }

    func modelChanged(_ change: ImportWindowModel.Change) {
        guard change == .sources || change == .status else { return }
        let busy = model.phase == .copying || model.phase == .planning
        let rows = model.sources.map { source in
            "\(source.id)|\(source.isIncluded)|\(source.problem ?? "")|\(model.detail(of: source))"
        } + ["\(model.shown ?? "")|\(busy)"]
        guard rows != shownRows else { return }
        shownRows = rows
        reloading = true
        let shown = model.shown
        table.reloadData()
        if let row = model.sources.firstIndex(where: { $0.id == shown }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        reloading = false
        addButton.isEnabled = !busy
        removeButton.isEnabled = !busy && model.shown != nil
    }

    func numberOfRows(in _: NSTableView) -> Int {
        model.sources.count
    }

    func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        guard model.sources.indices.contains(row) else { return nil }
        let row = ImportSourceRow(model.sources[row], detail: model.detail(of: model.sources[row]))
        row.onIncluded = { [weak self] id, included in self?.model.setIncluded(id, included) }
        row.onEject = { [weak self] id in
            guard let self else { return }
            Task { await self.model.eject(id) }
        }
        return row
    }

    func tableViewSelectionDidChange(_: Notification) {
        guard !reloading, model.sources.indices.contains(table.selectedRow) else { return }
        model.show(model.sources[table.selectedRow].id)
    }

    @objc private func addFolder() {
        onAddFolder?()
    }

    @objc private func removeSource() {
        if let shown = model.shown {
            model.remove(shown)
        }
    }
}

/// A source's row: the box, its kind's symbol and its name, Eject for a card, then what it holds or how its import
/// went, and its part of the copying.
final class ImportSourceRow: NSTableCellView {
    var onIncluded: ((String, Bool) -> Void)?
    var onEject: ((String) -> Void)?
    private let id: String
    private let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let ejectButton = NSButton()

    init(_ source: ImportWindowModel.Source, detail: String) {
        id = source.id
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 54))
        box.state = source.isIncluded ? .on : .off
        box.isEnabled = source.problem == nil && !source.isEjected
        box.target = self
        box.action = #selector(toggled)
        box.setAccessibilityLabel("Import from \(source.source.name)")
        box.setAccessibilityIdentifier("import.source." + source.source.name)
        let symbol = NSImageView(image: NSImage(
            systemSymbolName: source.isCard ? "sdcard" : "folder",
            accessibilityDescription: source.isCard ? "Card" : "Folder",
        ) ?? NSImage())
        symbol.contentTintColor = .secondaryLabelColor
        symbol.toolTip = source.isCard ? "Card" : source.source.url.path
        let name = NSTextField(labelWithString: source.source.name)
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        name.toolTip = source.isCard ? source.source.name : source.source.url.path
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSTextField(wrappingLabelWithString: detail)
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        text.textColor = source.problem == nil ? .secondaryLabelColor : .systemRed
        text.maximumNumberOfLines = 2
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var top: [NSView] = [box, symbol, name]
        if source.isCard, source.source.medium.isEjectable, !source.isEjected, source.progress == nil {
            ejectButton.image = NSImage(systemSymbolName: "eject", accessibilityDescription: "Eject")
            ejectButton.isBordered = false
            ejectButton.contentTintColor = .secondaryLabelColor
            ejectButton.toolTip = "Eject \(source.source.name)"
            ejectButton.target = self
            ejectButton.action = #selector(eject)
            ejectButton.setAccessibilityIdentifier("import.eject." + source.source.name)
            top.append(ejectButton)
        }
        let first = NSStackView(views: top)
        first.orientation = .horizontal
        first.alignment = .centerY
        first.spacing = 6
        first.setCustomSpacing(4, after: box)
        // The detail and the bar start under the name.
        let indent: CGFloat = 46
        let lower = NSStackView(views: [text])
        lower.orientation = .vertical
        lower.alignment = .leading
        lower.spacing = 3
        lower.edgeInsets = NSEdgeInsets(top: 0, left: indent, bottom: 0, right: 0)
        var bar: NSProgressIndicator?
        if let progress = source.progress, progress.photos > 0 {
            let shown = NSProgressIndicator()
            shown.isIndeterminate = false
            shown.minValue = 0
            shown.maxValue = Double(progress.photos)
            shown.doubleValue = Double(progress.done + progress.failed)
            shown.controlSize = .small
            lower.addArrangedSubview(shown)
            bar = shown
        }
        let stack = NSStackView(views: [first, lower])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            first.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            lower.widthAnchor.constraint(equalTo: stack.widthAnchor),
            text.widthAnchor.constraint(lessThanOrEqualTo: lower.widthAnchor, constant: -indent),
        ])
        bar?.widthAnchor.constraint(equalTo: lower.widthAnchor, constant: -indent).isActive = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func toggled() {
        onIncluded?(id, box.state == .on)
    }

    @objc private func eject() {
        onEject?(id)
    }
}
