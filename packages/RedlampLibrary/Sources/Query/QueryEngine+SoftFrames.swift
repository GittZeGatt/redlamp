import Foundation

/// What the engine keeps for the soft-frame terms and the grid's marks (LIB-42): the index's measurements by photo
/// ID, read once and added to as the measurer records more; the library's stacks, found for a version of the store;
/// and the verdicts judged for each source, setting and mode, until the store, the measurements or the mode change.
struct SoftFrameState: Sendable {
    var mode = SoftFrames.Mode.onePerMoment
    var sharpness: [Int64: PhotoSharpness]?
    /// Changes whenever `sharpness` does.
    var sharpnessVersion = 0
    var loading: Task<[Int64: PhotoSharpness], any Error>?
    /// Measurements added while the index's were being read.
    var added: [Int64: PhotoSharpness] = [:]
    var stacks: (generation: Int, stacks: Stacks)?
    var verdicts: [VerdictKey: SoftFrames] = [:]

    struct VerdictKey: Hashable {
        let generation: Int
        let sharpness: Int
        let mode: SoftFrames.Mode
        let moments: MomentScope
    }

    /// Verdicts kept, at most, before they're dropped.
    static let kept = 8

    mutating func trim() {
        stacks = nil
        verdicts.removeAll()
    }
}

extension QuerySource {
    func photoSharpness(of _: [Int64]?) async throws -> [Int64: PhotoSharpness] {
        [:]
    }

    func softFrameStacks(store _: ColumnStore) async throws -> Stacks {
        Stacks()
    }
}

extension IndexQuerySource {
    func photoSharpness(of ids: [Int64]?) async throws -> [Int64: PhotoSharpness] {
        try await index.read { try $0.photoSharpness(of: ids) }
    }

    func softFrameStacks(store: ColumnStore) async throws -> Stacks {
        try await StackFinder.find(in: index, store: store)
    }
}

public extension QueryEngine {
    /// What the soft-frame check proposes: one pick per moment unless the app has chosen otherwise.
    var proposalMode: SoftFrames.Mode {
        withSoftFrames { _, state in state.mode }
    }

    /// Proposes in `mode` from now on: what the soft-frame terms found is found again.
    func setProposalMode(_ mode: SoftFrames.Mode) {
        let changed = withSoftFrames { _, state -> Bool in
            defer { state.mode = mode }
            return state.mode != mode
        }
        if changed {
            dropSoftFrameResults()
        }
    }

    /// The soft-frame verdicts of `source`'s photos, in moments as `setting` finds them among them, in the engine's
    /// mode: for the grid's marks, worked out once for each version of the store, the measurements and the mode.
    /// Off the caller's thread.
    func softFrames(of source: PhotoSource, setting: MomentSetting = MomentSetting()) async throws -> SoftFrames {
        try await Task.detached(priority: .userInitiated) { [self] in
            if await loadedSnapshot() == nil {
                try await load()
            }
            guard let (store, vocabulary, generation) = snapshot() else { return .empty }
            return try await softFrames(
                MomentScope(source: source, setting: setting), in: store, vocabulary: vocabulary,
                generation: generation,
            )
        }.value
    }

    /// Measurements the measurer recorded, by photo ID: the verdicts, and what the terms found, are worked out again
    /// with them.
    func addSharpness(_ measured: [Int64: PhotoSharpness]) {
        guard !measured.isEmpty else { return }
        withSoftFrames { _, state in
            if state.sharpness != nil {
                state.sharpness?.merge(measured) { $1 }
            } else {
                state.added.merge(measured) { $1 }
            }
            state.sharpnessVersion += 1
        }
        dropSoftFrameResults()
    }

    /// How many photos have a measurement, once they've been read.
    var measuredCount: Int? {
        withSoftFrames { _, state in state.sharpness?.count }
    }

