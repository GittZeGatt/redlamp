import CoreGraphics
import Foundation
import RedlampDocument
import Synchronization

/// What an import session reports as it browses its sources, each once the session holds it.
public enum ImportEvent: Sendable, Hashable {
    /// A source's photos are listed, newest first by their files' dates.
    case listed(source: String, photos: [String])
    /// Photos whose first bytes are read: their content keys, metadata and the ratings they carry.
    case read([String])
    /// Photos shown from the small thumbnail their first bytes hold until their grid thumbnails are made.
    case provisional([String])
    /// Photos whose grid thumbnails are in the store.
    case previewed([String])
    /// Photos the library has already, every photo file of them, so their previews aren't read.
    case imported([String])
    case failed(photo: String, message: String)
    /// A source that couldn't be listed: gone, or not answering.
    case sourceFailed(source: String, message: String)
    /// Every source is listed and every photo read, and previewed unless the library has it.
    case browsed
}

/// An import's browsing (LIB-27): its sources, each listed and read through its own volume's readers,
/// and their photos with what the user chooses for them.
///
/// - **At once:** each source is listed, then its photos are read newest first, those on screen
///   (`prioritise`) before the rest: each photo's first bytes once, for its content keys, metadata and
///   the rating and label it carries, then its embedded preview, made into a grid thumbnail in the
///   store under its content key. Nothing is copied, and nothing written beside the photos.
/// - **JPEGs:** a camera JPEG holds no preview of a grid's size in its first bytes, so one larger than
///   `provisionalSize` is shown from what it offers there: a Multi-Picture Format large thumbnail, read
///   alone, makes its grid thumbnail; else the thumbnail in its EXIF is kept in memory as a provisional
///   preview (`provisionalPreview`), never stored, and the photo is read whole and decoded at a fraction
///   of its size for its grid thumbnail later, those on screen first, once no head on screen waits.
/// - **Already imported:** a photo's content keys are looked up among the library's, loaded once, as
///   soon as its head is read and before its preview is: a photo the library has is marked, and its
///   preview isn't read.
/// - **While it copies:** previews are read at the volume's high priority and copies at its normal
///   one, through the same readers (`importer`).
/// - **Choices:** which photos go, and the rating, flag and label each is given, are kept here until
///   the import is planned, and written in each photo's `.redlamp` at the destination.
public final class ImportSession: Sendable {
    public let sources: [ImportSource]
    public let library: ImportLibrary
    public let fileSystem: any LibraryFileSystem
    public let volumes: VolumeIORegistry
    public let scheduler: WorkScheduler
    /// Browsing makes grid thumbnails; without, it reads only the photos' heads.
    public let makesPreviews: Bool
    private let state = Mutex(State())

    /// Photos kept in memory whole, at most, when one has no embedded preview to take.
    static let wholeFileLimit = 128 << 20
    /// Photos read whole with their heads, at most, when their previews are made from all of them.
    static let wholeFileRead = 16 << 20
    /// JPEGs read whole with their heads, at most: a larger one is first shown from what its head offers.
    static let provisionalSize = 1 << 20
    /// A Multi-Picture Format large thumbnail read for a grid thumbnail, at most.
    static let largeThumbnailLimit = 4 << 20

    /// A provisional preview: the JPEG of the thumbnail in a photo's EXIF, and the photo's orientation.
    struct Provisional: Sendable {
        var jpeg: Data
        var orientation: Int?
    }

