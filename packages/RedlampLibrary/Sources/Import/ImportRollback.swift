import Foundation
import RedlampDocument

/// What rolling an import back did (LIB-27).
public struct ImportRollback: Sendable, Hashable {
    /// A file a rollback moved to the Trash: where it was, and where it went.
    public struct Trashed: Sendable, Hashable, Codable {
        public var from: String
        public var to: String
    }

    /// A copy a rollback left where it is, and why: it isn't the file the import made any more, or it
    /// couldn't be moved to the Trash.
    public struct Left: Sendable, Hashable {
        /// The photo's ID on its source (`ImportPlan.Item.photo`).
        public var photo: String
        public var path: String
        public var message: String
    }

    /// How far a rollback has got: photos taken back, of those the import had copied.
    public struct Progress: Sendable, Hashable {
        public var photos: Int
        public var done: Int
    }

    public var id: UUID
    /// `.rolledBack`; `.rollingBack` when it was cancelled before the end, for `Importer.rollBack` to finish.
    public var state: ImportJournal.State
    /// Photos the import had copied, or begun to, at the destination or the backup.
    public var photos: Int
    /// Those taken back, by their IDs on their sources (`ImportPlan.Item.photo`): every copy of them the import
    /// made moved to the Trash, or gone already, and their rows out of the index.
    public var rolledBack: [String]
    public var trashed: [Trashed]
    /// Photos taken out of the library.
    public var removed: Int
    /// The folders the import made that were left empty, and removed.
    public var removedFolders: [String]
    public var left: [Left]
    public var elapsed: Duration
    /// For a rollback a forced quit or Cancel stopped: the photos it had taken back before.
    public var recoveredFrom: Int?
}

extension Importer {
    /// Photos taken back between two of the index's writes.
    static let rollbackBatch = 64

    /// Rolls import `id` back (LIB-27): an import cancelled, cut short by a forced quit, or finished. Each copy
    /// it made at the destination and the backup goes to the Trash, with the `.redlamp` sidecars beside its
    /// photos at the destination; its photos' rows leave the index; the folders it made (`newFolders`) that are
    /// left empty are removed, but the library's roots. A photo file is taken only while it's the copy the
    /// import made: of its size, with its content key. A photo one of whose files isn't stays whole, at every
    /// target, and the rollback says so. What the import staged under hidden names is removed. The sources
    /// are never touched.
    ///
    /// It's journaled in the import's log, as the import is: once its state is `rollingBack`, each file moved
    /// to the Trash and each photo taken back gets a line. Cancelling stops it between batches of photos,
    /// leaving it `rollingBack`, as a forced quit does; calling it again finishes it. Throws
    /// `ImportError.missingTarget` while the destination or the backup holding copies isn't there.
    @discardableResult
    public func rollBack(
        _ id: UUID, progress: (@Sendable (ImportRollback.Progress) -> Void)? = nil,
    ) async throws -> ImportRollback {
        try await serially { [self] in
            let journal = journal
            let (plan, logged, newFolders) = try await LibraryIndex.offCaller {
                let (plan, logged) = try journal.load(id)
                return try (plan, logged, journal.newFolders(id))
            }
            return try await rollBack(plan, logged: logged, newFolders: newFolders ?? [], progress: progress)
        }
    }

    private func rollBack(
        _ plan: ImportPlan, logged: ImportJournal.Progress, newFolders: [String],
        progress: (@Sendable (ImportRollback.Progress) -> Void)?,
    ) async throws -> ImportRollback {
        let started = ContinuousClock.now
        let fileSystem = destinationFileSystem
        let copied = plan.items.indices.filter { logged.verified[$0] != nil }
        let pending = plan.items.indices.filter { !logged.rolledBack.contains($0) }
        try await LibraryIndex.offCaller {
            for (number, root) in plan.roots.enumerated() {
                let holds = pending.contains { index in
                    logged.verified[index]?.values.contains { $0[number] != nil } == true
                }
                if holds, !fileSystem.exists(root) {
                    throw ImportError.missingTarget(plan.id, path: LibraryIndexer.path(root))
                }
            }
        }
        let log = try journal.log(plan.id)
        try log.state(.rollingBack)
        let locator = try await locator()
        let held = await library.index?.folderHolds.hold(Self.heldFolders(plan, newFolders: newFolders))
        defer { held?.release() }

        var rolledBack = logged.rolledBack
        var trashed = logged.trashed.sorted { $0.key < $1.key }.flatMap(\.value)
        var left: [ImportRollback.Left] = []
        var removed = 0
        var stopped = false
        var quitting: Int? = switch interruption.withLock({ $0 }) {
        case let .afterTakingBack(count): count
        default: nil
        }
        for start in stride(from: 0, to: pending.count, by: Self.rollbackBatch) {
            guard !Task.isCancelled else {
                stopped = true
                break
            }
            let batch = Array(pending[start ..< min(start + Self.rollbackBatch, pending.count)])
            let quitAfter = quitting
            let part = try await LibraryIndex.offCaller {
                try Self.takeBack(
                    batch, of: plan, logged: logged, fileSystem: fileSystem, locator: locator, log: log,
                    quitAfter: quitAfter,
                )
            }
            quitting = quitting.map { $0 - part.done.count }
            removed += try await removeRows(of: part.gone)
            for index in part.done {
                try log.rolledBack(index)
            }
            rolledBack.formUnion(part.done)
            trashed += part.trashed
            left += part.left
            progress?(ImportRollback.Progress(photos: copied.count, done: copied.count { rolledBack.contains($0) }))
        }
        var removedFolders: [String] = []
        if !stopped {
            removedFolders = try await removeFolders(newFolders)
            try log.state(.rolledBack)
        }
        let before = copied.count { logged.rolledBack.contains($0) }
        return ImportRollback(
            id: plan.id, state: stopped ? .rollingBack : .rolledBack, photos: copied.count,
            rolledBack: copied.filter { rolledBack.contains($0) }.map { plan.items[$0].photo }, trashed: trashed,
            removed: removed, removedFolders: removedFolders, left: left, elapsed: ContinuousClock.now - started,
            recoveredFrom: logged.state == .rollingBack ? before : nil,
        )
    }

