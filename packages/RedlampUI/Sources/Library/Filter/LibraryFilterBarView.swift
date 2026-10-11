import AppKit
import RedlampDesign
import RedlampDocument
import RedlampLibrary

/// The Library filter bar above the grid (LIB-18, LIB-45): a search field always on screen (DEC-66), the query's terms
/// as its tokens, completed from the index as they're typed; beside it the whole library's count, which searches All
/// Photographs with the same query (DEC-67); the photos found of the source's, and when that's none, the filter's
/// offers (`FilterOffersView`): a name in a misspelt word's place, and the term whose removal brings back the most
/// taken out; the sort; saved filters; and the lock. The Attribute row and the Metadata columns open from the
/// field's buttons beneath it; they read the same query and write it, so what's chosen there shows in the field and
/// the other way round.
///
/// `\` shows and hides the rows open, the field taking the keyboard as they're shown; Esc in the field goes back
/// to the grid.
final class LibraryFilterBarView: NSView, NSTokenFieldDelegate {
    static let rowHeight: CGFloat = 44
    static let attributeHeight: CGFloat = 36
    static let metadataHeight: CGFloat = 168
    private static let gap: CGFloat = 8

    private let model: EditorModel
    private var trackers: [Tracker] = []
    private var counts: LibraryObservation?
    private let status = filterLabel("")
    /// The whole library's photos, which a click searches with the same query (DEC-67).
    private let searchAll = FilterBarButton(identifier: "library.filter.search-all", tip: "Search All Photographs")
    /// While the filter is off (⌘L) with a query: turns it on.
    private let filterOff = FilterBarButton(identifier: "library.filter.none", tip: "Filter Off")
    /// While the filter finds none of the source's photos: what it offers in place of the term in its way.
    private let offers: FilterOffersView
    private let sort = FilterPopUp(identifier: "library.filter.sort", tip: "Sort", large: true)
    private let direction = FilterBarButton(
        identifier: "library.filter.direction",
        symbol: "arrow.up",
        tip: "Ascending",
    )
    private let presets = FilterPopUp(identifier: "library.filter.presets", tip: "Filter Presets", large: true)
    private let lock = FilterBarButton(identifier: "library.filter.lock", symbol: "lock.open", tip: "Lock Filters")
    let field = FilterSearchField()
    private let attributes: FilterAttributeRow
    let columns: FilterColumnsView
    /// The completions of the term being typed, shown over the grid under it.
    let completions = FilterCompletionView()
    /// The query's text as the field last showed it, or typed it.
    private var shownText: String?
    /// Search All has something to search, and is shown when the row has room for it beside the offers.
    private var searchAllWanted = false
    /// What the bar's layout depends on, as last laid out.
    private var laidOut: [AnyHashable] = []