    private struct State {
        var photos: [String: ImportPhoto] = [:]
        /// Each source's photos, newest first.
        var bySource: [String: [String]] = [:]
        /// Each source's files that aren't photos or sidecars of them, by path.
        var others: [String: [String]] = [:]
        /// The photos on screen whose heads aren't claimed yet, first first.
        var prioritised: [String] = []
        /// The photos on screen, first first.
        var onScreen: [String] = []
        /// Each source's place in its photos, newest first, for its readers.
        var cursors: [String: Int] = [:]
        /// The provisional previews of photos waiting for their grid thumbnails.
        var provisional: [String: Provisional] = [:]
        /// Each source's photos waiting for their grid thumbnails, in the order their provisional previews
        /// were made, and the place its readers have got to.
        var refining: [String: [String]] = [:]
        var refiningCursors: [String: Int] = [:]
        /// Photos waiting for their grid thumbnails that no reader has claimed.
        var unrefined: Set<String> = []
        /// Photos being read, or read.
        var claimed: Set<String> = []
        /// Sources listed, by ID.
        var listed: Set<String> = []
        var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
        var keys: Task<ImportKeys, Never>?
        var browsing: Task<Void, Never>?
    }

    public init(
        sources: [ImportSource], library: ImportLibrary, fileSystem: any LibraryFileSystem = LocalFileSystem(),
        volumes: VolumeIORegistry? = nil, scheduler: WorkScheduler = LibraryIndexer.scheduler,
        makesPreviews: Bool = true,
    ) {
        self.sources = sources
        self.library = library
        self.fileSystem = fileSystem
        self.volumes = volumes ?? VolumeIORegistry(fileSystem: fileSystem)
        self.scheduler = scheduler
        self.makesPreviews = makesPreviews
    }

    /// The readers `source` is read through: its volume's.
    public func io(for source: ImportSource) -> VolumeIO {
        volumes.io(for: source.volume, probe: source.url)
    }

    // MARK: - Photos and choices

    /// Every source's photos, newest first.
    public var photos: [ImportPhoto] {
        state.withLock { Array($0.photos.values) }.sorted { first, second in
            first.captured != second.captured ? first.captured > second.captured : first.id < second.id
        }
    }

    public func photo(_ id: String) -> ImportPhoto? {
        state.withLock { $0.photos[id] }
    }

    /// The files on `source` that aren't photos or their sidecars, by path: videos, a camera's own.
    public func otherFiles(on source: ImportSource) -> [String] {
        state.withLock { $0.others[source.id] ?? [] }
    }

    /// Reads these photos before the others: the cells on screen, first first.
    public func prioritise(_ ids: [String]) {
        state.withLock { state in
            state.prioritised = ids
            state.onScreen = ids
        }
    }

    /// Photo `id`'s provisional preview, upright and at most `edge` on its long side: the thumbnail in its
    /// EXIF, while its grid thumbnail isn't made yet; nil once it is, and for a photo that has none.
    public func provisionalPreview(_ id: String, edge: Int) -> CGImage? {
        guard let small = state.withLock({ $0.provisional[id] }) else { return nil }
        return EmbeddedPreviews.thumbnail(ofJPEG: small.jpeg, edge: edge, orientation: small.orientation)
    }

    public func choose(_ ids: [String], _ chosen: Bool) {
        change(ids) { $0.isChosen = chosen }
    }

    public func rate(_ ids: [String], _ stars: Int) {
        change(ids) { $0.rate(stars) }
    }

    public func flag(_ ids: [String], _ flag: PhotoFlag?) {
        change(ids) { $0.setFlag(flag) }
    }

    public func label(_ ids: [String], _ label: ColorLabel?) {
        change(ids) { $0.setLabel(label) }
    }

    /// Takes `photos` as their sources' only ones, listed elsewhere, as they were read and with the choices
    /// made for them: the ingest step lists the one it's given, and the import window plans together the
    /// photos it browsed in a session for each source.
    public func add(_ photos: [ImportPhoto]) {
        state.withLock { state in
            for photo in photos where state.photos[photo.id] == nil {
                state.photos[photo.id] = photo
                state.bySource[photo.source, default: []].append(photo.id)
                state.listed.insert(photo.source)
            }
        }
    }

    func change(_ ids: [String], _ body: (inout ImportChoices) -> Void) {
        state.withLock { state in
            for id in ids {
                if var choices = state.photos[id]?.choices {
                    body(&choices)
                    state.photos[id]?.choices = choices
                }
            }
        }
    }

