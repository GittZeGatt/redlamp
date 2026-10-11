import Foundation
import Observation
import RedlampDesign
import RedlampLibrary

/// The Library's stacks (LIB-28), for the grid and the filmstrip: the source's photos with each raw and its
/// JPEG and each stack made by hand shown as one cell with its count until it's opened, and each burst the library
/// finds by itself open, every frame with its cell and the burst marked as one, until it's closed (DEC-64)
/// (`StackedList`), as the library finds them in its index (`LibraryStackFinder`), over the app's own photo
/// IDs (`FolderLibrary.photoIDs`), so the grid's selection is `EditorModel.photoSelection`.
///
/// Stacks are found off the main thread when the photos come or go and when a stack is made or taken apart,
/// one stacking at a time, the stacks open before open after. A stack opens or closes on the main thread in
/// microseconds, with a diff of the cells, in the grid's groups too (`LibraryGroups`). A closed stack's cell
/// selects all of its photos (`EditorModel.coverClosedStacks`), so culling, keywords, drags and moves reach
/// every photo it stands for and nothing out of sight is selected alone.
///
/// How a source's stacks start (`Openness.Start`) is the source's own: as found, unless Open All or Close All
/// Stacks was the last asked for it, as its view keeps it; a source without a view starts as found.
@MainActor
@Observable
@_spi(Harness) public final class LibraryStacks {
    /// What changed in the list's cells, for the views that follow them.
    @_spi(Harness) public enum Change: Equatable {
        /// Stacked afresh: photos came or went, stacks were made or taken apart, or the source shows stacks for
        /// the first time or no longer.
        case restacked
        /// Stacks opened or closed: the cells changed as the diff says.
        case items(PhotoListDiff)
    }

    /// Which stacks are open, as each source's view keeps them (`LibraryViewState`): how its stacks start, and the
    /// stacks that aren't as they'd start, by their top photo's path.
    struct Openness: Codable, Equatable, Sendable {
        /// How a source's stacks start.
        enum Start: String, Codable, Sendable {
            /// As the library finds them: bursts open (DEC-64), pairs and stacks made by hand closed.
            case found
            /// Every one open: Open All Stacks was the last asked for.
            case open
            /// Every one closed: Close All Stacks was the last asked for.
            case closed
        }

        struct Stack: Codable, Hashable, Sendable {
            var path: String
            /// A raw and its JPEG, rather than a burst or a manual stack with the same top photo.
            var pair: Bool
        }

        /// Open All was the last asked for: `start` for a build that doesn't read it.
        var all: Bool
        var others: [Stack]
        /// Nil in a view kept before found bursts started open, whose stacks started closed but after Open All.
        var start: Start?

        init(start: Start, others: [Stack]) {
            all = start == .open
            self.others = others
            self.start = start
        }

        /// How the stacks it keeps started, which `others` aren't as.
        var kept: Start {
            start ?? (all ? .open : .closed)
        }

        /// How the stacks the source gains start from now on: as found in a view kept before they did, but after
        /// Open All.
        var gained: Start {
            start ?? (all ? .open : .found)
        }
    }

    /// The stacks as the menus and the palette follow them, the list itself not being observed. Nothing here changes
    /// as a stack opens or closes: SwiftUI makes the whole menu bar again for each change.
    @_spi(Harness) public struct Outline: Equatable {
        /// Counts the stackings shown.
        @_spi(Harness) public internal(set) var stackings = 0
        /// Whether the list shows a stack, open or closed.
        @_spi(Harness) public internal(set) var hasStacks = false
    }

    @ObservationIgnored private weak var model: EditorModel?
    /// The source's photos with their stacks; nil without the library, while the source has no stack, and until
    /// its stacks are first found.
    @ObservationIgnored @_spi(Harness) public private(set) var list: StackedList?
    @_spi(Harness) public private(set) var outline = Outline()
    /// Counts the stacks opened and closed, for what follows which are open (Remove from Stack, Split Stack, moving in
    /// a stack); the outline doesn't change as they do.
    @_spi(Harness) public private(set) var toggles = 0
    /// How the source's stacks start, and the stacks it gains: as found until Open All or Close All Stacks.
    @ObservationIgnored private(set) var start = Openness.Start.found
    /// The source `start` is of: another source starts as found, unless its view says otherwise.
    @ObservationIgnored private var startSource: PhotoSource?
    /// Whether the stacks a list gains come open: after Open All Stacks, until Close All Stacks.
    var opensNew: Bool {
        start == .open
    }