    init(model: EditorModel) {
        self.model = model
        offers = FilterOffersView(model: model)
        attributes = FilterAttributeRow(model: model)
        columns = FilterColumnsView(model: model)
        super.init(frame: CGRect(x: 0, y: 0, width: 1200, height: Self.rowHeight))
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.14, alpha: 1).cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Library Filter")
        setAccessibilityIdentifier("library.filter")
        status.font = .systemFont(ofSize: NSFont.systemFontSize)
        status.alignment = .right
        searchAll.onPress = { [weak self] in self?.model.searchAllPhotographs() }
        searchAll.toolTip = "Search All Photographs for this filter"
        searchAll.isHidden = true
        filterOff.title = "Filter Off"
        filterOff.isHidden = true
        filterOff.toolTip = "The filter is off: click to turn it on (\(ShortcutAction.toggleFilters.title))"
        filterOff.onPress = { [weak self] in self?.model.perform(.toggleFilters) }
        sort.onChoose = { [weak self] tag in
            guard LibrarySortField.allCases.indices.contains(tag) else { return }
            self?.model.sort(by: LibrarySortField.allCases[tag])
        }
        direction.onPress = { [weak self] in self?.model.perform(.reverseSort) }
        presets.onChoose = { [weak self] tag in self?.presetChosen(tag) }
        lock.onPress = { [weak self] in self?.model.perform(.lockFilters) }
        lock.toolTip = "Lock Filters: keep this filter as sources change"
        offers.onResize = { [weak self] in self?.needsLayout = true }
        field.delegate = self
        field.clearButton.target = self
        field.clearButton.action = #selector(clearChosen)
        field.attributeButton.target = self
        field.attributeButton.action = #selector(attributeChosen)
        field.metadataButton.target = self
        field.metadataButton.action = #selector(metadataChosen)
        field.toolTip = "Words find names, folders, keywords and captions; terms such as rating>=3 camera:X-T5 "
            + "kw:birds -flag:reject filter, Tab completing them"
        completions.onChoose = { [weak self] completion in self?.accept(completion) }
        for view: NSView in [
            field,
            searchAll,
            filterOff,
            offers,
            status,
            sort,
            direction,
            presets,
            lock,
            attributes,
            columns,
        ] {
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

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    /// The row, and each row open beneath it.
    private var height: CGFloat {
        Self.rowHeight + (isOpen(.attribute) ? Self.attributeHeight : 0) + (isOpen(.metadata) ? Self.metadataHeight : 0)
    }

    private func isOpen(_ section: FilterSection) -> Bool {
        model.libraryFilters?.isOpen(section) ?? false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        trackers.forEach { $0.cancel() }
        trackers = []
        counts = nil
        guard window != nil else { return }
        trackers = [
            Tracker { [weak self] in
                guard let self else { return }
                _ = (model.folder, model.library.includesSubfolders, model.library.shownSource)
                model.followSource()
            },
            Tracker { [weak self] in
                guard let self else { return }
                model.libraryFilters?.setMoments(MomentSetting(looseness: model.libraryViews.looseness))
            },
            Tracker { [weak self] in
                _ = (self?.model.librarySources.rows, self?.model.librarySources.isCounted)
                self?.update()
            },
            Tracker { [weak self] in
                guard let self, let filters = model.libraryFilters else { return }
                let wasHidden = completions.isHidden
                completions.show(filters.completions)
                if wasHidden != completions.isHidden || !completions.isHidden {
                    placeCompletions()
                }
            },
            Tracker { [weak self] in
                guard let self, let filters = model.libraryFilters else { return }
                _ = (model.library.revision, filters.filter.sections, filters.isBarShown, filters.source)
                if !model.library.isFiltered {
                    filters.countColumns()
                }
            },
        ]
        counts = model.librarySources.observeCounts { [weak self] changed in
            if changed.contains(.allPhotographs) {
                self?.update()
            }
        }
    }

    /// The bar as the filter has it.
    private func update() {
        guard let filters = model.libraryFilters else { return }
        let filter = filters.filter
        if field.text != filter.text, shownText != filter.text {
            field.show(filter.text, typing: false)
        }
        shownText = filter.text
        field.setOpen(attribute: isOpen(.attribute), metadata: isOpen(.metadata))
        let clearHidden = filter.text.isEmpty
        if field.clearButton.isHidden != clearHidden {
            field.clearButton.isHidden = clearHidden
        }
        let placeholder = placeholder
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }
        updateStatus(filters)
        updateSearchAll(filters)
        let filterOffHidden = filter.isEnabled || filter.text.isEmpty
        if filterOff.isHidden != filterOffHidden {
            filterOff.isHidden = filterOffHidden
        }
        sort.set(
            LibrarySortField.allCases.enumerated().map { ($1.title, $0) },
            chosen: LibrarySortField.allCases.firstIndex(of: filters.sort.field),
        )
        direction.symbol = filters.sort.ascending ? "arrow.up" : "arrow.down"
        let directionTip = "\(filters.sort.ascending ? "Ascending" : "Descending") (\(ShortcutAction.reverseSort.title))"
        if direction.toolTip != directionTip {
            direction.toolTip = directionTip
            direction.setAccessibilityLabel(directionTip)
        }
        updatePresets(filters)
        lock.isOn = filters.isLocked
        lock.symbol = filters.isLocked ? "lock.fill" : "lock.open"
        for (view, section) in [(attributes, FilterSection.attribute), (columns, .metadata)] as [(
            NSView,
            FilterSection,
        )]
            where view.isHidden == isOpen(section) {
            view.isHidden = !isOpen(section)
        }
        let layout: [AnyHashable] = [
            isOpen(.attribute), isOpen(.metadata), searchAllWanted, searchAll.title, filterOff.isHidden,
        ]
        if layout != laidOut {
            if layout.prefix(2) != laidOut.prefix(2) {
                invalidateIntrinsicContentSize()
            }
            laidOut = layout
            needsLayout = true
        }
    }

