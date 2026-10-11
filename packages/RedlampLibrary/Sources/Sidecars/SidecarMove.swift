import Foundation
import RedlampDocument
import Synchronization

/// Moving a root's sidecars from one place to the other: what would move, and the photos with a copy in each place,
/// which the move settles.
public struct SidecarMovePlan: Sendable, Hashable, Codable {
    /// A sidecar, where it is and where it goes.
    public struct Item: Sendable, Hashable, Codable {
        /// The photo's path below the root.
        public var photo: String
        public var source: URL
        public var target: URL
    }

    /// A photo whose sidecar is in both places, the two copies holding different bytes (DEC-63): the move keeps the
    /// copy Redlamp reads, the one saved last, where the root keeps its sidecars from then on, and sets the other
    /// aside. Two copies the same are one item: the move removes the copy where it's leaving.
    public struct Conflict: Sendable, Hashable, Codable {
        public var photo: String
        public var beside: URL
        public var onThisMac: URL
        /// Where the copy saved last is, as `SidecarLocator.readURL(for:)` finds it: the one the move keeps.
        public var kept: RootRecord.Sidecars
    }

    public var root: Int64
    public var rootPath: String
    public var destination: RootRecord.Sidecars
    public var items: [Item]
    /// Settled as the move runs, their copies set aside before any item moves.
    public var conflicts: [Conflict]
    /// The folder the copies the move sets aside go in, one of its own in `LibraryPaths.setAsideEdits`, made as the
    /// first goes in; nil for a move with no conflicts.
    public var setAside: URL?

    public init(
        root: Int64, rootPath: String, destination: RootRecord.Sidecars, items: [Item], conflicts: [Conflict],
        setAside: URL? = nil,
    ) {
        self.root = root
        self.rootPath = rootPath
        self.destination = destination
        self.items = items
        self.conflicts = conflicts
        self.setAside = setAside
    }
}

/// What a move did.
public struct SidecarMoveOutcome: Sendable, Hashable {
    public var moved = 0
    /// Sidecars gone from where they were before they could be moved.
    public var gone = 0
    /// Sidecars that turned up in both places while the move ran, left as they are for the next move to settle.
    public var conflicts: [String] = []
    /// Sidecars that couldn't be moved, by photo, and why; they stay where they were. A photo whose copy couldn't be
    /// set aside keeps both copies where they were.
    public var failed: [String: String] = [:]
    /// Photos with a copy in each place that the move settled (DEC-63): the copy saved last kept where the root keeps
    /// its sidecars, the other set aside in `setAside`.
    public var settled: [String] = []
    /// The folder holding the copies the move set aside; nil when it set none aside.
    public var setAside: URL?
    /// Cancel stopped the move: what putting back every sidecar in the place they were going did.
    public var putBack: SidecarPutBack?

    public init() {}
}

/// What putting back a move Cancel stopped did (`SidecarMoveOutcome.putBack`).
public struct SidecarPutBack: Sendable, Hashable {
    public var moved = 0
    /// Sidecars that couldn't be put back, by photo, and why; they stay where the move took them.
    public var failed: [String: String] = [:]

    public init(moved: Int = 0, failed: [String: String] = [:]) {
        self.moved = moved
        self.failed = failed
    }
}

/// A move of a root's sidecars as its journal keeps it (`LibrarySidecars.moveJournal`), from before the first sidecar
/// moves until the move is over, so a launch after a quit finishes it (`resumeMove`).
public struct SidecarMoveJournal: Sendable, Hashable, Codable {
    /// What moves where: the sidecars the move set out with or, once Cancel has turned it round, those going back.
    public var plan: SidecarMovePlan
    /// Cancel turned the move round: `plan` takes back every sidecar in the place they were going.
    public var puttingBack = false

    public init(plan: SidecarMovePlan, puttingBack: Bool = false) {
        self.plan = plan
        self.puttingBack = puttingBack
    }
}