    /// The source shown and its stacks as its view kept them, until they've been found and opened so.
    @ObservationIgnored private var restoring: (source: PhotoSource, openness: Openness)?
    /// Counts the list's changes, for a grouping made meanwhile to open its stacks as the list has them.
    @ObservationIgnored private(set) var openings = 0
    @ObservationIgnored let finder = LibraryStackFinder()
    /// Each photo's ID in the index, by its ID here, as the stackings found them, while the photos' IDs aren't the
    /// index's (`indexID(of:)`).
    @ObservationIgnored private var indexIDs: [Int64: Int64] = [:]
    @ObservationIgnored private var observers: [UUID: @MainActor (Change) -> Void] = [:]
    @ObservationIgnored private var observation: LibraryObservation?
    @ObservationIgnored private var indexing: LibraryObservation?
    @ObservationIgnored private var selectionTracker: Tracker?
    @ObservationIgnored private var stacking = false
    @ObservationIgnored private var pending = false
    /// What the next stacking forgets first: the stacks found before, and their photos' names.
    @ObservationIgnored private var forgetting = (stacks: false, names: false)
    /// Photos, by their IDs here, whose stacks the next stacking opens: a stack's change left them in an open stack
    /// that the stacks open before wouldn't open again, as the half of one split below the photo split at.
    @ObservationIgnored private var opening = Set<Int64>()
    /// The stacking that follows badges' changes once they're quiet, for a stack changed in a sidecar by another
    /// Mac or app.
    @ObservationIgnored private var quiet: Task<Void, Never>?
    /// How long the last stacking took off the main thread, and how many have been made, for the measurements.
    @ObservationIgnored @_spi(Harness) public private(set) var lastStacking: Duration = .zero
    @ObservationIgnored @_spi(Harness) public private(set) var stackingsMade = 0

    /// Whether no stacking is under way, asked for meanwhile, or waiting for badges' changes to be quiet.
    @_spi(Harness) public var isIdle: Bool {
        !stacking && !pending && quiet == nil
    }

    /// How long badges' changes are quiet before the stacks are found again.
    static let quietPause = Duration.seconds(1)
    /// The stacks a source's view keeps that don't follow Open All, at most; a larger source keeps its first ones.
    static let keptStacks = 2000

    init(model: EditorModel) {
        self.model = model
        observation = model.library.observe { [weak self] diff in self?.libraryChanged(diff) }
        // The library indexed more photos, whose names stacks are found from; and a folder listed from the disk is
        // shown from the library once it's indexed, without a change when nothing differs.
        indexing = model.library.service?.observe { [weak self] in
            self?.restackWhenQuiet(names: true)
        }
        selectionTracker = Tracker { [weak model] in
            guard let model else { return }
            _ = (model.photoSelection, model.selection)
            model.coverClosedStacks()
        }
        if let openness = model.libraryViews.restoredStacks {
            model.libraryViews.restoredStacks = nil
            restore(openness)
        }
        restack()
    }

    /// Calls `handler` after every change, until the returned token is released.
    @_spi(Harness) public func observe(_ handler: @escaping @MainActor (Change) -> Void) -> LibraryObservation {
        let id = UUID()
        observers[id] = handler
        return LibraryObservation { [weak self] in self?.observers.removeValue(forKey: id) }
    }

    // MARK: - Stacking

    /// Finds the source's stacks again, off the main thread, and shows them; `forgetting` the stacks found
    /// before, and their photos' names with `names`, and opening those holding `opening`. Without the library,
    /// or for a source not shown from it, there are none.
    func restack(forgetting: Bool = false, names: Bool = false, opening: [Int64] = []) {
        guard let model else { return }
        self.forgetting.stacks = self.forgetting.stacks || forgetting
        self.forgetting.names = self.forgetting.names || forgetting && names
        self.opening.formUnion(opening)
        let library = model.library
        guard library.isShownFromLibrary, let core = library.service?.core else {
            pending = false
            self.opening = []
            if list != nil {
                show(nil, changed: true)
            }
            return
        }
        guard !stacking else {
            pending = true
            return
        }
        stacking = true
        pending = false
        if startSource != library.photoList.source {
            startSource = library.photoList.source
            start = .found
        }
        let request = Request(
            items: library.showsIndexIDs ? nil : library.items.allRows, ids: library.photoIDs, list: library.photoList,
            previous: list, start: start, opening: self.opening, finder: finder,
            photoIDs: model.libraryPanels.photoIDs, forgetting: self.forgetting,
        )
        self.forgetting = (false, false)
        self.opening = []
        // Detached, so the stacking starts at once rather than once the main thread has drawn what asked for it.
        Task.detached(priority: .userInitiated) { [weak self] in
            let started = ContinuousClock.now
            let result = await Self.stack(request, index: core.index, engine: core.engine)
            await self?.stacked(result, for: request.list.source, since: started)
        }
    }

