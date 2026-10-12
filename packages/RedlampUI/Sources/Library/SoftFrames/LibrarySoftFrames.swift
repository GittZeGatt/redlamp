import Foundation
import Observation
import RedlampDocument
import RedlampLibrary
import Synchronization

/// The soft-frame check in the Library (LIB-42): what it proposes for the photos shown, drawn apart in the grid until
/// they're accepted (`GridBadges.proposedPick`, `.proposedReject`, `.softness`), in the mode chosen in the filter bar,
/// and the measurer that reads the shown photos' bursts and moments in the background. Proposals start hidden: the
/// threshold is to be tuned on shoots the owner has culled (DEC-61). While they're hidden nothing is measured, unless
/// the filter has a soft-frame term, which finds the photos measured so far.
@MainActor
@Observable
public final class LibrarySoftFrames {
    /// Whether the grid draws the proposals.
    public internal(set) var shows: Bool
    /// What's proposed.
    public internal(set) var mode: SoftFrames.Mode
    /// The verdicts of the photos shown, by index ID.
    @ObservationIgnored public private(set) var verdicts = SoftFrames.empty
    /// The index's IDs of the photos shown, by their URLs, while their IDs in the list aren't the index's: a folder
    /// listed from the disk before the library took it over.
    @ObservationIgnored private var shownIDs: [URL: Int64] = [:]

    @ObservationIgnored private weak var model: EditorModel?
    /// Where the mode and whether proposals are shown are kept across launches; nil keeps them in memory.
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var listObservation: LibraryObservation?
    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    /// The verdicts asked for again once the measurer's batches have gathered (`measuredSettle`).
    @ObservationIgnored private var measuredRefresh: Task<Void, Never>?
    @ObservationIgnored private var measurer: (engine: ObjectIdentifier, measurer: SharpnessMeasurer)?
    /// The source and setting the measurer was last given the photos of.
    @ObservationIgnored private var measuring: (source: PhotoSource, setting: MomentSetting)?
    /// How many times the verdicts have been asked for, and the grid told they changed, for the tests.
    @ObservationIgnored private(set) var refreshes = 0
    @ObservationIgnored private(set) var notified = 0

    static let showsKey = "LibraryShowsProposals"
    static let modeKey = "LibraryProposalMode"

    /// How long changes to the list are gathered before the verdicts are asked for again.
    static let settle = Duration.milliseconds(120)
    /// How long the measurer's batches are gathered before the verdicts are asked for again: a batch comes every
    /// fraction of a second, and judging a large source takes a few hundred milliseconds (276 ms for a million
    /// photos), which would otherwise run back to back for as long as the measurer does.
    static let measuredSettle = Duration.seconds(2)

    init(model: EditorModel, defaults: UserDefaults?) {
        self.model = model
        self.defaults = defaults
        shows = defaults?.bool(forKey: Self.showsKey) ?? false
        mode = defaults?.string(forKey: Self.modeKey).flatMap(SoftFrames.Mode.init(rawValue:)) ?? .onePerMoment
        listObservation = model.library.observe { [weak self] _ in self?.refresh() }
    }

    /// The grid's mark for the photo listed as `id` at `url`, while proposals are shown.
    func mark(of id: Int64?, url: URL) -> SoftFrames.Entry? {
        guard shows, let entry = entry(listed: id, url: url), entry.verdict == .proposed || entry.verdict == .soft
        else { return nil }
        return entry
    }

    /// The verdict of the photo listed as `id` at `url`, through its index ID.
    func entry(listed id: Int64?, url: URL) -> SoftFrames.Entry? {
        let indexID = model?.library.showsIndexIDs == true ? id : shownIDs[url]
        return indexID.flatMap(verdicts.entry(of:))
    }

    /// The photos listed that something is proposed for, by their IDs in the list and in its order, with the flag
    /// accepting it gives: a pick for a frame proposed, a reject for a soft one. Found from the verdicts, so a large
    /// source's photos whose rows aren't read are among them.
    func proposals(where included: (Int64) -> Bool = { _ in true }) -> [(photo: Int64, flag: PhotoFlag)] {
        guard let library = model?.library else { return [] }
        let list = library.photoList
        var found: [(place: Int, photo: Int64, flag: PhotoFlag)] = []
        func add(_ listed: Int64?, _ verdict: SoftFrames.Verdict) {
            guard let listed, let place = list.index(of: listed), included(listed) else { return }
            switch verdict {
            case .proposed: found.append((place, listed, .pick))
            case .soft: found.append((place, listed, .reject))
            case .none, .changed: break
            }
        }
        if library.showsIndexIDs {
            for verdict in [SoftFrames.Verdict.proposed, .soft] {
                for photo in verdicts.photos(verdict) {
                    add(photo, verdict)
                }
            }
        } else {
            for (url, photo) in shownIDs {
                add(library.photoID(of: url), verdicts.verdict(of: photo))
            }
        }
        found.sort { $0.place < $1.place }
        return found.map { ($0.photo, $0.flag) }
    }

