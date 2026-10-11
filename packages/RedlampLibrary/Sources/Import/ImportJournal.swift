import Foundation
import Synchronization

/// The imports' journal, in `LibraryPaths.root/Imports` on the Mac's own disk, kept as the file
/// operations' is (`FileJournal`): each import a file of JSON lines, its header (its settings, sources
/// and the folders it would make) and then a photo a line, written to a hidden name, synced and renamed
/// into place before anything is copied. Beside it, its log gets a line as each file is verified at each
/// destination, as each photo is placed, done or failed, as a rollback moves each file to the Trash and
/// takes each photo back, and at each change of state, written straight to the file, so a forced quit
/// loses none; `Importer.recover` finishes the import from there, and `Importer.rollBack` the rollback.
public struct ImportJournal: Sendable {
    public let folder: URL
    /// Imports kept; older ones that are over are removed.
    public static let kept = 50
    static let version = 1

    public init(paths: LibraryPaths) {
        folder = paths.root.appending(path: "Imports", directoryHint: .isDirectory)
    }

    public enum State: String, Sendable, Hashable, Codable {
        /// Written, nothing copied yet.
        case planned
        /// Copying, or stopped by a forced quit: the next launch finishes it.
        case running
        /// Every photo done, or failed.
        case finished
        /// Cancelled: the photos done so far are in place, the others weren't copied.
        case stopped
        /// Rolling back: its copies going to the Trash and its photos out of the library, or stopped by a
        /// forced quit or Cancel before the end, for `Importer.rollBack` to finish.
        case rollingBack
        /// Rolled back: the copies it made moved to the Trash, its photos taken out of the library and the
        /// folders it made and left empty removed, but for the photos `ImportRollback.left` names.
        case rolledBack

        /// Whether it has to be finished, or rolled back, before another import runs.
        public var isUnfinished: Bool {
            self == .planned || self == .running || self == .rollingBack
        }
    }

    /// An import as the journal lists it.
    public struct Entry: Sendable, Hashable, Identifiable {
        public var id: UUID
        public var title: String
        public var created: Date
        public var photos: Int
        public var state: State
        /// Photos done and still in place: a rollback takes back those it moves to the Trash.
        public var done: Int
        public var failed: Int
        /// Photos a rollback took back.
        public var rolledBack: Int
    }

    struct Header: Codable {
        var version: Int
        var id: UUID
        var title: String
        var created: Double
        var settings: ImportSettings
        var sources: [ImportPlan.Source]
        var photos: Int
        var folders: [String]
        var counters: NamingCounters
        /// The folders the import would make: those of the destination, the backup, the folders above them
        /// and the plan's folders below them that weren't there when it was written. A rollback removes those
        /// left empty. Nil in an import written before rollbacks.
        var newFolders: [String]?
    }

    /// A line of an import's log.
    struct Record: Codable {
        var verified: Int?
        var copy: Int?
        var target: Int?
        var sha256: String?
        var placed: Int?
        var done: Int?
        var failed: Int?
        var message: String?
        var state: State?
        /// A file of photo `trashed` a rollback moved to the Trash, from `from` to `to`.
        var trashed: Int?
        var from: String?
        var to: String?
        /// A photo a rollback took back: nothing of it the import made is left at the targets, nor in the index.
        var rolledBack: Int?
    }

    /// What an import's log says.
    struct Progress: Sendable, Hashable {
        var state = State.planned
        /// Each copy's SHA-256 once verified at a target, by photo, copy and target.
        var verified: [Int: [Int: [Int: String]]] = [:]
        var placed = Set<Int>()
        /// Photos done and still in place: those a rollback took back aren't.
        var done = Set<Int>()
        var failed: [Int: String] = [:]
        /// The files a rollback moved to the Trash, by photo.
        var trashed: [Int: [ImportRollback.Trashed]] = [:]
        var rolledBack = Set<Int>()
    }

    /// "Import 120 photos from EOS_DIGITAL".
    static func title(of plan: ImportPlan) -> String {
        let count = plan.items.count
        let names = plan.sources.map(\.name).joined(separator: ", ")
        return "Import \(count) photo\(count == 1 ? "" : "s")" + (names.isEmpty ? "" : " from \(names)")
    }

    // MARK: - Writing