/// Cancel, from anywhere, for a move running elsewhere (`LibrarySidecars.move`).
public final class SidecarMoveControl: Sendable {
    private let cancelled = Atomic(false)

    public init() {}

    public var isCancelled: Bool {
        cancelled.load(ordering: .acquiring)
    }

    public func cancel() {
        cancelled.store(true, ordering: .releasing)
    }
}

extension RootRecord.Sidecars: Codable {}

public extension LibrarySidecars {
    /// The journal of a move in progress, until LIB-26's file operations journal holds it.
    var moveJournal: URL {
        paths.root.appending(path: "Sidecar Move.json")
    }

    /// Sidecars moved at a time: Cancel waits for one part at most.
    static let movePart = 256

    /// What moving `root`'s sidecars to `destination` would do: every `.redlamp` sidecar in the
    /// other place, and the photos whose sidecar is in both, with the copy saved last in either. Other apps' `.xmp`
    /// never move.
    func planMove(ofRoot root: Int64, to destination: RootRecord.Sidecars) async throws -> SidecarMovePlan {
        let (record, locatorRoot) = try await knownRoot(root)
        return try await planMove(of: record, locatorRoot, to: destination)
    }

    /// Moves the plan's sidecars, `movePart` at a time, after recording the whole move in its journal and setting the
    /// root to keep them at the destination: each is copied beside where it goes, checked byte for byte, put in place
    /// without replacing anything, and only then removed where it was.
    ///
    /// The plan's conflicts are settled first (DEC-63): of each photo's two copies, the one not saved last is moved
    /// into the plan's `setAside` folder as a sidecar is moved, and then the one kept moves to the destination if it
    /// isn't there. A photo whose copy can't be set aside keeps both where they were.
    ///
    /// `control`, or cancelling the calling task, stops the move after the part under way and turns it round: the
    /// journal says so before anything goes back, the root keeps its sidecars where it did, and every sidecar in the
    /// place they were going goes back (`SidecarMoveOutcome.putBack`), which can't be stopped; copies set aside stay
    /// set aside. A move that moves nothing, every sidecar failing, sets the placement back too. `placed` hears each
    /// change of the root's placement, before the sidecars move. A move a quit interrupted is finished by
    /// `resumeMove`.
    func move(
        _ plan: SidecarMovePlan, control: SidecarMoveControl? = nil, placed: (@Sendable () async -> Void)? = nil,
        progress: (@Sendable (FileProgress) -> Void)? = nil,
    ) async throws -> SidecarMoveOutcome {
        try await move(plan, part: Self.movePart, control: control, placed: placed, progress: progress)
    }

    /// Finishes the move in the journal, if there's one, as `move` would: what moved stays moved, and the rest moves,
    /// or goes back when Cancel had turned the move round. Nil when there's none. The root is found by its path: an
    /// index made again since the move began gives it another ID. A root the index no longer has ends the move.
    func resumeMove(
        control: SidecarMoveControl? = nil, placed: (@Sendable () async -> Void)? = nil,
        progress: (@Sendable (FileProgress) -> Void)? = nil,
    ) async throws -> SidecarMoveOutcome? {
        guard var journal = try await unfinishedMove() else { return nil }
        let path = journal.plan.rootPath
        journal.plan.root = try await index.read { try $0.root(path: path)?.id } ?? journal.plan.root
        let root: (RootRecord, SidecarLocator.Root)
        do {
            root = try await knownRoot(journal.plan.root)
        } catch let LibrarySidecarsError.noSuchRoot(id) {
            try await removeJournal()
            throw LibrarySidecarsError.noSuchRoot(id)
        }
        return try await run(
            journal, root: root, part: Self.movePart, control: control, placed: placed, progress: progress,
        )
    }