    // MARK: - Browsing

    /// Lists every source and reads its photos, as the type describes, reporting each step; cancelling
    /// the task iterating the events stops it.
    public func browse() -> AsyncStream<ImportEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ImportEvent.self)
        let task = Task { [self] in
            await withTaskGroup(of: Void.self) { group in
                for source in sources {
                    group.addTask { await self.browse(source, events: continuation) }
                }
            }
            if !Task.isCancelled {
                continuation.yield(.browsed)
            }
            continuation.finish()
        }
        state.withLock { $0.browsing = task }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Stops browsing.
    public func close() {
        state.withLock { $0.browsing }?.cancel()
    }

    /// Photos read at once on a volume: enough to keep its readers busy while others parse and decode.
    static func readers(_ io: VolumeIO) -> Int {
        min(max(2 * io.width, 4), 2 * CoreCounts.performance)
    }

    private func browse(_ source: ImportSource, events: AsyncStream<ImportEvent>.Continuation) async {
        let io = io(for: source)
        do {
            if !state.withLock({ $0.listed.contains(source.id) }) {
                try await list(source, io: io)
            }
        } catch {
            events.yield(.sourceFailed(source: source.id, message: ImportCopyError.message(error)))
            return
        }
        events.yield(.listed(source: source.id, photos: state.withLock { $0.bySource[source.id] ?? [] }))
        let keys = await knownKeys()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< Self.readers(io) {
                group.addTask {
                    while !Task.isCancelled, let work = self.claimNext(on: source.id) {
                        switch work {
                        case let .head(id):
                            await self.read(id, io: io, keys: keys, previewing: self.makesPreviews, events: events)
                        case let .refine(id, onScreen):
                            await self.refine(id, io: io, priority: onScreen ? .high : .normal, events: events)
                        }
                    }
                }
            }
        }
    }
}

extension ImportSession {
    /// Lists `source`'s photo folder and every folder below it: a folder that can't be listed below
    /// the first is left out.
    private func list(_ source: ImportSource, io: VolumeIO) async throws {
        let top = LibraryIndexer.path(source.photosFolder)
        var waiting = [top]
        var photos: [ImportPhoto] = []
        var others: [String] = []
        while let folder = waiting.popLast() {
            let entries: [FileEntry]
            do {
                entries = try await io.contentsOfDirectory(at: URL(fileURLWithPath: folder, isDirectory: true))
            } catch where folder != top && VolumeIO.isNotFound(error) {
                continue
            }
            let (found, rest) = ImportPhoto.group(entries, folder: folder, source: source.id)
            photos += found
            others += rest.map { folder + "/" + $0.name }
            waiting += entries.filter(FolderWalk.isFolder).map { folder + "/" + $0.name }
        }
        photos.sort { $0.captured != $1.captured ? $0.captured > $1.captured : $0.id < $1.id }
        state.withLock { state in
            guard state.listed.insert(source.id).inserted else { return }
            for photo in photos where state.photos[photo.id] == nil {
                state.photos[photo.id] = photo
            }
            state.bySource[source.id] = photos.map(\.id)
            state.others[source.id] = others.sorted()
        }
    }

    /// Lists the sources not listed yet; one that can't be is left out.
    private func ensureListed() async {
        let unlisted = state.withLock { state in sources.filter { !state.listed.contains($0.id) } }
        await withTaskGroup(of: Void.self) { group in
            for source in unlisted {
                group.addTask { try? await self.list(source, io: self.io(for: source)) }
            }
        }
    }

    /// The library's content keys, loaded the first time they're asked for.
    private func knownKeys() async -> ImportKeys {
        let task = state.withLock { state in
            if let keys = state.keys {
                return keys
            }
            let library = library
            let keys = Task { await (try? library.contentKeys()) ?? ImportKeys() }
            state.keys = keys
            return keys
        }
        return await task.value
    }

