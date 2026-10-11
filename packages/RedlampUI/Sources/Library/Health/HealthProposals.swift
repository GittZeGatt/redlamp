import Foundation
import Observation
import RedlampLibrary

/// The proposals of the Library Health check the grid shows (LIB-40): the check's findings as the library has them,
/// read again off the main thread each time the check's list changes, and each photo's mark, which the grid's cells
/// draw and their tooltips and VoiceOver say. The menus follow only what's offered, which a batch or Keep Anyway
/// changes once, not the counts, which change with each part of a batch's photos: SwiftUI asks every item of the menu
/// bar again whenever something its menus read changes.
///
/// A folder shown has marks too: those of its files that can't be read, which its grid shows as the Finder shows
/// them, each saying what's wrong with it and proposing nothing (`HealthMark.init(unreadable:)`). They're read again
/// off the main thread whenever the photos shown change.
@MainActor
@Observable
public final class HealthProposals {
    /// What the menus follow: the check shown, and whether its batch has anything to act on.
    public struct Offer: Equatable, Sendable {
        public var check: HealthCheck.Kind
        /// Its batch acts on something proposed, or on photos listed apart once they're chosen.
        public var canAccept: Bool
        /// Its list has photos.
        public var hasFindings: Bool
    }

    /// The check's findings counted.
    public struct Tally: Equatable, Sendable {
        /// The findings its batch acts on as proposed.
        public var proposed: Int
        /// The findings listed apart, which the batch leaves out unless they're chosen.
        public var apart: Int
        /// The findings in its list.
        public var found: Int
    }

    /// The check shown and what it offers; nil while the grid shows anything else, and until its findings are read.
    public private(set) var offer: Offer?
    /// The check's findings counted, as last read.
    @ObservationIgnored public private(set) var tally: Tally?
    /// The check's findings as last read.
    @ObservationIgnored private(set) var findings: HealthFindings?
    /// Each photo's mark, by the index's ID.
    @ObservationIgnored private var marks: [Int64: HealthMark] = [:]
    @ObservationIgnored private weak var model: EditorModel?
    @ObservationIgnored private var shown: LibrarySource?
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var readAgain = false
    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var health: (core: ObjectIdentifier, health: LibraryHealth)?
    /// Duplicates being read whole to confirm them, and how many were unconfirmed as the last reading started.
    @ObservationIgnored private var confirming: Task<Void, Never>?
    @ObservationIgnored private var confirmedFrom: Int?
    /// How long each reading of the findings took to reach the grid, for the budgets.
    @ObservationIgnored @_spi(Harness) public private(set) var readsTook: [Duration] = []
    /// The folder shown's files that can't be read, each with its mark.
    @ObservationIgnored private var folderMarks = FolderMarks()
    @ObservationIgnored private var readingFolder = false
    @ObservationIgnored private var readFolderAgain = false
    @ObservationIgnored private var libraryObservation: LibraryObservation?

    /// A folder's files that can't be read, each one's mark by the index's ID and by its path, as the folder is shown
    /// from the library or listed from the disk.
    private struct FolderMarks: Sendable, Equatable {
        var byID: [Int64: HealthMark] = [:]
        var byPath: [String: HealthMark] = [:]
    }

    init(model: EditorModel) {
        self.model = model
        libraryObservation = model.library.observe { [weak self] diff in
            guard !diff.onlyReads else { return }
            self?.readFolder()
        }
        readFolder()
    }

    /// The source shown, or its list, changed: a check's findings are read again, and anything else has none.
    func follow(_ source: LibrarySource?) {
        guard case .health? = source else {
            clear()
            return
        }
        if source != shown {
            clear()
            shown = source
        }
        read()
    }

    /// The mark of the photo at `url`, while it's in the check shown, or it's a file of the folder shown that can't be
    /// read.
    func mark(for url: URL) -> HealthMark? {
        if !marks.isEmpty, let id = model?.librarySources.indexID(ofShown: url) {
            return marks[id]
        }
        guard !folderMarks.byPath.isEmpty, let library = model?.library else { return nil }
        if library.showsIndexIDs, let id = library.photoID(of: url) {
            return folderMarks.byID[id]
        }
        return folderMarks.byPath[url.path]
    }