    /// Writes `plan`, with `newFolders`, the folders it would make (`Header.newFolders`).
    func write(_ plan: ImportPlan, newFolders: [String] = []) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = Self.fileName(created: plan.created, id: plan.id)
        let header = Header(
            version: Self.version, id: plan.id, title: Self.title(of: plan),
            created: plan.created.timeIntervalSince1970, settings: plan.settings, sources: plan.sources,
            photos: plan.items.count, folders: plan.folders, counters: plan.counters, newFolders: newFolders,
        )
        let encoder = Self.encoder
        var data = try encoder.encode(header)
        data.append(0x0A)
        for item in plan.items {
            try data.append(encoder.encode(item))
            data.append(0x0A)
        }
        let staging = folder.appending(path: ".\(name).import.\(UUID().uuidString)")
        try FileJournal.writeSynced(data, to: staging)
        let log = folder.appending(path: name + ".log")
        try FileJournal.writeSynced(Data(), to: log)
        guard rename(staging.path, folder.appending(path: name + ".import").path) == 0 else {
            let error = POSIXError.current
            unlink(staging.path)
            unlink(log.path)
            throw error
        }
        try FileJournal.synchronizeFolder(folder)
    }

    func log(_ id: UUID) throws -> Log {
        guard let name = try fileNames()[id] else { throw ImportError.noSuchImport(id) }
        return try Log(url: folder.appending(path: name + ".log"))
    }

    /// An import's log, open for adding lines.
    final class Log: Sendable {
        private let descriptor: Int32
        private let lock = Mutex(())

        init(url: URL) throws {
            descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else { throw POSIXError.current }
        }

        deinit {
            close(descriptor)
        }

        func verified(_ item: Int, copy: Int, target: Int, sha256: Data) throws {
            try append(Record(verified: item, copy: copy, target: target, sha256: ImportJournal.hex(sha256)))
        }

        func placed(_ item: Int) throws {
            try append(Record(placed: item))
        }

        func done(_ item: Int) throws {
            try append(Record(done: item))
        }

        func failed(_ item: Int, message: String) throws {
            try append(Record(failed: item, message: message))
        }

        func trashed(_ item: Int, from: URL, to: URL) throws {
            try append(Record(trashed: item, from: from.path, to: to.path))
        }

        func rolledBack(_ item: Int) throws {
            try append(Record(rolledBack: item))
        }

        /// Records a change of state, and syncs the log.
        func state(_ state: State) throws {
            try append(Record(state: state))
            try lock.withLock { _ in
                guard fsync(descriptor) == 0 else { throw POSIXError.current }
            }
        }

        private func append(_ record: Record) throws {
            var line = try ImportJournal.encoder.encode(record)
            line.append(0x0A)
            try lock.withLock { _ in
                try line.withUnsafeBytes { bytes in
                    var written = 0
                    while written < bytes.count {
                        let count = Darwin.write(descriptor, bytes.baseAddress! + written, bytes.count - written)
                        if count < 0 {
                            guard errno == EINTR else { throw POSIXError.current }
                            continue
                        }
                        written += count
                    }
                }
            }
        }
    }

    // MARK: - Reading

    /// Every import, oldest first.
    public func entries() throws -> [Entry] {
        try fileNames().values.sorted().compactMap { name in
            guard let header = try? Self.header(of: folder.appending(path: name + ".import")) else { return nil }
            let progress = progress(name: name)
            return Entry(
                id: header.id, title: header.title, created: Date(timeIntervalSince1970: header.created),
                photos: header.photos, state: progress.state, done: progress.done.count,
                failed: progress.failed.count, rolledBack: progress.rolledBack.count,
            )
        }
    }

    /// The folders the import would make, as its header keeps them (`Header.newFolders`).
    func newFolders(_ id: UUID) throws -> [String]? {
        guard let name = try fileNames()[id] else { throw ImportError.noSuchImport(id) }
        return try Self.header(of: folder.appending(path: name + ".import")).newFolders
    }

    /// The destinations and backups of every import it keeps, from their headers alone.
    public func targets() throws -> [URL] {
        try fileNames().values.compactMap { name in try? Self.header(of: folder.appending(path: name + ".import")) }
            .flatMap { header in [header.settings.destination] + (header.settings.backup.map { [$0] } ?? []) }
    }

    /// The import's plan, as far as the journal keeps it, and what its log says.
    func load(_ id: UUID) throws -> (plan: ImportPlan, progress: Progress) {
        guard let name = try fileNames()[id] else { throw ImportError.noSuchImport(id) }
        let data = try Data(contentsOf: folder.appending(path: name + ".import"))
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true).makeIterator()
        let decoder = JSONDecoder()
        guard let first = lines.next() else { throw ImportError.damagedJournal(id) }
        let header = try decoder.decode(Header.self, from: first)
        guard header.version <= Self.version else { throw ImportError.newerJournal(id) }
        var items: [ImportPlan.Item] = []
        while let line = lines.next() {
            try items.append(decoder.decode(ImportPlan.Item.self, from: line))
        }
        guard items.count == header.photos else { throw ImportError.damagedJournal(id) }
        let plan = ImportPlan(
            id: header.id, created: Date(timeIntervalSince1970: header.created), settings: header.settings,
            sources: header.sources, items: items, folders: header.folders, counters: header.counters,
        )
        return (plan, progress(name: name))
    }

    /// The log's lines played back; a line a forced quit cut short is left out.
    private func progress(name: String) -> Progress {
        var progress = Progress()
        guard let data = try? Data(contentsOf: folder.appending(path: name + ".log")) else { return progress }
        let decoder = JSONDecoder()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let record = try? decoder.decode(Record.self, from: line) else { continue }
            if let item = record.verified, let copy = record.copy, let target = record.target, let sha = record.sha256 {
                progress.verified[item, default: [:]][copy, default: [:]][target] = sha
            }
            if let item = record.placed {
                progress.placed.insert(item)
            }
            if let item = record.done {
                progress.done.insert(item)
                progress.failed.removeValue(forKey: item)
            }
            if let item = record.failed {
                progress.failed[item] = record.message ?? ""
            }
            if let item = record.trashed, let from = record.from, let to = record.to {
                progress.trashed[item, default: []].append(ImportRollback.Trashed(from: from, to: to))
            }
            if let item = record.rolledBack {
                progress.rolledBack.insert(item)
            }
            if let state = record.state {
                progress.state = state
            } else if progress.state == .planned {
                progress.state = .running
            }
        }
        progress.done.subtract(progress.rolledBack)
        return progress
    }

    private func fileNames() throws -> [UUID: String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [:] }
        var found: [UUID: String] = [:]
        for name in names where name.hasSuffix(".import") && !name.hasPrefix(".") {
            let stem = String(name.dropLast(".import".count))
            if let id = stem.split(separator: " ").last.flatMap({ UUID(uuidString: String($0)) }) {
                found[id] = stem
            }
        }
        return found
    }

    /// Removes all but the `kept` newest imports that are over, and what interrupted writes left.
    func prune() {
        guard let entries = try? entries(), let names = try? fileNames() else { return }
        for entry in entries.filter({ !$0.state.isUnfinished }).dropLast(Self.kept) {
            guard let name = names[entry.id] else { continue }
            unlink(folder.appending(path: name + ".import").path)
            unlink(folder.appending(path: name + ".log").path)
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            where name.hasPrefix(".") && name.contains(".import.") {
            unlink(folder.appending(path: name).path)
        }
    }

    // MARK: - Files

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return encoder
    }

    static func fileName(created: Date, id: UUID) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HHmmss.SSS"
        return formatter.string(from: created) + " " + id.uuidString
    }

    static func header(of url: URL) throws -> Header {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.firstIndex(of: 0x0A) == nil, let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            data.append(chunk)
        }
        return try JSONDecoder().decode(Header.self, from: data.prefix { $0 != 0x0A })
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

public enum ImportError: Error, Sendable, Hashable, CustomStringConvertible {
    case noSuchImport(UUID)
    /// The import's file in the journal can't be read.
    case damagedJournal(UUID)
    /// The import was written by a newer Redlamp.
    case newerJournal(UUID)
    /// An import a forced quit interrupted waits to be finished (`Importer.recover`) or rolled back
    /// (`Importer.rollBack`), or a rollback waits to be finished.
    case unfinished(UUID)
    /// The destination or the backup holding copies the import made isn't there, so it can't be rolled back.
    case missingTarget(UUID, path: String)

    public var description: String {
        switch self {
        case let .noSuchImport(id): "there's no import \(id.uuidString) in the journal"
        case let .damagedJournal(id): "import \(id.uuidString) can't be read from the journal"
        case let .newerJournal(id): "import \(id.uuidString) was written by a newer Redlamp"
        case let .unfinished(id): "import \(id.uuidString) was interrupted and has to be finished first"
        case let .missingTarget(_, path): "\(path) isn't there: connect it to roll the import back"
        }
    }
}