    /// What a reader does next.
    private enum Work: Sendable {
        /// Reads the photo's head, and makes its preview or provisional preview.
        case head(String)
        /// Makes the grid thumbnail of a photo shown from its provisional preview.
        case refine(String, onScreen: Bool)
    }

    /// The next work on `source`: the head of a photo on screen, then the grid thumbnail of one on screen
    /// shown from its provisional preview, then the newest head not yet read, then the next grid thumbnail.
    private func claimNext(on source: String) -> Work? {
        state.withLock { state in
            if let index = state.prioritised.firstIndex(where: { id in
                state.photos[id]?.source == source && !state.claimed.contains(id)
            }) {
                let id = state.prioritised.remove(at: index)
                state.claimed.insert(id)
                return .head(id)
            }
            if let id = state.onScreen.first(where: { id in
                state.unrefined.contains(id) && state.photos[id]?.source == source
            }) {
                state.unrefined.remove(id)
                return .refine(id, onScreen: true)
            }
            let order = state.bySource[source] ?? []
            var cursor = state.cursors[source] ?? 0
            defer { state.cursors[source] = cursor }
            while cursor < order.count {
                let id = order[cursor]
                cursor += 1
                if state.claimed.insert(id).inserted {
                    return .head(id)
                }
            }
            let waiting = state.refining[source] ?? []
            var next = state.refiningCursors[source] ?? 0
            defer { state.refiningCursors[source] = next }
            while next < waiting.count {
                let id = waiting[next]
                next += 1
                if state.unrefined.remove(id) != nil {
                    return .refine(id, onScreen: false)
                }
            }
            return nil
        }
    }

    /// Reads photo `id`'s head and, when `previewing` and the library doesn't have it, its preview.
    private func read(
        _ id: String, io: VolumeIO, keys: ImportKeys, previewing: Bool,
        events: AsyncStream<ImportEvent>.Continuation?,
    ) async {
        guard let photo = state.withLock({ $0.photos[id] }) else { return }
        let priority: VolumeIO.Priority = previewing ? .high : .normal
        let read: ReadHead
        do {
            read = try await readHead(of: photo, io: io, priority: priority, keys: keys)
        } catch is CancellationError {
            state.withLock { _ = $0.claimed.remove(id) }
            finish(id) { _ in }
            return
        } catch {
            let message = ImportCopyError.message(error)
            finish(id) { $0.state = .failed(message) }
            events?.yield(.failed(photo: id, message: message))
            return
        }
        let updated = finish(id) { photo in
            for index in photo.files.indices {
                photo.files[index].contentKey = read.keys[photo.files[index].name]
            }
            photo.metadata = read.metadata
            photo.xmp = read.xmp
            photo.imported = Set(read.keys.filter { keys.contains($0.value) }.keys)
            photo.state = photo.isImported ? .imported : .read
            photo.choices.fill(from: photo.ownChoices)
        }
        guard let updated else { return }
        events?.yield(updated.isImported ? .imported([id]) : .read([id]))
        guard previewing, !updated.isImported, let store = library.store, let key = read.keys[updated.primary.name]
        else { return }
        let made: Preview = if store.contains(
            key,
            tier: .grid,
            size: updated.primary.size,
            modified: updated.primary.modified,
        ) {
            .made
        } else {
            await (try? preview(updated, key: key, head: read.head, io: io, store: store)) ?? .nothing
        }
        switch made {
        case .made:
            state.withLock { $0.photos[id]?.state = .previewed }
            events?.yield(.previewed([id]))
        case let .provisional(small):
            state.withLock { state in
                state.photos[id]?.state = .provisional
                state.provisional[id] = small
                state.refining[updated.source, default: []].append(id)
                state.unrefined.insert(id)
            }
            events?.yield(.provisional([id]))
        case .nothing:
            break
        }
    }