    private struct Request: Sendable {
        /// The photos, whose URLs find their IDs in the index; nil when their IDs are the index's.
        var items: [LibraryItem]?
        var ids: ContiguousArray<Int64>
        var list: PhotoList
        var previous: StackedList?
        var start: Openness.Start
        var opening: Set<Int64>
        var finder: LibraryStackFinder
        var photoIDs: PanelPhotoIDs
        var forgetting: (stacks: Bool, names: Bool)
    }

    private struct Result: Sendable {
        /// Nil when the list shows no stack.
        var list: StackedList?
        /// Whether its cells or their badges differ from the stacked list it follows; after none, whether it
        /// shows a stack.
        var changed: Bool
        var indexIDs: [Int64: Int64]
        /// How its stacks started.
        var start: Openness.Start
    }

    /// The request's photos with the library's stacks, relabelled with the IDs here, the stacks open in the list
    /// before open in it.
    private nonisolated static func stack(_ request: Request, index: LibraryIndex, engine: QueryEngine) async
        -> Result? {
        let (items, ids, list) = (request.items, request.ids, request.list)
        guard items.map({ $0.count == ids.count }) ?? true else { return nil }
        if request.forgetting.stacks {
            await request.finder.forget(names: request.forgetting.names)
        }
        var byOwn: [Int64: Int64] = [:]
        if let items {
            let photos = ids.indices.map { (list: ids[$0], url: items[$0].url) }
            byOwn = await request.photoIDs.ids(of: photos, in: index)
        }
        guard let found = await request.finder.stacks(in: index, engine: engine) else { return nil }
        let stacks: Stacks
        if items == nil {
            stacks = found.relabelled(above: list.highestID ?? -1) { list.contains($0) ? $0 : nil }
        } else {
            var byIndex: [Int64: Int64] = [:]
            byIndex.reserveCapacity(byOwn.count)
            for (own, indexed) in byOwn {
                byIndex[indexed] = own
            }
            stacks = found.relabelled(above: ids.max() ?? -1) { byIndex[$0] }
        }
        var stacked: StackedList
        var changed: Bool
        let bursts = request.start == .found
        if let previous = request.previous {
            var selection = StackSelection()
            let (updated, diff) = previous.updated(
                list: request.list, stacks: stacks, opensBursts: bursts, selection: &selection,
            )
            (stacked, changed) = (updated, !diff.isEmpty)
        } else {
            stacked = StackedList(request.list, stacks: stacks, opensBursts: bursts)
            let shown = stacked.stacksShown
            changed = shown.open + shown.closed > 0
        }
        if request.start == .open, stacked.stacksShown.closed > 0 {
            stacked.openAll()
            changed = true
        }
        for photo in request.opening {
            guard let outer = stacked.shownStacks(of: photo).first, outer.kind != .pair, !outer.isOpen else { continue }
            _ = stacked.open(outer.first)
            changed = true
        }
        let shown = stacked.stacksShown
        return Result(
            list: shown.open + shown.closed > 0 ? stacked : nil, changed: changed, indexIDs: byOwn,
            start: request.start,
        )
    }

    private func stacked(_ result: Result?, for source: PhotoSource, since started: ContinuousClock.Instant) {
        stacking = false
        lastStacking = ContinuousClock.now - started
        stackingsMade += 1
        if let result, model?.library.photoList.source == source {
            indexIDs.merge(result.indexIDs) { _, new in new }
            if restoring.map({ $0.source != source }) == true {
                restoring = nil
            }
            var made = result.list
            var changed = result.changed
            // Open All or Close All asked for while the stacks were being found, which the request didn't know of.
            if restoring == nil, var stacked = made {
                let shown = stacked.stacksShown
                if start == .open, shown.closed > 0 {
                    stacked.openAll()
                } else if start == .closed, result.start != .closed, shown.open > 0 {
                    stacked.closeAll()
                }
                if stacked.stacksShown != shown {
                    made = stacked
                    changed = true
                }
            }
            show(made, changed: changed || (list == nil) != (made == nil))
            followRestored()
        }
        if pending || model.map({ $0.library.photoList.source != source }) == true {
            restack()
        }
    }

