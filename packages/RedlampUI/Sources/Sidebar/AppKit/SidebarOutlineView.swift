import AppKit
import RedlampDesign
import RedlampDocument
import RedlampRecipes

/// A row of a sidebar list: a recipe group, a recipe or one of the other rows.
final class SidebarNode: NSObject {
    enum Kind {
        case group(String)
        case recipe(Recipe)
        /// The last applied recipe's Amount slider.
        case recipeAmount(String, Double)
        case placeholder(String)
        case snapshot(Snapshot)
        case history(HistoryStep, index: Int, current: Bool, future: Bool)
        /// An earlier session with the photo, its steps inside.
        case session(HistorySession)
        /// A step of an earlier session: choosing it brings its edit back as a new step.
        case earlierStep(HistoryStep, session: HistorySession)
        /// A folder of the working set, its subfolders inside.
        case folder(FolderRow)
        /// Recently Trashed, after the folders (LIB-26).
        case recentlyTrashed(TrashRow)
        /// A Library entry, a check of Library Health, or a place in the collection list (LIB-23).
        case source(SourceRow)
        /// Library Health's checks, inside it (LIB-40).
        case libraryHealth
    }

    /// Updated in place by lists that reload one row at a time (the Folders panel).
    var kind: Kind
    let children: [SidebarNode]

    init(_ kind: Kind, children: [SidebarNode] = []) {
        self.kind = kind
        self.children = children
    }
}