    /// How many of the folder shown's files can't be read, as last read.
    var unreadableInFolder: Int {
        folderMarks.byPath.count
    }

    /// The marks of the photos the index knows as `ids`.
    func marks(of ids: [Int64]) -> [HealthMark] {
        ids.compactMap { marks[$0] }
    }

    /// The kinds of the pairs' halves the check proposes for the Trash, for the batch's words.
    var proposedKinds: Set<PhotoRecord.Kind> {
        Set(findings?.findings.lazy.filter(\.isProposed).compactMap { finding -> PhotoRecord.Kind? in
            guard case let .pairHalf(kind, _) = finding.reason else { return nil }
            return kind
        } ?? [])
    }

    /// Calls `handler` each time the marks change.
    func observe(_ handler: @escaping @MainActor () -> Void) -> LibraryObservation {
        let id = UUID()
        observers[id] = handler
        return LibraryObservation { [weak self] in self?.observers.removeValue(forKey: id) }
    }

    /// Reads whole, at utility priority, the duplicate candidates no recorded hash confirms, `unconfirmed` of them as
    /// the counts last found, so Exact Duplicates lists every group; the counts are read again after. One reading at a
    /// time, and none while the count is the one the last reading started from: candidates that can't be read, on a
    /// volume that's away say, stay unconfirmed until there are others.
    func confirmDuplicates(unconfirmed: Int) {
        guard confirming == nil, unconfirmed > 0, unconfirmed != confirmedFrom, let model,
              let core = model.library.service?.core
        else { return }
        confirmedFrom = unconfirmed
        let health = library(core)
        confirming = Task { [weak self] in
            try? await Task.detached(priority: .utility) { _ = try await health.confirmDuplicates() }.value
            guard let self else { return }
            confirming = nil
            self.model?.librarySources.recount()
        }
    }

    /// Returns once the duplicates being confirmed are, for the regression suite.
    @_spi(Harness) public func confirmed() async {
        await confirming?.value
    }

    /// Library Health for the library open now.
    func library(_ core: LibraryCore) -> LibraryHealth {
        if let health, health.core == ObjectIdentifier(core) {
            return health.health
        }
        let made = LibraryHealth(operations: core.files, engine: core.engine)
        health = (ObjectIdentifier(core), made)
        return made
    }

    /// The check of `kind` as the Library panel has it: pairs under its rule.
    static func check(_ kind: HealthCheck.Kind, pairs rule: PairRule) -> HealthCheck {
        switch kind {
        case .duplicates: .duplicates
        case .pairs: .pairs(rule)
        case .damaged: .damaged
        case .missing: .missing
        case .extensions: .extensions
        }
    }

    /// Whether the findings asked for so far are in.
    @_spi(Harness) public var isReading: Bool {
        reading
    }

    /// How many photos of the check shown have a mark.
    @_spi(Harness) public var marked: Int {
        marks.count
    }

    private func read() {
        guard let model, let core = model.library.service?.core, case let .health(kind)? = shown else { return }
        guard !reading else {
            readAgain = true
            return
        }
        reading = true
        let (health, check, source, started) = (
            library(core), Self.check(kind, pairs: model.librarySources.pairRule), shown, ContinuousClock.now,
        )
        Task { [weak self] in
            let read = await Task.detached(priority: .userInitiated) { () -> Read? in
                guard let found = try? await health.findings(check) else { return nil }
                var marks = [Int64: HealthMark](minimumCapacity: found.findings.count)
                var tally = Tally(proposed: 0, apart: 0, found: found.findings.count)
                for finding in found.findings {
                    marks[finding.photo] = HealthMark(finding)
                    tally.proposed += finding.isProposed ? 1 : 0
                    tally.apart += finding.apart == nil ? 0 : 1
                }
                return Read(findings: found, marks: marks, tally: tally)
            }.value
            guard let self else { return }
            reading = false
            if shown == source, let read {
                apply(read)
                readsTook = readsTook.suffix(99) + [.now - started]
            }
            if readAgain {
                readAgain = false
                self.read()
            }
        }
    }

    /// A check's findings as read, with each photo's mark and their count.
    private struct Read: Sendable {
        var findings: HealthFindings
        var marks: [Int64: HealthMark]
        var tally: Tally
    }