    /// The photos of `source` the soft-frame check measures, in the order to measure them: each burst's frames, then
    /// the frames of its moments (as `setting` finds them) of more than one; a raw and its JPEG once, by the raw.
    /// Those measured already are among them. Off the caller's thread.
    func softFrameCandidates(of source: PhotoSource, setting: MomentSetting = MomentSetting()) async throws -> [Int64] {
        try await Task.detached(priority: .utility) { [self] in
            if await loadedSnapshot() == nil {
                try await load()
            }
            guard let (store, vocabulary, generation) = snapshot() else { return [] }
            let stacks = try await softFrameStacks(in: store, generation: generation)
            let rows = try await rows(of: source, in: store, vocabulary: vocabulary, generation: generation)
            return store.softFrameCandidates(of: rows, stacks: stacks, setting: setting)
        }.value
    }
}

extension QueryEngine {
    /// The verdicts of `scope`'s photos in `store`, judged unless they're kept.
    func softFrames(
        _ scope: MomentScope, in store: ColumnStore, vocabulary: QueryVocabulary, generation: Int,
    ) async throws -> SoftFrames {
        let (sharpness, version) = try await loadedSharpness()
        let (mode, kept) = withSoftFrames { current, state -> (SoftFrames.Mode, SoftFrames?) in
            guard current == generation else { return (state.mode, nil) }
            let key = SoftFrameState.VerdictKey(
                generation: generation, sharpness: version, mode: state.mode, moments: scope,
            )
            return (state.mode, state.verdicts[key])
        }
        if let kept {
            return kept
        }
        let stacks = try await softFrameStacks(in: store, generation: generation)
        let rows = try await rows(of: scope.source, in: store, vocabulary: vocabulary, generation: generation)
        try Task.checkCancellation()
        let found = store.softFrames(of: rows, stacks: stacks, sharpness: sharpness, mode: mode, setting: scope.setting)
        withSoftFrames { current, state in
            guard current == generation, state.mode == mode, state.sharpnessVersion == version else { return }
            if state.verdicts.count >= SoftFrameState.kept {
                state.verdicts.removeAll()
            }
            let key = SoftFrameState.VerdictKey(
                generation: generation, sharpness: version, mode: mode, moments: scope,
            )
            state.verdicts[key] = found
        }
        return found
    }

    /// The measurements by photo ID and their version, read from the index the first time they're asked for.
    private func loadedSharpness() async throws -> ([Int64: PhotoSharpness], Int) {
        enum Found {
            case known([Int64: PhotoSharpness], Int)
            case loading(Task<[Int64: PhotoSharpness], any Error>)
        }
        let source = source
        let found = withSoftFrames { _, state -> Found in
            if let sharpness = state.sharpness {
                return .known(sharpness, state.sharpnessVersion)
            }
            if let loading = state.loading {
                return .loading(loading)
            }
            let task = Task { try await source.photoSharpness(of: nil) }
            state.loading = task
            return .loading(task)
        }
        let loading: Task<[Int64: PhotoSharpness], any Error>
        switch found {
        case let .known(sharpness, version): return (sharpness, version)
        case let .loading(task): loading = task
        }
        let read = try await loading.value
        return withSoftFrames { _, state in
            if state.sharpness == nil {
                var sharpness = read
                sharpness.merge(state.added) { $1 }
                state.sharpness = sharpness
                state.added = [:]
                state.loading = nil
                state.sharpnessVersion += 1
            }
            return (state.sharpness ?? [:], state.sharpnessVersion)
        }
    }

    /// The library's stacks for `store`, found once for each version of it.
    func softFrameStacks(in store: ColumnStore, generation: Int) async throws -> Stacks {
        if let kept = withSoftFrames({ _, state in
            state.stacks.flatMap { $0.generation == generation ? $0.stacks : nil } }) {
            return kept
        }
        let found = try await source.softFrameStacks(store: store)
        withSoftFrames { current, state in
            if current == generation {
                state.stacks = (generation, found)
            }
        }
        return found
    }
}
