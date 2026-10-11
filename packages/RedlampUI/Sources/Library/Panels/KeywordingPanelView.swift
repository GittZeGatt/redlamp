import AppKit
import RedlampDesign
import RedlampLibrary

/// The Keywording panel (LIB-21): the keywords of the photos selected as full paths, as tokens (LIB-45), those
/// only some of them have greyed with how many; a field that adds keywords, completing them from the library's
/// keywords and synonyms in a list under it and making new ones; and the keyword set ⌥1 to ⌥9 apply, chosen here,
/// its nine keywords toggled on the photos by a click on their buttons, each naming its key, with the painter's
/// button beside it (`KeywordPainterButton`).
final class KeywordingPanelView: PanelStackView, NSTextFieldDelegate {
    private let panels: LibraryPanels
    private let summary = PanelControls.note("")
    private let progress = NSProgressIndicator()
    private let tokens = KeywordTokensView()
    /// Below the tokens, how many keywords they leave out.
    private let more = PanelControls.note("")
    private let entry = PanelControls.field(placeholder: "Add Keywords")
    private let completions = KeywordCompletionList()
    private let sets = NSPopUpButton()
    private let setButtons: [ActionButton]
    private var matches: [KeywordCompletion.Match] = []
    private var highlighted: Int?
    private var trackers: [Tracker] = []
    private var shown: (rows: [String], set: String?) = ([], nil)

    init(panels: LibraryPanels) {
        self.panels = panels
        var buttons: [ActionButton] = []
        for number in 1 ... KeywordSet.size {
            let button = ActionButton(title: "") { [weak panels] in _ = panels?.applyKeywordSet(number) }
            button.bezelStyle = .push
            button.controlSize = .regular
            button.font = PanelControls.font
            button.lineBreakMode = .byTruncatingTail
            button.setAccessibilityIdentifier("keywording.set.\(number)")
            button.setButtonType(.pushOnPushOff)
            buttons.append(button)
        }
        setButtons = buttons
        super.init(spacing: 8)
        setAccessibilityIdentifier("keywording")
        progress.style = .bar
        progress.controlSize = .small
        progress.isIndeterminate = false
        // Its row stays while no change is under way: one coming and going lays out the whole column, many
        // milliseconds of the main thread for each change.
        progress.alphaValue = 0
        progress.setAccessibilityElement(false)
        more.isHidden = true
        tokens.onRemove = { [weak panels] path in _ = panels?.remove(path) }
        tokens.onHeightChange = { [weak self] delta in self?.rowsChanged(by: delta) }
        entry.delegate = self
        entry.setAccessibilityIdentifier("keywording.entry")
        entry.toolTip = "Keywords separated by commas; a keyword inside another as Places > Portugal"
        completions.isHidden = true
        completions.onChoose = { [weak self] place in
            guard let self, matches.indices.contains(place) else { return }
            complete(with: matches[place])
            commit()
        }
        sets.controlSize = .regular
        sets.font = PanelControls.font
        sets.target = self
        sets.action = #selector(chooseSet)
        sets.setAccessibilityIdentifier("keywording.sets")
        let grid = NSGridView(views: stride(from: 0, to: buttons.count, by: 3).map { start in
            buttons[start ..< start + 3].map { $0 as NSView }
        })
        grid.rowSpacing = 6
        grid.columnSpacing = 6
        for column in 0 ..< grid.numberOfColumns {
            grid.column(at: column).xPlacement = .fill
        }
        addFullWidth(summary)
        addFullWidth(progress)
        addFullWidth(tokens)
        addFullWidth(more)
        addFullWidth(entry)
        addFullWidth(completions)
        let painter = KeywordPainterButton(model: panels.model)
        // The set's name is cut short before the painter's button is.
        sets.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        painter.setContentCompressionResistancePriority(.required, for: .horizontal)
        painter.setContentHuggingPriority(.required, for: .horizontal)
        addFullWidth(PanelControls.form([("Keyword Set", PanelControls.row([sets, painter]))]))
        addFullWidth(grid)
        stack.setCustomSpacing(4, after: progress)
        stack.setCustomSpacing(4, after: tokens)
        stack.setCustomSpacing(4, after: entry)
        stack.setCustomSpacing(12, after: completions)
        for button in buttons {
            button.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 1.0 / 3, constant: -4).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        trackers.forEach { $0.cancel() }
        trackers = []
        guard window != nil else { return }
        trackers = [
            Tracker { [weak self] in
                guard let self else { return }
                showSelection(panels.selection)
            },
            Tracker { [weak self] in
                guard let self else { return }
                showSets(panels.keywordSets, active: panels.activeSet, selection: panels.selection)
            },
            Tracker { [weak self] in
                guard let self else { return }
                showProgress(panels.progress)
            },
        ]
    }

    // MARK: - Showing