    /// Makes the grid thumbnail of photo `id`, shown from its provisional preview, from the whole photo read at
    /// `priority`, and lets the provisional preview go.
    private func refine(
        _ id: String, io: VolumeIO, priority: VolumeIO.Priority, events: AsyncStream<ImportEvent>.Continuation?,
    ) async {
        guard let photo = state.withLock({ $0.photos[id] }), let store = library.store,
              let key = photo.primary.contentKey
        else { return }
        let made = await (try? wholePreview(photo, key: key, head: Data(), io: io, store: store, priority: priority))
            ?? false
        guard made else { return }
        state.withLock { state in
            state.provisional[id] = nil
            state.photos[id]?.state = .previewed
        }
        events?.yield(.previewed([id]))
    }

    /// Changes photo `id` as its head's reading ended, and lets go of what waited for it.
    @discardableResult
    private func finish(_ id: String, _ change: (inout ImportPhoto) -> Void) -> ImportPhoto? {
        let (photo, waiters) = state.withLock { state -> (ImportPhoto?, [CheckedContinuation<Void, Never>]) in
            if var photo = state.photos[id] {
                change(&photo)
                state.photos[id] = photo
            }
            return (state.photos[id], state.waiters.removeValue(forKey: id) ?? [])
        }
        for waiter in waiters {
            waiter.resume()
        }
        return photo
    }