    /// The move the journal holds, which a quit interrupted; nil when there's none. A journal an earlier build wrote
    /// holds a part of a move, as its plan.
    func unfinishedMove() async throws -> SidecarMoveJournal? {
        let url = moveJournal
        return try await LibraryIndex.offCaller { () -> SidecarMoveJournal? in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let data = try Data(contentsOf: url)
            if let journal = try? JSONDecoder().decode(SidecarMoveJournal.self, from: data) {
                return journal
            }
            return try SidecarMoveJournal(plan: JSONDecoder().decode(SidecarMovePlan.self, from: data))
        }
    }

    // MARK: - Writing in a place

    /// Whether Redlamp can write in a folder, and why not when it can't.
    enum WriteAccess: Sendable, Hashable {
        case writable
        /// The folder isn't there: its disk may not be connected.
        case missing
        /// On a volume that's read-only.
        case readOnly
        /// Its permissions don't let Redlamp write in it.
        case notPermitted
        /// On a network volume whose share refused a file made there.
        case refused
    }

    /// Whether Redlamp can write in `folder`, and if not, why. A local volume says so without anything being written;
    /// with `probing`, on a network volume, whose share may refuse writes its permissions allow, a hidden file is made
    /// there and removed. That file is named as an interrupted save's leftover, so a share that lets it be made but not
    /// removed has it removed with them.
    static func writeAccess(in folder: URL, probing: Bool = true) -> WriteAccess {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .volumeIsReadOnlyKey, .volumeIsLocalKey]
        guard let values = try? URL(fileURLWithPath: folder.path).resourceValues(forKeys: keys),
              values.isDirectory == true
        else { return .missing }
        if values.volumeIsReadOnly == true {
            return .readOnly
        }
        if access(folder.path, W_OK) != 0 {
            return .notPermitted
        }
        guard probing, values.volumeIsLocal != true else { return .writable }
        let probe = folder.appending(path: ".redlamp-probe.redlamp.\(UUID().uuidString)").path
        let descriptor = open(probe, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return errno == ENOENT ? .missing : .refused }
        var byte: UInt8 = 0
        let wrote = Darwin.write(descriptor, &byte, 1) == 1
        let closed = close(descriptor) == 0
        let removed = unlink(probe) == 0
        return wrote && closed && removed ? .writable : .refused
    }
}

extension LibrarySidecars {
    /// `move`, `part` sidecars at a time.
    func move(
        _ plan: SidecarMovePlan, part: Int, control: SidecarMoveControl? = nil,
        placed: (@Sendable () async -> Void)? = nil, progress: (@Sendable (FileProgress) -> Void)? = nil,
    ) async throws -> SidecarMoveOutcome {
        let root = try await knownRoot(plan.root)
        var plan = plan
        if !plan.conflicts.isEmpty, plan.setAside == nil {
            plan.setAside = paths.setAsideFolder(forRootAt: plan.rootPath)
        }
        let journal = SidecarMoveJournal(plan: plan)
        try await write(journal)
        return try await run(journal, root: root, part: part, control: control, placed: placed, progress: progress)
    }

    /// `planMove` for a root the caller has found, reading the disk but not the index.
    func planMove(
        of record: RootRecord, _ locatorRoot: SidecarLocator.Root, to destination: RootRecord.Sidecars,
    ) async throws -> SidecarMovePlan {
        let rootURL = URL(fileURLWithPath: record.path, isDirectory: true)
        let locator = SidecarLocator(folder: paths.sidecars, roots: [locatorRoot])
        let beside = try await Self.besideSidecars(below: rootURL).sidecars
        let mac = try await Self.macSidecars(of: locatorRoot, in: paths.sidecars)
        var items: [SidecarMovePlan.Item] = []
        var conflicts: [SidecarMovePlan.Conflict] = []
        for photo in (destination == .onThisMac ? beside : mac).sorted() {
            let image = rootURL.appending(path: photo)
            guard let onThisMac = locator.onThisMac(image) else { continue }
            let besidePhoto = SidecarLocator.besidePhoto(image)
            if beside.contains(photo), mac.contains(photo), !SidecarMover.same(besidePhoto, onThisMac) {
                let kept: RootRecord.Sidecars = locator.readURL(for: image).path == onThisMac.path
                    ? .onThisMac : .besidePhotos
                conflicts.append(SidecarMovePlan.Conflict(
                    photo: photo, beside: besidePhoto, onThisMac: onThisMac, kept: kept,
                ))
            } else {
                let (source, target) = destination == .onThisMac ? (besidePhoto, onThisMac) : (onThisMac, besidePhoto)
                items.append(SidecarMovePlan.Item(photo: photo, source: source, target: target))
            }
        }
        return SidecarMovePlan(
            root: record.id, rootPath: record.path, destination: destination, items: items, conflicts: conflicts,
            setAside: conflicts.isEmpty ? nil : paths.setAsideFolder(forRootAt: record.path),
        )
    }