    /// "Search" and the source shown, whose photos typing narrows (DEC-67).
    private var placeholder: String {
        if let source = model.library.shownSource {
            return "Search \(source.title)"
        }
        return model.folder.map { "Search \($0.lastPathComponent)" } ?? "Search"
    }

    /// What the field can't read, while it can't; else the photos found, or what the library is waiting for.
    private func updateStatus(_ filters: LibraryFilters) {
        let note = model.libraryFilterNote
        let total = filters.listed?.total ?? model.library.count
        let shown = model.library.isFiltered ? model.library.count : total
        let count = !model.hasFilterSource ? "" : shown == total
            ? "\(total.formatted()) photos" : "\(shown.formatted()) of \(total.formatted())"
        let error = filters.error?.message
        set(status, error ?? (note.isEmpty ? count : note))
        let color: NSColor = error == nil ? .secondaryLabelColor : .systemRed
        if status.textColor != color {
            status.textColor = color
        }
        if status.toolTip != error ?? note {
            status.toolTip = error ?? note
        }
    }

    /// The whole library's photos beside the field while it has a query and the source isn't All Photographs, as the
    /// Library panel counts them beside All Photographs.
    private func updateSearchAll(_ filters: LibraryFilters) {
        searchAllWanted = model.library.shownSource != .allPhotographs && model.hasFilterSource
            && !filters.filter.text.trimmingCharacters(in: .whitespaces).isEmpty
            && model.library.service?.isReady == true
        let title = model.librarySources.count(of: .allPhotographs).map { "Search All \($0.formatted())" }
            ?? "Search All Photographs"
        if searchAll.title != title {
            searchAll.title = title
        }
    }

    private func updatePresets(_ filters: LibraryFilters) {
        let current = filters.preset
        var items: [(title: String?, tag: Int)] = current == nil ? [("Custom Filter", -1), (nil, 0)] : []
        items += filters.presets.enumerated().map { ($1.name, $0) }
        items += [(nil, 0), ("Save Current Settings as New Preset…", -2)]
        if let current, !current.isBuiltIn {
            items.append(("Delete Preset “\(current.name)”…", -3))
        }
        presets.set(items, chosen: current.flatMap { preset in filters.presets.firstIndex(of: preset) } ?? -1)
    }

    /// Sets a label's text, leaving it alone when it's the same.
    private func set(_ label: NSTextField, _ text: String) {
        if label.stringValue != text {
            label.stringValue = text
        }
    }

    /// The row from its ends: the sort, presets and lock at its end; the field at its start, 300 to 600 points as
    /// the room leaves it (280 beside offers), and after it Search All, the offers and the count. While the filter
    /// finds
    /// nothing, its offers come first: Search All and the count are left out when there isn't room for them too.
    override func layout() {
        super.layout()
        let row = Self.rowHeight
        let height = FilterSearchField.height
        let y = (row - height) / 2
        var right = bounds.width - 12
        func placeRight(_ view: NSView, width: CGFloat) {
            right -= width
            view.frame = CGRect(x: right, y: y, width: width, height: height)
            right -= Self.gap
        }
        placeRight(lock, width: 32)
        placeRight(presets, width: min(max(presets.intrinsicContentSize.width, 110), 150))
        placeRight(direction, width: 32)
        placeRight(sort, width: min(max(sort.intrinsicContentSize.width, 110), 140))
        let offersWidth = offers.isHidden ? 0 : offers.fittingWidth + Self.gap
        let searchAllWidth = searchAllWanted ? searchAll.fittingWidth + Self.gap : 0
        let filterOffWidth = filterOff.isHidden ? 0 : filterOff.fittingWidth + Self.gap
        var room = right - 12 - Self.gap
        let least: CGFloat = offers.isHidden ? 300 : 280
        let fieldWidth = max(min(room - offersWidth - searchAllWidth - filterOffWidth - Self.statusRoom, 600), least)
        field.frame = CGRect(x: 12, y: y, width: max(min(fieldWidth, room), 120), height: height)
        room -= field.frame.width + Self.gap
        var x = field.frame.maxX + Self.gap
        let fits = searchAllWanted && room - offersWidth - filterOffWidth >= searchAllWidth
        if searchAll.isHidden == fits {
            searchAll.isHidden = !fits
        }
        for button in [searchAll, filterOff] where !button.isHidden {
            button.frame = CGRect(x: x, y: y, width: button.fittingWidth, height: height)
            x += button.fittingWidth + Self.gap
            room -= button.fittingWidth + Self.gap
        }
        if !offers.isHidden {
            let width = max(min(offers.fittingWidth, room), 0)
            offers.frame = CGRect(x: x, y: y, width: width, height: height)
            x += width + Self.gap
        }
        let statusWidth = right - x
        status.frame = CGRect(x: x, y: (row - 17) / 2, width: statusWidth < 70 ? 0 : statusWidth, height: 17)
        var top = row
        if isOpen(.attribute) {
            attributes.frame = CGRect(x: 0, y: top, width: bounds.width, height: Self.attributeHeight)
            top += Self.attributeHeight
        }
        if isOpen(.metadata) {
            columns.frame = CGRect(x: 0, y: top, width: bounds.width, height: Self.metadataHeight)
        }
        placeCompletions()
    }