    /// Calls `handler` whenever the verdicts shown change.
    func observe(_ handler: @escaping @MainActor () -> Void) -> LibraryObservation {
        let id = UUID()
        observers[id] = handler
        return LibraryObservation { [weak self] in self?.observers.removeValue(forKey: id) }
    }

    func setShows(_ shows: Bool) {
        guard shows != self.shows else { return }
        self.shows = shows
        defaults?.set(shows, forKey: Self.showsKey)
        notify()
        refresh()
    }

    func setMode(_ mode: SoftFrames.Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        defaults?.set(mode.rawValue, forKey: Self.modeKey)
        model?.library.service?.engine?.setProposalMode(mode)
        refresh()
    }

    /// Asks for the shown photos' verdicts again, once the list has been still for `settle`, and has the measurer
    /// read those it hasn't.
    func refresh() {
        refreshes += 1
        guard let model, let service = model.library.service, let engine = service.engine,
              let index = service.core?.index, shows || model.libraryFilters?.filter.query?.findsSoftFrames == true
        else {
            refreshing?.cancel()
            if !verdicts.isEmpty {
                verdicts = .empty
                shownIDs = [:]
                notify()
            }
            return
        }
        engine.setProposalMode(mode)
        let source = model.library.photoList.source
        let setting = model.libraryFilters?.moments ?? MomentSetting()
        let measurer = measurer(engine: engine, index: index, service: service)
        let asked = measuring.map { $0.source == source && $0.setting == setting } ?? false
        let unindexed = model.library.showsIndexIDs ? [] : model.items.map(\.url)
        // A folder listed from the disk finds its photos' IDs in the index, a moment before the query engine has them.
        let live = unindexed.isEmpty ? nil : service.core?.live
        refreshing?.cancel()
        refreshing = Task { [weak self] in
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled else { return }
            await live?.settle()
            guard !Task.isCancelled,
                  let found = try? await engine.softFrames(of: source, setting: setting) else { return }
            let ids = unindexed.isEmpty ? [:] : await LibraryService.indexIDs(of: unindexed, in: index)
            guard let self, !Task.isCancelled, self.model?.library.photoList.source == source else { return }
            if found != verdicts || ids != shownIDs {
                verdicts = found
                shownIDs = ids
                notify()
            }
            if !asked, let candidates = try? await engine.softFrameCandidates(of: source, setting: setting) {
                measurer.measure(candidates)
                measuring = (source, setting)
            }
        }
    }

    /// The library's measurer, made once for its engine: held back while the index is being updated, so the
    /// indexer keeps its budgets, and the verdicts asked for again as it records more.
    private func measurer(engine: QueryEngine, index: LibraryIndex, service: LibraryService) -> SharpnessMeasurer {
        if let measurer, measurer.engine == ObjectIdentifier(engine) {
            return measurer.measurer
        }
        measurer?.measurer.stop()
        let updating = UpdatingIndex()
        updating.follow(service)
        let made = SharpnessMeasurer(
            index: index, engine: engine, scheduler: model?.library.scheduler ?? .shared,
            mayRun: { !updating.isUpdating }, measured: { [weak self] _ in
                Task { @MainActor in self?.measuredBatch() }
            },
        )
        measurer = (ObjectIdentifier(engine), made)
        return made
    }

    /// Asks for the verdicts again once the batches the measurer records have gathered for `measuredSettle`.
    private func measuredBatch() {
        guard measuredRefresh == nil else { return }
        measuredRefresh = Task { [weak self] in
            try? await Task.sleep(for: Self.measuredSettle)
            self?.measuredRefresh = nil
            self?.refresh()
        }
    }

    /// How many photos the measurer has measured, for the regression suite.
    @_spi(Harness) public var measuredCount: Int {
        measurer?.measurer.count ?? 0
    }

    /// The verdict of the photo shown at `url`, for the regression suite.
    @_spi(Harness) public func verdict(ofShown url: URL) -> SoftFrames.Verdict {
        entry(listed: model?.library.photoID(of: url), url: url)?.verdict ?? .none
    }

    private func notify() {
        notified += 1
        for handler in observers.values {
            handler()
        }
    }
}

/// Whether the library's index is being updated, read off the main thread by the measurer.
private final class UpdatingIndex: Sendable {
    private let updating = Mutex(false)

    var isUpdating: Bool {
        updating.withLock { $0 }
    }

    @MainActor func follow(_ service: LibraryService) {
        withObservationTracking {
            let now = service.isUpdatingIndex
            updating.withLock { $0 = now }
        } onChange: { [weak self, weak service] in
            Task { @MainActor in
                guard let self, let service else { return }
                self.follow(service)
            }
        }
    }
}
