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

    @ObservationIgnored private weak var model: EditorModel?
    /// Where the mode and whether proposals are shown are kept across launches; nil keeps them in memory.
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var listObservation: LibraryObservation?
    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var measurer: (engine: ObjectIdentifier, measurer: SharpnessMeasurer)?
    /// The source and setting the measurer was last given the photos of.
    @ObservationIgnored private var measuring: (source: PhotoSource, setting: MomentSetting)?

    static let showsKey = "LibraryShowsProposals"
    static let modeKey = "LibraryProposalMode"

    /// How long changes to the list are gathered before the verdicts are asked for again.
    static let settle = Duration.milliseconds(120)

    init(model: EditorModel, defaults: UserDefaults?) {
        self.model = model
        self.defaults = defaults
        shows = defaults?.bool(forKey: Self.showsKey) ?? false
        mode = defaults?.string(forKey: Self.modeKey).flatMap(SoftFrames.Mode.init(rawValue:)) ?? .onePerMoment
        listObservation = model.library.observe { [weak self] _ in self?.refresh() }
    }

    /// The grid's mark for the photo with index ID `id`, while proposals are shown.
    func mark(of id: Int64?) -> SoftFrames.Entry? {
        guard shows, let id, let entry = verdicts.entry(of: id), entry.verdict == .proposed || entry.verdict == .soft
        else { return nil }
        return entry
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
        guard let model, let service = model.library.service, let engine = service.engine,
              let index = service.core?.index, model.library.showsIndexIDs,
              shows || model.libraryFilters?.filter.query?.findsSoftFrames == true
        else {
            refreshing?.cancel()
            if !verdicts.isEmpty {
                verdicts = .empty
                notify()
            }
            return
        }
        engine.setProposalMode(mode)
        let source = model.library.photoList.source
        let setting = model.libraryFilters?.moments ?? MomentSetting()
        let measurer = measurer(engine: engine, index: index, service: service)
        let asked = measuring.map { $0.source == source && $0.setting == setting } ?? false
        measuring = (source, setting)
        refreshing?.cancel()
        refreshing = Task { [weak self] in
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled,
                  let found = try? await engine.softFrames(of: source, setting: setting) else { return }
            guard let self, !Task.isCancelled, self.model?.library.photoList.source == source else { return }
            if found != verdicts {
                verdicts = found
                notify()
            }
            if !asked, let candidates = try? await engine.softFrameCandidates(of: source, setting: setting) {
                measurer.measure(candidates)
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
                Task { @MainActor in self?.refresh() }
            },
        )
        measurer = (ObjectIdentifier(engine), made)
        return made
    }

    /// How many photos the measurer has measured, for the regression suite.
    @_spi(Harness) public var measuredCount: Int {
        measurer?.measurer.count ?? 0
    }

    private func notify() {
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