    /// The room the field leaves for the count when there's room for it: "1,234 of 12,345".
    private static let statusRoom: CGFloat = 90

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).intersection(dirtyRect).fill()
    }
}

extension LibraryFilterBarView {
    /// The completions under the text being typed, in the view that holds the bar.
    private func placeCompletions() {
        guard let host = completions.superview else { return }
        let origin = field.typingOrigin(in: host)
        let below = CGRect(x: origin.x, y: origin.y + (host.isFlipped ? 4 : -4), width: 440, height: 0)
        completions.place(under: below, in: host)
    }

    // MARK: - The field's buttons

    @objc private func clearChosen() {
        model.libraryFilters?.clear()
        focusText()
    }

    @objc private func attributeChosen() {
        model.libraryFilters?.toggleRow(.attribute)
    }

    @objc private func metadataChosen() {
        model.libraryFilters?.toggleRow(.metadata)
    }

    // MARK: - Text

    /// The field takes the keyboard, the cursor at its end; one being edited is left as it is, as making it first
    /// responder again would end its editing and make the text being typed a token.
    func focusText() {
        guard let window,
              field.currentEditor() == nil || window.firstResponder !== field.currentEditor() else { return }
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else { return }
        editor.selectedRange = NSRange(location: editor.string.utf16.count, length: 0)
        field.followTyping()
    }

    func controlTextDidChange(_: Notification) {
        guard !field.isShowing, let filters = model.libraryFilters else { return }
        field.followTyping()
        let text = field.text
        if FilterQueryTerms.split(text) != FilterQueryTerms.split(filters.filter.text) {
            shownText = text
            filters.setText(text)
        }
        complete()
    }

    func controlTextDidBeginEditing(_: Notification) {
        model.libraryFilters?.isTyping = true
        model.libraryFilters?.prepareNames()
    }

    func controlTextDidEndEditing(_: Notification) {
        model.libraryFilters?.endCompletion()
        model.libraryFilters?.isTyping = false
        model.keepActivePhotoShown()
    }

    /// Asks for the completions of the term being typed where the cursor is, in the field's text.
    private func complete() {
        guard let filters = model.libraryFilters else { return }
        guard let typing = field.typing else {
            filters.endCompletion()
            return
        }
        filters.complete(field.text, cursor: typing.start + typing.cursor)
    }

    /// ↑ and ↓ move through the completions, Tab and Return take one, Esc closes them or goes back to the grid.
    private func handle(_ key: FilterTextKey) -> Bool {
        let showing = !completions.isHidden && !completions.items.isEmpty
        switch key {
        case .up where showing: completions.move(by: -1)
        case .down where showing: completions.move(by: 1)
        case .tab where showing, .enter where showing:
            guard let chosen = completions.chosen else { return false }
            accept(chosen)
        case .escape where showing:
            model.libraryFilters?.endCompletion()
        case .escape, .enter:
            model.libraryFilters?.endCompletion()
            backToPhotos()
        default:
            return false
        }
        return true
    }