/// One of the sidebar's lists: an outline view as tall as its rows, with no scroll view of its
/// own, so the panels around it scroll together. Groups and earlier sessions expand in place.
/// Subclasses with rows of their own (the Folders panel) override the data source and `track()`.
///
/// In the Library module's source list (`Look.sourceList`, LIB-45) it's a Mac source list: AppKit's style, its row
/// heights for the sidebar size chosen in System Settings, its disclosure chevrons, the source shown as its selection,
/// and its highlights for a drop and for a row's menu. It never takes the keyboard, which stays with the grid.
class SidebarOutlineView: NSOutlineView, HeightProviding, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// How a list looks: as the Develop panels' rows, or as a Mac source list.
    enum Look {
        case panel, sourceList
    }

    /// In a source list, a row's content ends this far from the list's trailing edge, inside the selection; a top-level
    /// row's starts at most this far from its leading edge.
    static let sourceListTrailingInset: CGFloat = 18
    static let sourceListLeadingInset: CGFloat = 25
    /// A list this short may hold the line that says what an empty section holds, whose height its width decides.
    private static let mostRowsWrapped = 4

    /// How much wider than its column a source list tiles itself, measured on one of AppKit's own: measured on
    /// this one, its own column sizing would take part.
    private static let sourceListPadding: CGFloat = {
        let probe = NSOutlineView(frame: .zero)
        let column = NSTableColumn(identifier: .init("probe"))
        probe.addTableColumn(column)
        probe.outlineTableColumn = column
        probe.headerView = nil
        probe.style = .sourceList
        probe.rowSizeStyle = .default
        probe.tile()
        return probe.frame.width - column.width
    }()

    /// The rows, read while tracked: the list reloads when anything they read changes.
    final var content: @MainActor () -> [SidebarNode] = { [] }
    /// Whether a group or session shows its rows when the list reloads.
    final var isExpanded: @MainActor (SidebarNode) -> Bool = { _ in false }
    final var expansionChanged: @MainActor (SidebarNode, Bool) -> Void = { _, _ in }
    /// Files dropped on the list, filtered by `acceptsFiles`. A list without it refuses drops.
    final var dropFiles: (@MainActor ([URL]) -> Void)? {
        didSet {
            if dropFiles == nil {
                unregisterDraggedTypes()
            } else {
                registerForDraggedTypes([.fileURL])
            }
        }
    }

    /// The dropped files the list takes; none refuses the drop.
    final var acceptsFiles: @MainActor ([URL]) -> [URL] = { $0 }

    let model: EditorModel
    let look: Look
    /// How much wider than its column the list tiles itself: none in the panels, a source list's padding in one.
    private var columnPadding: CGFloat = 0
    private var roots: [SidebarNode] = []
    private var tracker: Tracker?
    /// Rows are being reloaded: expansion changes then are restorations, not the user's.
    var isReloading = false
    /// Library's photos are dragged over the list, and the row that takes them is outlined.
    private var isDraggingPhotos = false
    private(set) var photoDropRow: Int?

    init(model: EditorModel, look: Look = .panel) {
        self.model = model
        self.look = look
        super.init(frame: CGRect(x: 0, y: 0, width: 250, height: 0))
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        addTableColumn(column)
        outlineTableColumn = column
        columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        headerView = nil
        backgroundColor = .clear
        switch look {
        case .panel:
            style = .plain
            selectionHighlightStyle = .none
            intercellSpacing = .zero
            indentationPerLevel = SidebarCellView.Layout.indent
            rowHeight = SidebarCellView.Layout.rowHeight
        case .sourceList:
            style = .sourceList
            rowSizeStyle = .default
            selectionHighlightStyle = .regular
            draggingDestinationFeedbackStyle = .sourceList
            refusesFirstResponder = true
            columnPadding = Self.sourceListPadding
        }
        dataSource = self
        delegate = self
        target = self
        action = #selector(rowClicked)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopTracking()
        if window != nil {
            track()
        }
    }

    /// Starts keeping the rows up to date, when the list joins a window.
    func track() {
        tracker = Tracker { [weak self] in
            guard let self else { return }
            show(content())
        }
    }

    func stopTracking() {
        tracker?.cancel()
        tracker = nil
    }

    /// Shows the rows again, after something they read that isn't observed (a search) changed.
    func refresh() {
        show(content())
    }

    /// Reloading starts every row collapsed; the column is told the list's height once the
    /// rows that were open are open again, so it never shrinks (and scrolls) in between.
    private func show(_ nodes: [SidebarNode]) {
        roots = nodes
        isReloading = true
        reloadData()
        expand(roots)
        isReloading = false
        selectHighlighted()
        invalidateColumnLayout()
    }

    private func expand(_ nodes: [SidebarNode]) {
        for node in nodes where !node.children.isEmpty && isExpanded(node) {
            expandItem(node)
            expand(node.children)
        }
    }

    /// A source list tiles itself taller than its rows, by its style's padding: it's as tall as it makes itself, or
    /// setting another height would tile it again.
    func height(forWidth _: CGFloat) -> CGFloat {
        if look == .sourceList {
            tile()
            return frame.height
        }
        return numberOfRows > 0 ? rect(ofRow: numberOfRows - 1).maxY : 0
    }

    /// The room above the first row and below the last, which a source list's padding leaves.
    var padding: (top: CGFloat, bottom: CGFloat) {
        let height = height(forWidth: bounds.width)
        guard numberOfRows > 0 else { return (0, height) }
        return (rect(ofRow: 0).minY, height - rect(ofRow: numberOfRows - 1).maxY)
    }

    /// The column fills the list. A source list tiles itself as wide as its column and its style's padding, which a
    /// column as wide as the list would make wider again, without end.
    override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize.width != frame.width
        super.setFrameSize(newSize)
        let width = max(newSize.width - columnPadding, 0)
        if let column = tableColumns.first, column.width != width {
            column.width = width
        }
        if look == .sourceList, resized, (1 ... Self.mostRowsWrapped).contains(numberOfRows) {
            noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0 ..< numberOfRows))
        }
    }

    /// Rows start at the panel's padding, a level further in for each level down, with the
    /// first part of each for a group's chevron. A source list's rows are where AppKit puts them, ending inside
    /// the selection.
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let rowRect = rect(ofRow: row)
        guard look == .panel else {
            var frame = super.frameOfCell(atColumn: column, row: row)
            frame.size.width = max(rowRect.maxX - Self.sourceListTrailingInset - frame.minX, 0)
            return frame
        }
        let x = Metrics.panelPadding + CGFloat(level(forRow: row)) * indentationPerLevel
        return CGRect(
            x: x, y: rowRect.minY, width: max(rowRect.width - x - Metrics.panelPadding, 0), height: rowRect.height,
        )
    }

    /// A source list's disclosure chevrons are AppKit's; the panels draw their own.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        look == .sourceList ? super.frameOfOutlineCell(atRow: row) : .zero
    }

    /// Whether `point` is on the disclosure chevron of row `row` in a source list.
    private func isOnDisclosure(_ point: CGPoint, row: Int) -> Bool {
        look == .sourceList && frameOfOutlineCell(atRow: row).insetBy(dx: -2, dy: 0).contains(point)
    }

    /// A table view only passes clicks to controls in its rows: the Amount slider.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        responder is NSSlider || super.validateProposedFirstResponder(responder, for: event)
    }

    /// A source's row shows its source as it's pressed, as the Finder's sidebar shows a place, and a set's chevron
    /// opens or closes it; every other row is the table's, which acts as the click ends.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = row(at: point)
        guard index >= 0, let node = item(atRow: index) as? SidebarNode, case let .source(source) = node.kind,
              !isOnDisclosure(point, row: index)
        else {
            return super.mouseDown(with: event)
        }
        let chevronEnd = frameOfCell(atColumn: 0, row: index).minX + SidebarCellView.Layout.chevronSize.width + 4
        if look == .panel, isExpandable(node), point.x < chevronEnd {
            toggle(node)
        } else {
            model.librarySources.show(source.source)
        }
    }

    /// A source list rings the row whose menu is open, as the Finder's sidebar does: the table's own handling
    /// notes which row was clicked.
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0,
              let view = view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCellView else { return nil }
        if look == .sourceList {
            _ = super.menu(for: event)
        }
        return view.contextMenu()
    }

    // MARK: - Data source

    func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? roots.count
    }

    func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? roots[index]
    }

    func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? SidebarNode)?.children.isEmpty ?? true)
    }

    /// A drop lands on the whole list, wherever it's let go.
    func outlineView(
        _: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem _: Any?, proposedChildIndex _: Int,
    ) -> NSDragOperation {
        guard dropFiles != nil, !droppedFiles(info).isEmpty else { return [] }
        setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }

    func outlineView(_: NSOutlineView, acceptDrop info: any NSDraggingInfo, item _: Any?, childIndex _: Int) -> Bool {
        let files = droppedFiles(info)
        guard let dropFiles, !files.isEmpty else { return false }
        // The import may show a modal alert, which shouldn't hold up the drag's end.
        DispatchQueue.main.async { dropFiles(files) }
        return true
    }

    private func droppedFiles(_ info: any NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true],
        ) as? [URL] ?? []
        return acceptsFiles(urls)
    }

    // MARK: - Library's photos dropped (LIB-23, LIB-26)

    /// What dropping Library's photos on row `row` does, given the operations the drag offers; nil refuses the drop.
    /// The Folders and Collections lists, which take them, say.
    func photoDrop(onRow _: Int, _: DraggedPhotos, operations _: NSDragOperation) -> PhotoDrop? {
        nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let photos = LibraryDrags.photos(in: sender) else {
            return super.draggingEntered(sender)
        }
        return photosDragged(sender, photos)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let photos = LibraryDrags.photos(in: sender) else {
            return super.draggingUpdated(sender)
        }
        return photosDragged(sender, photos)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        guard isDraggingPhotos else { return super.draggingExited(sender) }
        endPhotoDrag()
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isDraggingPhotos || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard isDraggingPhotos else { return super.performDragOperation(sender) }
        let row = photoDropRow
        showPhotoDrop(nil)
        guard let photos = LibraryDrags.photos(in: sender), let row,
              let drop = photoDrop(onRow: row, photos, operations: sender.draggingSourceOperationMask)
        else { return false }
        // Once the drag has ended: a move shows its progress in a sheet, and may end with an alert.
        DispatchQueue.main.async { MainActor.assumeIsolated(drop.perform) }
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        guard isDraggingPhotos else { return super.concludeDragOperation(sender) }
        endPhotoDrag()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        guard isDraggingPhotos else { return super.draggingEnded(sender) }
        endPhotoDrag()
    }

    /// The row under the drag outlined when it takes the photos; a refused drop shows the cursor that says so.
    private func photosDragged(_ sender: any NSDraggingInfo, _ photos: DraggedPhotos) -> NSDragOperation {
        // The other module's column stays in place, transparent, and takes nothing.
        guard isOnScreen else { return [] }
        isDraggingPhotos = true
        let row = row(at: convert(sender.draggingLocation, from: nil))
        let drop = row >= 0 ? photoDrop(onRow: row, photos, operations: sender.draggingSourceOperationMask) : nil
        showPhotoDrop(drop == nil ? nil : row)
        guard let drop else {
            NSCursor.operationNotAllowed.set()
            return []
        }
        return drop.operation
    }

    private func endPhotoDrag() {
        isDraggingPhotos = false
        showPhotoDrop(nil)
    }

    private var isOnScreen: Bool {
        var view: NSView? = self
        while let current = view {
            if current.isHidden || current.alphaValue == 0 {
                return false
            }
            view = current.superview
        }
        return true
    }

    private func showPhotoDrop(_ row: Int?) {
        guard row != photoDropRow else { return }
        if let shown = photoDropRow, shown < numberOfRows {
            (rowView(atRow: shown, makeIfNecessary: false) as? SidebarRowView)?.isDropTarget = false
        }
        photoDropRow = row
        if let row {
            (rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView)?.isDropTarget = true
            LibraryDrags.outlined += 1
        }
    }

    // MARK: - Delegate

    func outlineView(_: NSOutlineView, shouldSelectItem _: Any) -> Bool {
        false
    }

    /// A source list's line saying what a section holds while it's empty wraps, its row as tall as its lines; every
    /// other row is the list's height.
    func outlineView(_: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard look == .sourceList, case let .placeholder(text)? = (item as? SidebarNode)?.kind else { return rowHeight }
        let width = bounds.width - Self.sourceListLeadingInset - Self.sourceListTrailingInset
            - SidebarCellView.Layout.labelPadding
        return max(rowHeight, ceil(SidebarCellView.placeholderHeight(text, width: width)) + 10)
    }

    func outlineView(_: NSOutlineView, viewFor _: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        // Rows are made only as they show, so a folder is listed (for its subfolders, and its count
        // until the library counts it) only once it's on screen, however many siblings it has.
        if case let .folder(folder) = node.kind, !folder.isMissing, model.library.node(for: folder.url) == nil {
            model.library.listTree(folder.url)
        }
        return SidebarCellView(
            node: node, model: model, isExpanded: isItemExpanded(node), look: look, rowSize: effectiveRowSizeStyle,
        )
    }

    func outlineView(_: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = SidebarRowView()
        row.drawsHighlights = look == .panel
        row.isCurrentStep = Self.isHighlighted(item as? SidebarNode)
        return row
    }

    /// The current history step, and the open folder, Recently Trashed or the source shown.
    static func isHighlighted(_ node: SidebarNode?) -> Bool {
        switch node?.kind {
        case let .history(_, _, current, _): current
        case let .folder(folder): folder.isOpen
        case let .recentlyTrashed(trash): trash.isOpen
        case let .source(source): source.isShown
        default: false
        }
    }

    /// `reloadItem` makes a row's cell again but keeps its row view, which draws the highlight,
    /// so a list that reloads rows one at a time sets the highlights afterwards.
    final func refreshHighlights() {
        enumerateAvailableRowViews { rowView, row in
            (rowView as? SidebarRowView)?.isCurrentStep = Self.isHighlighted(item(atRow: row) as? SidebarNode)
        }
        selectHighlighted()
    }

    /// A source list selects the rows it highlights: AppKit draws them as its selection. Clicks never select, so
    /// the selection is only ever the source shown.
    final func selectHighlighted() {
        guard look == .sourceList else { return }
        var rows = IndexSet()
        for row in 0 ..< numberOfRows where Self.isHighlighted(item(atRow: row) as? SidebarNode) {
            rows.insert(row)
        }
        if rows != selectedRowIndexes {
            selectRowIndexes(rows, byExtendingSelection: false)
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        expansionDidChange(notification, expanded: true)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        expansionDidChange(notification, expanded: false)
    }

    private func expansionDidChange(_ notification: Notification, expanded: Bool) {
        guard let node = notification.userInfo?["NSObject"] as? SidebarNode else { return }
        expansionChanged(node, expanded)
        (view(atColumn: 0, row: row(forItem: node), makeIfNecessary: false) as? SidebarCellView)?.isExpanded = expanded
        if !isReloading {
            selectHighlighted()
            invalidateColumnLayout()
        }
    }

    @objc private func rowClicked() {
        guard let node = item(atRow: clickedRow) as? SidebarNode else { return }
        if look == .sourceList,
           isOnDisclosure(convert(window?.currentEvent?.locationInWindow ?? .zero, from: nil), row: clickedRow) {
            return
        }
        switch node.kind {
        case let .recipe(recipe):
            guard model.info != nil else { return }
            model.applyRecipe(recipe)
        case let .snapshot(snapshot):
            model.applySnapshot(snapshot)
        case let .history(_, index, _, _):
            model.goToHistory(index)
        case let .earlierStep(step, session):
            model.restoreHistory(step, from: session)
        case .group, .session, .libraryHealth:
            toggle(node)
        case let .folder(folder):
            if !clickedChevron(of: node) {
                open(folder)
            }
        case .recentlyTrashed:
            model.showRecentlyTrashed()
        default:
            break
        }
    }

    /// The chevron expands a folder, and the rest of its row opens it: false when the click wasn't on the chevron.
    /// A source list's chevron is AppKit's, which takes its own clicks.
    private func clickedChevron(of node: SidebarNode) -> Bool {
        guard look == .panel else { return false }
        let location = convert(window?.currentEvent?.locationInWindow ?? .zero, from: nil)
        let chevronEnd = frameOfCell(atColumn: 0, row: clickedRow).minX + SidebarCellView.Layout.chevronSize.width + 4
        guard isExpandable(node), location.x < chevronEnd else { return false }
        toggle(node)
        return true
    }

    /// Shows the folder in the filmstrip, unless it's missing or has nothing to show.
    func open(_ folder: FolderRow) {
        guard folder.isSelectable else { return }
        model.showFolder(folder.url)
    }

    private func toggle(_ node: SidebarNode) {
        if isItemExpanded(node) {
            collapseItem(node)
        } else {
            expandItem(node)
        }
    }
}