    /// Runs the move `journal` holds for `root`, turning it round if it's stopped; removes the journal once it's over.
    /// Nothing here reads the index, which a cancelled task couldn't, and its writes run whatever happens to the task.
    private func run(
        _ journal: SidecarMoveJournal, root: (record: RootRecord, locator: SidecarLocator.Root), part: Int,
        control: SidecarMoveControl?, placed: (@Sendable () async -> Void)?,
        progress: (@Sendable (FileProgress) -> Void)?,
    ) async throws -> SidecarMoveOutcome {
        let control = control ?? SidecarMoveControl()
        let destination = journal.plan.destination
        let source: RootRecord.Sidecars = destination == .onThisMac ? .besidePhotos : .onThisMac
        return try await withTaskCancellationHandler {
            try await setPlacement(destination, of: root.record)
            await placed?()
            var outcome = SidecarMoveOutcome()
            if journal.puttingBack {
                let back = try await moveInParts(
                    journal.plan.items.map { Step($0) },
                    part: part,
                    control: nil,
                    puttingBack: true,
                    progress: progress,
                )
                outcome.putBack = SidecarPutBack(moved: back.moved, failed: back.failed)
            } else {
                outcome = try await settleAndMove(journal.plan, part: part, control: control, progress: progress)
                if control.isCancelled {
                    var back = try await planMove(of: root.record, root.locator, to: source)
                    back.conflicts = []
                    back.setAside = nil
                    try await write(SidecarMoveJournal(plan: back, puttingBack: true))
                    try await setPlacement(source, of: root.record)
                    await placed?()
                    let returned = try await moveInParts(
                        back.items.map { Step($0) },
                        part: part,
                        control: nil,
                        puttingBack: true,
                        progress: progress,
                    )
                    outcome.putBack = SidecarPutBack(moved: returned.moved, failed: returned.failed)
                } else if outcome.moved == 0, outcome.settled.isEmpty, !outcome.failed.isEmpty {
                    try await setPlacement(source, of: root.record)
                    await placed?()
                }
            }
            try await removeJournal()
            outcome.conflicts.sort()
            outcome.settled.sort()
            return outcome
        } onCancel: {
            control.cancel()
        }
    }

    /// A file a move moves: a sidecar to its place, or a copy to the folder it's set aside in.
    struct Step: Sendable {
        var item: SidecarMovePlan.Item
        var settingAside = false
        /// Its photo is done once it is: a photo whose kept copy moves after its other copy is set aside is done
        /// with the second.
        var counts = true

        init(_ item: SidecarMovePlan.Item, settingAside: Bool = false, counts: Bool = true) {
            self.item = item
            self.settingAside = settingAside
            self.counts = counts
        }
    }