    /// What taking a batch of photos back did.
    private struct Part: Sendable {
        /// A photo file gone from where the import put it, moved to the Trash now or gone before: its row goes.
        struct Gone: Sendable {
            var path: String
            var key: ContentKey?
        }

        /// The photos taken back whole, of those the import had copied.
        var done: [Int] = []
        var gone: [Gone] = []
        var trashed: [ImportRollback.Trashed] = []
        var left: [ImportRollback.Left] = []
    }

    /// Whether a file at a target is the copy the import made.
    private enum Found {
        case made
        case gone
        case other(String)
    }

    /// Takes `batch`'s photos back at every target, as `rollBack` describes, logging each file moved to the
    /// Trash; with `quitAfter`, stops as a forced quit would once that many are. It blocks on the targets' file
    /// system: run it off the caller.
    private static func takeBack(
        _ batch: [Int], of plan: ImportPlan, logged: ImportJournal.Progress, fileSystem: any LibraryFileSystem,
        locator: SidecarLocator, log: ImportJournal.Log, quitAfter: Int?,
    ) throws -> Part {
        var part = Part()
        for index in batch {
            let item = plan.items[index]
            let verified = logged.verified[index] ?? [:]
            for number in plan.roots.indices {
                for copy in item.copies {
                    let staging = ImportCopier.staging(for: plan.targets(of: copy)[number])
                    if fileSystem.exists(staging) {
                        try? fileSystem.removeItem(at: staging)
                    }
                }
            }
            guard !verified.isEmpty else { continue }
            // A photo one of whose files isn't the copy the import made any more stays whole, at every target.
            var photos: [(number: Int, copy: ImportPlan.Copy, target: URL, present: Bool)] = []
            var changed: [ImportRollback.Left] = []
            for number in plan.roots.indices {
                for (place, copy) in item.copies.enumerated()
                    where copy.role == .photo && verified[place]?[number] != nil {
                    let target = plan.targets(of: copy)[number]
                    switch check(copy, at: target, fileSystem: fileSystem) {
                    case .made: photos.append((number, copy, target, true))
                    case .gone: photos.append((number, copy, target, false))
                    case let .other(message):
                        changed.append(ImportRollback.Left(photo: item.photo, path: target.path, message: message))
                    }
                }
            }
            guard changed.isEmpty else {
                part.left += changed
                continue
            }
            var whole = true
            targets: for number in plan.roots.indices {
                let here = photos.filter { $0.number == number }
                var files = here.filter(\.present).map(\.target)
                for (place, copy) in item.copies.enumerated()
                    where copy.role != .photo && verified[place]?[number] != nil {
                    let target = plan.targets(of: copy)[number]
                    if fileSystem.exists(target) {
                        files.append(target)
                    }
                }
                if number == 0 {
                    for photo in here {
                        let sidecars = [SidecarLocator.besidePhoto(photo.target), locator.onThisMac(photo.target)]
                        for sidecar in sidecars.compactMap(\.self) where !files.contains(sidecar) {
                            if fileSystem.exists(sidecar) {
                                files.append(sidecar)
                            }
                        }
                    }
                }
                var moved = Set<String>()
                defer {
                    for photo in here where !photo.present || moved.contains(photo.target.path) {
                        part.gone.append(Part.Gone(path: LibraryIndexer.path(photo.target), key: photo.copy.contentKey))
                    }
                }
                for file in files {
                    let place: URL
                    do {
                        place = try fileSystem.trashItem(at: file)
                    } catch {
                        whole = false
                        part.left.append(ImportRollback.Left(
                            photo: item.photo, path: file.path,
                            message: "it couldn't be moved to the Trash: \(ImportCopyError.message(error))",
                        ))
                        break targets
                    }
                    try log.trashed(index, from: file, to: place)
                    part.trashed.append(ImportRollback.Trashed(from: file.path, to: place.path))
                    moved.insert(file.path)
                }
            }
            if whole {
                part.done.append(index)
            }
            if let quitAfter, part.done.count >= quitAfter {
                throw ForcedQuit()
            }
        }
        return part
    }

