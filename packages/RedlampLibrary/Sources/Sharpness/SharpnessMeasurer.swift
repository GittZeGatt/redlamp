import CoreGraphics
import Foundation
import RedlampDocument
import Synchronization

/// Measures photos for soft frames in the background (LIB-42): the photos it's asked to, newest asks first, each once
/// a measure, as the index has no measurement for its content key. Each photo's file is read and its preview drawn on
/// the scheduler's background lane, which waits while anything on screen does and pauses in Low Power Mode or when
/// the Mac is hot, and nothing is measured while `mayRun` says no (the app's: while the index is being updated, so the
/// indexer keeps its budgets). Measurements are written to the index and handed to the engine in batches, and
/// `measured` hears of each batch.
public final class SharpnessMeasurer: Sendable {
    private let index: LibraryIndex
    private let engine: QueryEngine
    private let scheduler: WorkScheduler
    private let mayRun: @Sendable () -> Bool
    private let measured: @Sendable ([Int64]) -> Void
    private let state = Mutex(State())

    /// Photos written to the index together.
    static let batch = 8
    /// Photos measured at once: two, so one's file is read while the other's preview is drawn.
    static let width = 2
    /// How long it waits before asking `mayRun` again.
    static let pause = Duration.seconds(1)

    private struct State {
        /// Photos waiting, the next to measure first.
        var waiting: [Int64] = []
        /// Photos waiting or measured since the measurer was made, which aren't asked for again.
        var asked: Set<Int64> = []
        var running: Task<Void, Never>?
        var stopped = false
        var count = 0
    }

    public init(
        index: LibraryIndex, engine: QueryEngine, scheduler: WorkScheduler,
        mayRun: @escaping @Sendable () -> Bool = { true }, measured: @escaping @Sendable ([Int64]) -> Void = { _ in },
    ) {
        self.index = index
        self.engine = engine
        self.scheduler = scheduler
        self.mayRun = mayRun
        self.measured = measured
    }

    /// Measures those of `photos` (the index's IDs) not asked for before, in their order, ahead of any still waiting.
    public func measure(_ photos: [Int64]) {
        state.withLock { state in
            guard !state.stopped else { return }
            let new = photos.filter { state.asked.insert($0).inserted }
            state.waiting.insert(contentsOf: new, at: 0)
            guard state.running == nil, !state.waiting.isEmpty else { return }
            state.running = Task.detached(priority: .utility) { [self] in await run() }
        }
    }

    /// How many photos it has measured.
    public var count: Int {
        state.withLock { $0.count }
    }

    /// Whether photos are waiting or being measured.
    public var isBusy: Bool {
        state.withLock { $0.running != nil }
    }

    /// Stops: what's waiting is dropped, and nothing is measured after the photos being measured now.
    public func stop() {
        let running = state.withLock { state in
            state.stopped = true
            state.waiting = []
            return state.running
        }
        running?.cancel()
    }

    /// Returns once nothing waits, for the tests.
    public func finish() async {
        await state.withLock { $0.running }?.value
    }

    private func run() async {
        while !Task.isCancelled {
            let next = state.withLock { state -> [Int64] in
                let next = Array(state.waiting.prefix(Self.batch))
                state.waiting.removeFirst(next.count)
                if next.isEmpty {
                    state.running = nil
                }
                return next
            }
            guard !next.isEmpty else { return }
            while !mayRun() {
                try? await Task.sleep(for: Self.pause)
                if Task.isCancelled {
                    return
                }
            }
            await measureBatch(next)
        }
        state.withLock { $0.running = nil }
    }

    private func measureBatch(_ photos: [Int64]) async {
        guard let candidates = try? await index.read({ try $0.sharpnessCandidates(photos) }), !candidates.isEmpty
        else { return }
        let scheduler = scheduler
        var results: [(SharpnessCandidate, PhotoSharpness)] = []
        await withTaskGroup(of: (SharpnessCandidate, PhotoSharpness)?.self) { group in
            var next = candidates.makeIterator()
            func add() {
                guard let candidate = next.next() else { return }
                group.addTask {
                    let size = candidate.width.flatMap { width in
                        candidate.height.map { CGSize(width: width, height: $0) }
                    }
                    let found = try? await SharpnessReader.measure(candidate.url, imageSize: size, scheduler: scheduler)
                    return found.map { (candidate, $0) }
                }
            }
            for _ in 0 ..< Self.width {
                add()
            }
            while let result = await group.next() {
                if let result {
                    results.append(result)
                }
                add()
            }
        }
        guard !results.isEmpty, !Task.isCancelled else { return }
        let rows = results.map { ($0.0.contentKey, $0.1) }
        let written: Bool = await (try? index.write { writer in try writer.setPhotoSharpness(rows) }) != nil
        guard written else { return }
        engine.addSharpness(Dictionary(results.map { ($0.0.photo, $0.1) }) { $1 })
        state.withLock { $0.count += results.count }
        measured(results.map(\.0.photo))
    }
}