    /// The keywords of the photos selected, as tokens kept from one selection to the next (`KeywordTokensView`),
    /// which say when their height changes, so the panel isn't measured again for a held arrow key's every photo.
    private func showSelection(_ selection: PanelSelection) {
        MetadataPanelView.set(summary, to: Self.summary(of: selection))
        let enabled = selection.isAvailable && !selection.ids.isEmpty
        if entry.isEnabled != enabled {
            entry.isEnabled = enabled
        }
        let all = selection.orderedKeywords
        let ordered = all.prefix(Self.rowLimit)
        let rows = ordered.map { "\($0.path.text) \($0.count)" } + ["\(all.count)"]
        guard rows != shown.rows else { return }
        shown.rows = rows
        tokens.show(ordered, of: selection.ids.count)
        more.stringValue = "and \(all.count - ordered.count) more, in the Keyword List"
        let hidesMore = all.count <= ordered.count
        if more.isHidden != hidesMore {
            more.isHidden = hidesMore
            rowsChanged()
        }
    }

    /// Keywords shown at most: a selection of thousands can have hundreds.
    static let rowLimit = 40

    static func summary(of selection: PanelSelection) -> String {
        if !selection.isAvailable {
            return selection.count == 0 ? "No photo selected" : "Keywords need the folder in the library"
        }
        let count = selection.ids.count
        switch count {
        case 0: return "No photo selected"
        case 1: return selection.count > 1 ? "On 1 of \(selection.count) selected photos" : "On the active photo"
        default: return "On \(count.formatted(.number.locale(Locale(identifier: "en_US")))) selected photos"
        }
    }

    private func showSets(_ all: [KeywordSet], active: KeywordSet?, selection: PanelSelection) {
        let names = all.map(\.name)
        if names != sets.itemTitles {
            sets.removeAllItems()
            sets.addItems(withTitles: names)
        }
        if let active, sets.titleOfSelectedItem != active.name {
            sets.selectItem(withTitle: active.name)
        }
        for (place, button) in setButtons.enumerated() {
            let keyword = active?.keyword(forShortcut: place + 1)
            let enabled = keyword != nil && !selection.ids.isEmpty
            let title = Self.title(keyword?.name, key: place + 1, enabled: enabled)
            if button.attributedTitle != title {
                button.attributedTitle = title
            }
            button.toolTip = keyword.map { "⌥\(place + 1): \($0.displayName)" }
            button.isEnabled = enabled
            button.state = keyword.flatMap(selection.hasEverywhere) == true ? .on : .off
        }
    }

    /// A keyword set's button: the keyword's name, then its key in the small size and the secondary colour.
    private static func title(_ name: String?, key: Int, enabled: Bool) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingMiddle
        let title = NSMutableAttributedString(string: name ?? "—", attributes: [
            .font: PanelControls.font, .paragraphStyle: style,
            .foregroundColor: enabled ? NSColor.controlTextColor : .disabledControlTextColor,
        ])
        if name != nil {
            title.append(NSAttributedString(string: "  ⌥\(key)", attributes: [
                .font: PanelControls.noteFont, .paragraphStyle: style,
                .foregroundColor: enabled ? NSColor.secondaryLabelColor : .tertiaryLabelColor,
            ]))
        }
        return title
    }

    private func showProgress(_ shown: PanelProgress?) {
        progress.alphaValue = shown == nil ? 0 : 1
        progress.setAccessibilityElement(shown != nil)
        if let shown {
            progress.maxValue = Double(max(shown.total, 1))
            progress.doubleValue = Double(shown.done)
            progress.toolTip = "\(shown.title): \(shown.done) of \(shown.total)"
        }
    }

    @objc private func chooseSet() {
        guard let name = sets.titleOfSelectedItem else { return }
        panels.chooseKeywordSet(name)
    }

    // MARK: - The field and its completions

    func controlTextDidChange(_: Notification) {
        matches = panels.completions(entry.stringValue)
        highlighted = nil
        showCompletions()
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)) where !matches.isEmpty:
            highlighted = min((highlighted ?? -1) + 1, matches.count - 1)
            showCompletions()
            return true
        case #selector(NSResponder.moveUp(_:)) where !matches.isEmpty:
            highlighted = highlighted.map { max($0 - 1, 0) }
            showCompletions()
            return true
        case #selector(NSResponder.insertTab(_:)) where !matches.isEmpty:
            complete(with: matches[highlighted ?? 0])
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if let highlighted, matches.indices.contains(highlighted) {
                complete(with: matches[highlighted])
            }
            commit()
            return true
        case #selector(NSResponder.cancelOperation(_:)) where !matches.isEmpty:
            matches = []
            showCompletions()
            return true
        default:
            return false
        }
    }

    /// The term being typed replaced by `match`'s path, written as the field reads it.
    private func complete(with match: KeywordCompletion.Match) {
        var terms = entry.stringValue.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let path = match.path.names.joined(separator: " > ")
        if terms.isEmpty {
            terms = [path]
        } else {
            terms[terms.count - 1] = (terms.count > 1 ? " " : "") + path
        }
        entry.stringValue = terms.joined(separator: ",")
        entry.currentEditor()?.moveToEndOfDocument(nil)
        matches = []
        showCompletions()
    }

    private func commit() {
        let text = entry.stringValue
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if panels.addKeywords(text) {
            entry.stringValue = ""
        }
        matches = []
        showCompletions()
    }

    private func showCompletions() {
        let wasHidden = completions.isHidden
        completions.show(matches, highlighted: highlighted)
        completions.isHidden = matches.isEmpty
        if !wasHidden || !matches.isEmpty {
            rowsChanged()
        }
    }
}