    /// Whether the file at `target` is `copy` as the import made it: of its size and, for a photo, with its
    /// content key. Photo files never change once they're in place: Redlamp writes its edits beside them.
    private static func check(_ copy: ImportPlan.Copy, at target: URL, fileSystem: any LibraryFileSystem) -> Found {
        let entry: FileEntry
        do {
            entry = try fileSystem.attributes(of: target)
        } catch where VolumeIO.isNotFound(error) {
            return .gone
        } catch {
            return .other("it couldn't be checked: \(ImportCopyError.message(error))")
        }
        let changed = Found.other("it isn't the copy the import made: it changed since")
        guard !entry.isDirectory, entry.size == copy.size else { return changed }
        if let key = copy.contentKey {
            guard let head = try? fileSystem.read(target, range: 0 ..< ContentKey.headLength),
                  ContentKey(fileSize: Int(entry.size), head: head) == key
            else { return changed }
        }
        return .made
    }

    /// The folders a rollback changes, which the indexer leaves meanwhile: those the import's photos are in at
    /// the destination and the backup, and those it made, with everything below them.
    private static func heldFolders(_ plan: ImportPlan, newFolders: [String]) -> Set<FolderHolds.Folder> {
        var held = Set(newFolders.map { FolderHolds.Folder($0, subtree: true) })
        for root in plan.roots {
            let path = LibraryIndexer.path(root)
            held.insert(FolderHolds.Folder(path))
            for folder in plan.folders {
                held.insert(FolderHolds.Folder(ImportPlanner.join(path, folder)))
            }
        }
        return held
    }

    /// Takes out of the index the rows of photo files gone from where the import put them, those whose content
    /// key is the copy's, and tells the live lists; returns how many went.
    private func removeRows(of gone: [Part.Gone]) async throws -> Int {
        guard let index = library.index, !gone.isEmpty else { return 0 }
        let ids = try await index.write { writer -> [Int64] in
            var ids: [Int64] = []
            for file in gone {
                let (folderPath, name) = FilePlanner.split(file.path)
                guard let folder = try writer.folder(anyFormOf: folderPath) else { continue }
                var forms: [String] = []
                for form in [
                    name, name.precomposedStringWithCanonicalMapping, name.decomposedStringWithCanonicalMapping,
                ] where !forms.contains(form) {
                    forms.append(form)
                }
                for form in forms {
                    guard let row = try writer.photo(folder: folder.id, name: form) else { continue }
                    if let key = file.key?.data, let held = row.contentKey, held != key {
                        break
                    }
                    ids.append(row.id)
                    break
                }
            }
            try writer.deletePhotos(ids)
            return ids
        }
        if !ids.isEmpty {
            library.live?.receive(.photosRemoved(ids))
        }
        return ids.count
    }

    /// Removes the folders of `folders` left empty, the deepest first, but the library's roots, and their rows;
    /// returns those removed.
    private func removeFolders(_ folders: [String]) async throws -> [String] {
        guard !folders.isEmpty else { return [] }
        let roots = try await Set(library.index?.read { reader in try reader.roots().map(\.path) } ?? [])
        let removed = try await LibraryIndex.offCaller {
            folders.sorted { $0.count > $1.count }.filter { !roots.contains($0) && Self.removeIfEmpty($0) }
        }
        guard let index = library.index, !removed.isEmpty else { return removed }
        let parents = try await index.write { writer -> Set<String> in
            var parents = Set<String>()
            for path in removed where try writer.removeFolderIfEmpty(path) {
                parents.insert(FilePlanner.split(path).folder)
            }
            return parents.subtracting(removed)
        }
        for parent in parents.sorted() {
            library.live?.receive(.folderIndexed(FolderIndexed(path: parent)))
        }
        return removed
    }

    /// Removes the folder at `path` if it holds nothing, or only what the Finder leaves in a folder it shows
    /// (`.DS_Store`, and AppleDouble files on volumes without extended attributes); whether it went.
    static func removeIfEmpty(_ path: String) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path),
              names.allSatisfy({ $0 == ".DS_Store" || $0.hasPrefix("._") })
        else { return false }
        for name in names {
            unlink(path + "/" + name)
        }
        return rmdir(path) == 0
    }
}