    private func accept(_ completion: FilterCompletion) {
        guard let filters = model.libraryFilters, let range = filters.completionRange else { return }
        let (text, _) = FilterTerm.inserting(completion, in: field.text, at: range)
        shownText = text
        filters.setText(text)
        field.show(text, typing: true)
        if completion.text.hasSuffix(":") {
            complete()
        } else {
            filters.endCompletion()
        }
    }

    /// The keyboard goes back to the grid, or the loupe's view.
    private func backToPhotos() {
        (superview as? LibraryModuleView)?.takeFocus()
    }

    // MARK: - Presets

    private func presetChosen(_ tag: Int) {
        guard let filters = model.libraryFilters else { return }
        switch tag {
        case -2: savePreset()
        case -3: if let preset = filters.preset {
                filters.delete(preset)
            }
        case filters.presets.indices: filters.choose(filters.presets[tag])
        default: break
        }
        update()
    }

    /// Asks for the new preset's name.
    private func savePreset() {
        guard let filters = model.libraryFilters else { return }
        let alert = NSAlert()
        alert.messageText = "New Filter Preset"
        alert.informativeText = "The filter, its rows and its columns are saved under this name."
        let name = NSTextField(frame: CGRect(x: 0, y: 0, width: 240, height: 22))
        name.placeholderString = "Preset Name"
        alert.accessoryView = name
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                filters.save(as: name.stringValue)
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}

/// The keys the bar takes from the field before the field does.
enum FilterTextKey {
    case up, down, tab, enter, escape
}

extension LibraryFilterBarView {
    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        let key: FilterTextKey? = switch selector {
        case #selector(NSResponder.moveUp(_:)): .up
        case #selector(NSResponder.moveDown(_:)): .down
        case #selector(NSResponder.insertTab(_:)): .tab
        case #selector(NSResponder.insertNewline(_:)): .enter
        case #selector(NSResponder.cancelOperation(_:)): .escape
        default: nil
        }
        return key.map { handle($0) } ?? false
    }

    // MARK: - Tokens

    func tokenField(_: NSTokenField, representedObjectForEditing editingString: String) -> Any? {
        editingString
    }

    func tokenField(_: NSTokenField, displayStringForRepresentedObject representedObject: Any) -> String? {
        representedObject as? String
    }

    func tokenField(_: NSTokenField, editingStringForRepresentedObject representedObject: Any) -> String? {
        representedObject as? String
    }

    /// A term the language reads is a token; `OR`, `AND` and what it can't read are plain text among them.
    func tokenField(_: NSTokenField, styleForRepresentedObject representedObject: Any) -> NSTokenField.TokenStyle {
        guard let term = representedObject as? String, term != "OR", term != "AND",
              (try? LibraryQuery(parsing: term)) != nil else { return .plainSquared }
        return .rounded
    }

    /// What's tokenized, typed, pasted or dropped, as terms: a term with a space inside quotes or parentheses is one,
    /// and a quote or parenthesis left open is closed, so it can't reach the terms after it.
    func tokenField(_: NSTokenField, shouldAdd tokens: [Any], at _: Int) -> [Any] {
        let text = tokens.compactMap { $0 as? String }.joined(separator: " ")
        return FilterQueryTerms.split(text).map(FilterQueryTerms.closed)
    }

    func tokenField(_: NSTokenField, writeRepresentedObjects objects: [Any], to pasteboard: NSPasteboard) -> Bool {
        let terms = objects.compactMap { $0 as? String }
        guard !terms.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(terms.joined(separator: " "), forType: .string)
    }

    func tokenField(_: NSTokenField, readFrom pasteboard: NSPasteboard) -> [Any]? {
        pasteboard.string(forType: .string).map { FilterQueryTerms.split($0) }
    }
}

extension EditorModel {
    /// The note beside the filter bar's count: while the library opens, what its search waits for; with
    /// a filter on a folder the library hasn't indexed, that filters wait for it.
    var libraryFilterNote: String {
        if let waiting = library.libraryWaiting {
            return "\(waiting)…"
        }
        guard folder != nil, !library.isShownFromLibrary, libraryFilters?.filter.isEmpty == false else { return "" }
        return "Filters apply once the library has indexed this folder"
    }
}