    // MARK: - Each source's

    /// Whether the stack whose top photo is `top`, a raw and its JPEG with `pair`, starts open as `start` says.
    nonisolated static func startsOpen(top: Int64, pair: Bool, in stacks: Stacks, start: Openness.Start) -> Bool {
        switch start {
        case .found: !pair && stacks.kind(ofStackHolding: top) == .burst
        case .open: true
        case .closed: false
        }
    }

    /// Which stacks are open now, for the source's view to keep: how they start, and those that aren't as they'd
    /// start, by their top photo's path.
    var openness: Openness {
        var others: [Openness.Stack] = []
        if let list {
            for stack in list.openness where others.count < Self.keptStacks {
                guard stack.isOpen != Self.startsOpen(top: stack.top, pair: stack.pair, in: list.stacks, start: start),
                      let url = model?.library.url(ofPhoto: stack.top)
                else { continue }
                others.append(Openness.Stack(path: url.path, pair: stack.pair))
            }
        }
        return Openness(start: start, others: others)
    }

    /// The source just listed's stacks open as its view kept them: at once when they've been found, else once they
    /// are. Stacks found since start as they would have.
    func restore(_ openness: Openness) {
        guard let model else { return }
        start = openness.gained
        startSource = model.library.photoList.source
        restoring = (model.library.photoList.source, openness)
        followRestored()
    }

    /// Opens and closes the stacks of the source shown as its view kept them, once they've been found.
    private func followRestored() {
        guard let model, let (source, openness) = restoring, var stacked = list, stacked.list.source == source,
              model.library.photoList.source == source
        else { return }
        restoring = nil
        var kept = (pairs: Set<Int64>(), others: Set<Int64>())
        for stack in openness.others {
            guard let id = model.library.photoID(of: URL(fileURLWithPath: stack.path)) else { continue }
            if stack.pair {
                kept.pairs.insert(id)
            } else {
                kept.others.insert(id)
            }
        }
        var selection = StackSelection()
        let (stacks, start) = (stacked.stacks, openness.kept)
        let diff = stacked.reopen(selection: &selection) { top, pair in
            Self.startsOpen(top: top, pair: pair, in: stacks, start: start)
                != (pair ? kept.pairs : kept.others).contains(top)
        }
        guard !diff.isEmpty else { return }
        list = stacked
        model.coverClosedStacks(anyPhotoSelecting: true)
        changed(.items(diff))
        model.libraryViews.groups?.restacked()
    }

    private func show(_ made: StackedList?, changed: Bool) {
        list = made
        guard changed else { return }
        self.changed(.restacked)
        model?.coverClosedStacks()
        model?.libraryViews.groups?.restacked()
    }

    private func changed(_ change: Change) {
        openings += 1
        var next = outline
        if change == .restacked {
            next.stackings += 1
        } else {
            toggles += 1
        }
        let shown = list?.stacksShown ?? (open: 0, closed: 0)
        next.hasStacks = shown.open + shown.closed > 0
        if next != outline {
            outline = next
        }
        for observer in observers.values {
            observer(change)
        }
    }

    /// Photos that came or went are stacked again at once, with their names read again; badges' changes, once
    /// they've been quiet a moment, for a stack another Mac or app changed in a sidecar.
    private func libraryChanged(_ diff: LibraryDiff) {
        guard !diff.isEmpty, !diff.onlyReads else { return }
        guard !diff.reset, diff.removed.isEmpty, diff.inserted.isEmpty else {
            return restack(forgetting: true, names: true)
        }
        restackWhenQuiet()
    }

    /// Finds the stacks again once changes have been quiet a moment, with `names` their photos' names too.
    private func restackWhenQuiet(names: Bool = false) {
        forgetting.names = forgetting.names || names
        quiet?.cancel()
        quiet = Task { [weak self] in
            try? await Task.sleep(for: Self.quietPause)
            guard !Task.isCancelled else { return }
            self?.quiet = nil
            self?.restack(forgetting: true)
        }
    }