    /// Reads every one of `ids` not read yet, a source's at a time on its own readers, waiting for those
    /// browsing reads now; without previews.
    func ensureRead(_ ids: [String]) async {
        let keys = await knownKeys()
        let bySource = state.withLock { state in
            Dictionary(grouping: ids.filter { state.photos[$0]?.isRead == false }) { state.photos[$0]?.source ?? "" }
        }
        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                guard let pending = bySource[source.id], !pending.isEmpty else { continue }
                let io = io(for: source)
                let queue = ImportQueue(pending)
                for _ in 0 ..< Self.readers(io) {
                    group.addTask {
                        while !Task.isCancelled, let id = queue.next() {
                            while !Task.isCancelled, self.photo(id)?.isRead == false {
                                if self.state.withLock({ $0.claimed.insert(id).inserted }) {
                                    await self.read(id, io: io, keys: keys, previewing: false, events: nil)
                                } else {
                                    await self.waitForHead(id)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func waitForHead(_ id: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let read = state.withLock { state -> Bool in
                guard state.photos[id]?.isRead == false else { return true }
                state.waiters[id, default: []].append(continuation)
                return false
            }
            if read {
                continuation.resume()
            }
        }
    }

    // MARK: - Heads

    struct ReadHead: Sendable {
        var head: Data
        var metadata: CaptureMetadata?
        var xmp: CaptureMetadata?
        /// Each photo file's content key, by name.
        var keys: [String: ContentKey]

        init(head: Data, metadata: CaptureMetadata? = nil, xmp: CaptureMetadata? = nil, keys: [String: ContentKey]) {
            self.head = head
            self.metadata = metadata
            self.xmp = xmp
            self.keys = keys
        }
    }

    /// The photo's first photo file's head (its content key and metadata), the content keys of the
    /// others, and other apps' `.xmp` beside it, each read once through the volume's readers. Where the
    /// library has photos of each file's size, the bytes the content keys cover are read first, and
    /// nothing more when the library has them all.
    private func readHead(
        of photo: ImportPhoto, io: VolumeIO, priority: VolumeIO.Priority, keys known: ImportKeys,
    ) async throws -> ReadHead {
        let url = photo.url
        let size = Int(photo.primary.size)
        var keys: [String: ContentKey] = [:]
        var head = Data()
        if photo.photoFiles.allSatisfy({ known.contains(size: $0.size) }) {
            for file in photo.photoFiles {
                let fileURL = URL(fileURLWithPath: photo.folder + "/" + file.name, isDirectory: false)
                let fileHead = try await io.read(fileURL, range: 0 ..< ContentKey.headLength, priority: priority)
                keys[file.name] = ContentKey(fileSize: Int(file.size), head: fileHead)
                if file.name == photo.primary.name {
                    head = fileHead
                }
            }
            if keys.values.allSatisfy(known.contains) {
                return ReadHead(head: head, keys: keys)
            }
        }
        // A preview of a photo that isn't a raw is made from all of it, read at once, but for a large JPEG's.
        let whole = !photo.primary.isRaw && priority == .high && size <= Self.wholeFileRead
            && (!photo.primary.isJPEG || size <= Self.provisionalSize)
        let wanted = whole ? size : PhotoMetadataReader.headLength
        if head.count < wanted, head.count < size {
            try await head.append(io.read(url, range: head.count ..< wanted, priority: priority))
        }
        let read = head
        var xmp: Data?
        if let sidecar = photo.files
            .first(where: { $0.role == .otherApp && NamingJob.split($0.name).ext.lowercased() == "xmp" }) {
            let xmpURL = URL(fileURLWithPath: photo.folder + "/" + sidecar.name, isDirectory: false)
            xmp = try? await io.read(xmpURL, range: 0 ..< max(Int(sidecar.size), 1), priority: priority)
        }
        let xmpData = xmp
        let lane: WorkScheduler.Lane = priority == .high ? .onScreen : .lookAhead
        var parsed = try await scheduler.run(lane) {
            LibraryIndexer.Run.parse(head: read, size: size, url: url, xmp: xmpData)
        }
        if parsed.needsFile {
            let headLength = PhotoMetadataReader.headLength
            if size > headLength {
                _ = try await io.read(
                    url, range: headLength ..< min(size, LibraryIndexer.Run.chargedFileRead), priority: priority,
                )
            }
            parsed.metadata = try await scheduler.run(lane) { PhotoMetadataReader.read(url: url) }
        }
        keys[photo.primary.name] = parsed.key
        for file in photo.photoFiles.dropFirst() where keys[file.name] == nil {
            let fileURL = URL(fileURLWithPath: photo.folder + "/" + file.name, isDirectory: false)
            let fileHead = try await io.read(fileURL, range: 0 ..< ContentKey.headLength, priority: priority)
            keys[file.name] = ContentKey(fileSize: Int(file.size), head: fileHead)
        }
        return ReadHead(head: read, metadata: parsed.metadata, xmp: parsed.xmp, keys: keys)
    }

    // MARK: - Previews

    /// What making a photo's first preview came to.
    private enum Preview: Sendable {
        /// Its grid thumbnail is in the store.
        case made
        /// A small preview to show until its grid thumbnail is made.
        case provisional(Provisional)
        case nothing
    }

    /// Makes the photo's grid thumbnail from the smallest embedded preview that fills a cell, read alone
    /// through the volume's readers: a raw's, or a large JPEG's Multi-Picture Format large thumbnail. A large
    /// JPEG without one gives the thumbnail in its EXIF as a provisional preview instead, when it has one.
    /// Otherwise the thumbnail is made from the whole photo. It's stored under `key`, with the file's size
    /// and date.
    private func preview(
        _ photo: ImportPhoto, key: ContentKey, head: Data, io: VolumeIO, store: PhotoStore,
    ) async throws -> Preview {
        let url = photo.url
        let primary = photo.primary
        let size = Int(primary.size)
        let edge = PhotoStore.Tier.grid.pixelSize
        let orientation = photo.metadata?.orientation
        func stored(_ jpeg: Data, fillingCell: Bool) async throws -> Bool {
            let payload = try await scheduler.run(.onScreen) {
                EmbeddedPreviews.thumbnail(ofJPEG: jpeg, edge: edge, orientation: orientation).flatMap { image in
                    !fillingCell || max(image.width, image.height) >= edge
                        ? StoreImageEncoder().encode(image, for: .grid) : nil
                }
            }
            guard let payload else { return false }
            return store.store(payload, for: key, tier: .grid, size: primary.size, modified: primary.modified)
        }
        if primary.isRaw {
            var bytes = PreviewBytes(head: head, size: size) { range in
                try await io.read(url, range: range, priority: .high)
            }
            if let embedded = try await EmbeddedPreviews.best(in: &bytes, reaching: edge) {
                let jpeg = embedded.range.upperBound <= head.count
                    ? Data(head.dropFirst(embedded.offset).prefix(embedded.length))
                    : try await io.read(url, range: embedded.range, priority: .high)
                if try await stored(jpeg, fillingCell: false) {
                    return .made
                }
            }
        } else if primary.isJPEG, head.count < size {
            let found = EmbeddedPreviews.inJPEG(head, size: size)
            for large in found.large.sorted(by: { $0.length < $1.length })
                where large.length <= Self.largeThumbnailLimit {
                if try await stored(io.read(url, range: large.range, priority: .high), fillingCell: true) {
                    return .made
                }
            }
            if size > Self.provisionalSize, let thumbnail = found.thumbnail, thumbnail.range.upperBound <= head.count {
                let jpeg =
                    Data(head[head.startIndex + thumbnail.offset ..< head.startIndex + thumbnail.range.upperBound])
                return .provisional(Provisional(jpeg: jpeg, orientation: orientation))
            }
        }
        return try await wholePreview(photo, key: key, head: head, io: io, store: store, priority: .high)
            ? .made : .nothing
    }

    /// Makes the photo's grid thumbnail from all of it, `head` and the rest read at `priority`, and stores it as
    /// `preview` does: a JPEG is decoded at a fraction of its size, as ImageIO's thumbnails are; whether it's
    /// stored.
    private func wholePreview(
        _ photo: ImportPhoto, key: ContentKey, head: Data, io: VolumeIO, store: PhotoStore,
        priority: VolumeIO.Priority,
    ) async throws -> Bool {
        let url = photo.url
        let primary = photo.primary
        let size = Int(primary.size)
        guard size <= Self.wholeFileLimit else { return false }
        let edge = PhotoStore.Tier.grid.pixelSize
        var whole = Data(head.prefix(size))
        if whole.count < size {
            try await whole.append(io.read(url, range: whole.count ..< size, priority: priority))
        }
        let file = whole
        let isRaw = primary.isRaw
        let payload = try await scheduler.run(priority == .high ? .onScreen : .lookAhead) {
            let image = isRaw
                ? EmbeddedPreviews.thumbnail(ofRaw: file, edge: edge) : StoreThumbnailMaker.imageIO(url, file, edge)
            return image.flatMap { StoreImageEncoder().encode($0, for: .grid) }
        }
        guard let payload else { return false }
        return store.store(payload, for: key, tier: .grid, size: primary.size, modified: primary.modified)
    }

    // MARK: - Planning and copying

    /// The import of the photos chosen, as `settings` puts them, worked out before anything is copied:
    /// each photo's folders and names, numbered to tell them apart in capture order, at the destination
    /// and the backup, with its files; and what's left and why. Photos not read yet are read first, without
    /// previews; the destinations are listed through `destinationFileSystem`.
    public func plan(
        _ settings: ImportSettings, destinationFileSystem: any LibraryFileSystem = LocalFileSystem(),
        date: Date = Date(),
    ) async throws -> ImportPlan {
        await ensureListed()
        let chosen = state.withLock { $0.photos.values.filter(\.choices.isChosen).map(\.id) }
        await ensureRead(chosen)
        let photos = photos
        let sources = sources
        let others = state.withLock { $0.others.mapValues(\.count) }
        return try await LibraryIndex.offCaller {
            ImportPlanner(settings: settings, fileSystem: destinationFileSystem, date: date)
                .plan(photos, sources: sources, others: others)
        }
    }

    /// What copies this session's plans, reading through the same readers as the browsing.
    public func importer(destinationFileSystem: any LibraryFileSystem = LocalFileSystem()) -> Importer {
        Importer(
            library: library, fileSystem: fileSystem, destinationFileSystem: destinationFileSystem, volumes: volumes,
        )
    }
}