    /// The plan's copies set aside, then its sidecars moved with the copies kept where the move is leaving, all
    /// `part` at a time until `control` stops it between two parts. The progress counts photos.
    private func settleAndMove(
        _ plan: SidecarMovePlan, part: Int, control: SidecarMoveControl?, progress: (@Sendable (FileProgress) -> Void)?,
    ) async throws -> SidecarMoveOutcome {
        let destination = plan.destination
        var settling: [Step] = []
        var keeping: [Step] = []
        if let folder = plan.setAside {
            for conflict in plan.conflicts {
                let (kept, other) = conflict.kept == .onThisMac
                    ? (conflict.onThisMac, conflict.beside) : (conflict.beside, conflict.onThisMac)
                let moves = conflict.kept != destination
                let aside = folder.appending(path: conflict.photo + ".redlamp", directoryHint: .notDirectory)
                settling.append(Step(
                    SidecarMovePlan.Item(photo: conflict.photo, source: other, target: aside),
                    settingAside: true,
                    counts: !moves,
                ))
                if moves {
                    let target = destination == .onThisMac ? conflict.onThisMac : conflict.beside
                    keeping.append(Step(SidecarMovePlan.Item(photo: conflict.photo, source: kept, target: target)))
                }
            }
        }
        let total = plan.items.count + settling.count { $0.counts } + keeping.count
        var outcome = try await moveInParts(
            settling, part: part, control: control, puttingBack: false, progress: progress, total: total,
        )
        if !outcome.settled.isEmpty {
            outcome.setAside = plan.setAside
        }
        guard control?.isCancelled != true else { return outcome }
        let unsettled = Set(outcome.failed.keys)
        let moving = keeping.filter { !unsettled.contains($0.item.photo) } + plan.items.map { Step($0) }
        let moved = try await moveInParts(
            moving, part: part, control: control, puttingBack: false, progress: progress,
            done: settling.count { $0.counts }, total: total,
        )
        outcome.moved += moved.moved
        outcome.gone += moved.gone
        outcome.conflicts += moved.conflicts
        outcome.failed.merge(moved.failed) { first, _ in first }
        return outcome
    }

    /// Moves `steps`, `part` at a time, until `control` stops it between two parts; the progress counts from `done`
    /// up to `total`, all of the steps by default.
    private func moveInParts(
        _ steps: [Step], part size: Int, control: SidecarMoveControl?, puttingBack: Bool,
        progress: (@Sendable (FileProgress) -> Void)?, done counted: Int = 0, total: Int? = nil,
    ) async throws -> SidecarMoveOutcome {
        var outcome = SidecarMoveOutcome()
        var start = 0
        let total = total ?? steps.count
        var reached = counted
        progress?(FileProgress(done: reached, total: total, isRollingBack: puttingBack))
        while start < steps.count, control?.isCancelled != true {
            let part = Array(steps[start ..< min(start + max(size, 1), steps.count)])
            let before = reached
            let moved = try await LibraryIndex.offCaller {
                let outcome = Mutex(SidecarMoveOutcome())
                let done = Atomic(0)
                DispatchQueue.concurrentPerform(iterations: part.count) { index in
                    let step = part[index]
                    let item = step.item
                    let result = Result { try SidecarMover.coordinatedMove(item.source, to: item.target) }
                    outcome.withLock { outcome in
                        switch (result, step.settingAside) {
                        case (.success(.moved), true): outcome.settled.append(item.photo)
                        case (.success(.moved), false): outcome.moved += 1
                        case (.success(.gone), _): outcome.gone += 1
                        case (.success(.conflict), true):
                            outcome.failed[item.photo] = "a copy is already where it would be set aside"
                        case (.success(.conflict), false): outcome.conflicts.append(item.photo)
                        case let (.failure(error), _): outcome.failed[item.photo] = String(describing: error)
                        }
                    }
                    guard step.counts else { return }
                    let count = done.add(1, ordering: .relaxed).newValue
                    progress?(FileProgress(done: before + count, total: total, isRollingBack: puttingBack))
                }
                return outcome.withLock { $0 }
            }
            outcome.moved += moved.moved
            outcome.gone += moved.gone
            outcome.conflicts += moved.conflicts
            outcome.settled += moved.settled
            outcome.failed.merge(moved.failed) { first, _ in first }
            reached += part.count { $0.counts }
            start += part.count
        }
        return outcome
    }

    private func write(_ journal: SidecarMoveJournal) async throws {
        let url = moveJournal
        try await LibraryIndex.offCaller {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try JSONEncoder().encode(journal).write(to: url, options: .atomic)
        }
    }