    private func apply(_ read: Read) {
        let replaced = (findings, marks)
        findings = read.findings
        marks = read.marks
        tally = read.tally
        // Tens of thousands of findings and marks take milliseconds to free.
        Task.detached(priority: .utility) { withExtendedLifetime(replaced) {} }
        let tally = read.tally
        let offer = Offer(
            check: read.findings.check.kind, canAccept: tally.proposed > 0 || tally.apart > 0,
            hasFindings: tally.found > 0,
        )
        if offer != self.offer {
            self.offer = offer
        }
        for observer in observers.values {
            observer()
        }
    }

    // MARK: - The folder shown

    /// Reads again which of the folder shown's files can't be read, and what's wrong with each, off the main thread;
    /// none while anything else is shown.
    private func readFolder() {
        guard let library = model?.library, let open = library.openFolder, let core = library.service?.core else {
            return applyFolder(FolderMarks())
        }
        guard !readingFolder else {
            readFolderAgain = true
            return
        }
        readingFolder = true
        let folder = PhotoSource.folder(open, includingSubfolders: library.includesSubfolders)
        let (engine, index) = (core.engine, core.index)
        Task { [weak self] in
            let read = await Task.detached(priority: .userInitiated) {
                await Self.unreadable(in: folder, engine: engine, index: index)
            }.value
            guard let self else { return }
            readingFolder = false
            if let read, let library = model?.library, library.openFolder.map({
                PhotoSource.folder($0, includingSubfolders: library.includesSubfolders)
            }) == folder {
                applyFolder(read)
            }
            if readFolderAgain {
                readFolderAgain = false
                readFolder()
            }
        }
    }

    /// The files of `folder` that can't be read, each marked with what's wrong with it, as the index keeps it; nil
    /// when they couldn't be read.
    private nonisolated static func unreadable(
        in folder: PhotoSource, engine: QueryEngine, index: LibraryIndex,
    ) async -> FolderMarks? {
        guard let ids = try? await Array(engine.list(folder, matching: unreadableQuery).ids) else { return nil }
        guard !ids.isEmpty else { return FolderMarks() }
        return try? await index.read { reader in
            let health = try reader.photoHealth(ids)
            var marks = FolderMarks()
            var folders: [Int64: String] = [:]
            for id in ids {
                guard let photo = try reader.photo(id: id) else { continue }
                if folders[photo.folder] == nil {
                    folders[photo.folder] = try reader.folder(id: photo.folder)?.path
                }
                guard let path = folders[photo.folder] else { continue }
                let damage = health[id]?.damage ?? .unreadable("")
                let mark = HealthMark(unreadable: HealthFinding(photo: id, check: .damaged, reason: .damage(damage)))
                marks.byID[id] = mark
                marks.byPath[URL(fileURLWithPath: path + "/" + photo.name, isDirectory: false).path] = mark
            }
            return marks
        }
    }

    private func applyFolder(_ read: FolderMarks) {
        guard read != folderMarks else { return }
        let replaced = folderMarks
        folderMarks = read
        Task.detached(priority: .utility) { withExtendedLifetime(replaced) {} }
        for observer in observers.values {
            observer()
        }
    }

    private static let unreadableQuery = LibraryQuery.filter(LibraryQuery.Filter(.unreadable, .equal, [.bool(true)]))

    private func clear() {
        shown = nil
        readAgain = false
        findings = nil
        tally = nil
        if offer != nil {
            offer = nil
        }
        guard !marks.isEmpty else { return }
        let replaced = marks
        marks = [:]
        Task.detached(priority: .utility) { withExtendedLifetime(replaced) {} }
        for observer in observers.values {
            observer()
        }
    }
}

public extension EditorModel {
    /// The proposals of the Library Health check the grid shows.
    var healthProposals: HealthProposals {
        if let proposals = Self.healthProposals.object(forKey: self) {
            return proposals
        }
        let proposals = HealthProposals(model: self)
        Self.healthProposals.setObject(proposals, forKey: self)
        return proposals
    }

    private static let healthProposals = NSMapTable<EditorModel, HealthProposals>.weakToStrongObjects()
}