    // MARK: - Opening and closing

    /// Opens the closed stack whose first cell is `cell`: a burst or a stack made by hand, else a raw and its JPEG.
    @_spi(Harness) public func open(_ cell: Int64) {
        guard var stacked = list else { return }
        let diff = stacked.open(cell)
        guard !diff.isEmpty else { return }
        list = stacked
        changed(.items(diff))
        model?.libraryViews.groups?.openStack(cell, as: stacked)
    }

    /// Closes the open stack `cell` is in, a raw and its JPEG before the burst or stack made by hand holding them;
    /// when any of its photos was selected, all of them are, and the first is active when one of them was.
    @_spi(Harness) public func close(_ cell: Int64) {
        guard var stacked = list, let model else { return }
        let diff = stacked.close(cell)
        guard !diff.isEmpty else { return }
        list = stacked
        if let first = stacked.cell(for: cell) {
            model.keepSelected(stacked.photos(of: first), standingFor: first)
        }
        changed(.items(diff))
        model.libraryViews.groups?.closeStack(cell, as: stacked)
    }

    /// Opens every stack; the stacks the source's list gains come open until every one is closed again.
    @_spi(Harness) public func openAll() {
        start = .open
        startSource = model?.library.photoList.source
        guard var stacked = list, stacked.stacksShown.closed > 0 else { return }
        let diff = stacked.openAll()
        list = stacked
        changed(.items(diff))
        model?.libraryViews.groups?.openAllStacks()
    }

    /// Closes every stack, each selected whole when any of its photos was; the stacks the source's list gains come
    /// closed, bursts too, until every one is opened again.
    @_spi(Harness) public func closeAll() {
        start = .closed
        startSource = model?.library.photoList.source
        guard var stacked = list, let model, stacked.stacksShown.open > 0 else { return }
        let diff = stacked.closeAll()
        list = stacked
        model.coverClosedStacks(anyPhotoSelecting: true)
        changed(.items(diff))
        model.libraryViews.groups?.closeAllStacks()
    }

    /// Opens the outermost stack holding `photo` if it's closed, else closes it, as S does: a burst or a stack
    /// made by hand before a raw and its JPEG.
    @_spi(Harness) public func toggle(_ photo: Int64) {
        guard let stacked = list, let cell = stacked.cell(for: photo), let outer = stacked.shownStacks(of: cell).first
        else { return }
        guard outer.isOpen else { return open(outer.first) }
        closeWhole(outer, from: cell)
    }

    /// A click on a cell's badge: opens or closes the stack it's the first cell of, `pair` the raw and its JPEG
    /// shown there rather than the burst or stack made by hand.
    @_spi(Harness) public func toggle(badgeOf cell: Int64, pair: Bool) {
        guard let stacked = list, let shown = stacked.shownStacks(of: cell).first(where: { stack in
            (stack.kind == .pair) == pair && stack.first == cell
        }) else { return }
        guard shown.isOpen else { return open(cell) }
        closeWhole(shown, from: cell)
    }

    /// Closes `stack` from its cell `cell`, which a raw and its JPEG open inside it would close first.
    private func closeWhole(_ stack: (first: Int64, kind: Stack.Kind, isOpen: Bool), from cell: Int64) {
        for _ in 0 ..< 2 {
            close(cell)
            guard let shown = list?.shownStacks(of: cell),
                  shown.contains(where: { $0.first == stack.first && $0.kind == stack.kind && $0.isOpen })
            else { return }
        }
    }

    /// Whether `photo` has a cell of its own, or stands for a closed stack's photos.
    func isOnShow(_ photo: Int64) -> Bool {
        list?.isShown(photo) ?? true
    }

    /// The index's ID of photo `own`, one of the photos shown: its own while the photos' IDs are the index's, else as
    /// the stackings found it. A closed stack's photos outside the source have none.
    func indexID(of own: Int64) -> Int64? {
        guard let library = model?.library else { return nil }
        guard library.showsIndexIDs else { return indexIDs[own] }
        return library.photoList.contains(own) ? own : nil
    }
}

public extension EditorModel {
    /// The Library's stacks, made the first time they're asked for.
    @_spi(Harness) var gridStacks: LibraryStacks {
        if let stacks = libraryViews.stacks {
            return stacks
        }
        let stacks = LibraryStacks(model: self)
        libraryViews.stacks = stacks
        return stacks
    }
}