    private func removeJournal() async throws {
        let url = moveJournal
        try await LibraryIndex.offCaller { try? FileManager.default.removeItem(at: url) }
    }
}

/// Moves one sidecar, a package or a single file, without ever replacing one.
enum SidecarMover {
    enum Outcome {
        case moved
        case gone
        case conflict
    }

    enum Failure: Error, CustomStringConvertible {
        case notCopied(URL)

        var description: String {
            switch self {
            case let .notCopied(url): "the copy at \(url.path) isn't the same as the sidecar"
            }
        }
    }

    /// `move(_:to:)` under file coordination, as every sidecar read and write is.
    static func coordinatedMove(_ source: URL, to target: URL) throws -> Outcome {
        var outcome: Swift.Result<Outcome, any Error>?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: source, options: .forDeleting, writingItemAt: target, options: .forReplacing,
            error: &coordinationError,
        ) { source, target in
            outcome = Swift.Result { try move(source, to: target) }
        }
        if let coordinationError {
            throw coordinationError
        }
        return try (outcome ?? .failure(CocoaError(.fileWriteUnknown))).get()
    }

    /// Copies `source` beside `target` under a hidden name, checks the copy, renames it to
    /// `target`, then removes `source`. Run again after a forced quit, it picks up where that left
    /// off: a sidecar found at both, the same, was copied, and only its source is removed.
    static func move(_ source: URL, to target: URL) throws -> Outcome {
        let fileManager = FileManager.default
        switch (fileManager.fileExists(atPath: source.path), fileManager.fileExists(atPath: target.path)) {
        case (false, true):
            return .moved
        case (false, false):
            return .gone
        case (true, true):
            guard same(source, target) else { return .conflict }
            try remove(source)
            return .moved
        case (true, false):
            break
        }
        let folder = target.deletingLastPathComponent()
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        removeStaging(of: target)
        let staging = folder.appending(path: ".\(target.lastPathComponent).\(UUID().uuidString)")
        do {
            try fileManager.copyItem(at: source, to: staging)
            guard same(source, staging) else { throw Failure.notCopied(staging) }
            try fileManager.moveItem(at: staging, to: target)
        } catch {
            try? fileManager.removeItem(at: staging)
            if fileManager.fileExists(atPath: target.path) {
                return .conflict
            }
            throw error
        }
        try remove(source)
        return .moved
    }

    /// Whether two sidecars hold the same files with the same bytes.
    static func same(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = contents(lhs), let right = contents(rhs) else { return false }
        return left == right
    }

    /// Every file in a sidecar by its path inside it, or the single file's bytes under "".
    private static func contents(_ sidecar: URL) -> [String: Data]? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sidecar.path, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else { return (try? Data(contentsOf: sidecar)).map { ["": $0] } }
        guard let paths = FileManager.default.subpaths(atPath: sidecar.path) else { return nil }
        var files: [String: Data] = [:]
        for path in paths {
            let file = sidecar.appending(path: path)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder) else { return nil }
            if !isFolder.boolValue {
                guard let data = try? Data(contentsOf: file) else { return nil }
                files[path] = data
            }
        }
        return files
    }

    /// Removes a sidecar by renaming it to a hidden name first, as `SidecarStore` does, so an
    /// interrupted removal leaves it whole or gone; the hidden name is an interrupted save's, which
    /// opening its folder removes.
    private static func remove(_ sidecar: URL) throws {
        let hidden = sidecar.deletingLastPathComponent()
            .appending(path: ".\(sidecar.lastPathComponent).\(UUID().uuidString)")
        try FileManager.default.moveItem(at: sidecar, to: hidden)
        try FileManager.default.removeItem(at: hidden)
    }

    /// Removes copies an interrupted move left beside `target`.
    private static func removeStaging(of target: URL) {
        let folder = target.deletingLastPathComponent()
        let prefix = ".\(target.lastPathComponent)."
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names
            where name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }
}
