import Foundation
import RedlampLibrary

/// The source shown at quit, reopened at launch (LIB-23): the Library panel's entry, a Library Health check or a
/// place in the collection list, kept as it's shown and as it closes, with the module it was left in. As the library
/// closes at quit, the view of the source or the folder shown is kept too, so launch reopens either with its
/// selection, its active photo and its place in the grid (`EditorModel+SourceViews`), and with its filter, which the
/// filter bar keeps for each source.
///
/// Launch waits for the library alone, which the source's photos come from: not for the folders' bookmarks, the
/// counts or indexing. A source that's gone (a collection deleted, an entry or a check with no photos left, no previous
/// import) gives way to the folder launch opens without one, and so does a library that doesn't open.
extension LibrarySources {
    /// The key of the source shown (`LibrarySource.key`), while one is.
    static let shownKey = "library.sources.shown"
    /// The module the source shown was left in at quit.
    static let moduleKey = "library.sources.module"

    /// Keeps which source is shown, or that none is, for the next launch.
    func keepShown() {
        guard let defaults = model?.library.defaults else { return }
        if let shown {
            defaults.set(shown.key, forKey: Self.shownKey)
        } else {
            defaults.removeObject(forKey: Self.shownKey)
        }
        defaults.removeObject(forKey: Self.moduleKey)
    }

    /// As the library closes at quit: the view of the source or the folder shown, and the module a source was left in.
    func libraryClosing() {
        guard let model, launch == nil else { return }
        if let shown {
            model.rememberView(of: shown)
            model.library.defaults?.set(model.module.rawValue, forKey: Self.moduleKey)
        } else {
            model.rememberSourceView()
        }
    }

    /// Starts reopening the source shown at quit, once the library is open. What the reopening is told to open
    /// otherwise (`LaunchReopening.otherwise`) opens at once when no source was shown or the library is off, and later
    /// when the source is gone or the library doesn't open.
    func reopenAtLaunch() -> LaunchReopening {
        guard let library = model?.library,
              let source = library.defaults?.string(forKey: Self.shownKey).flatMap(LibrarySource.init(key:)),
              let service = library.service
        else { return LaunchReopening(nil) }
        let module = library.defaults?.string(forKey: Self.moduleKey).flatMap(AppModule.init(rawValue:)) ?? .library
        let reopening = LaunchReopening(source, module: module, generation: library.generation)
        launch = reopening
        service.whenOpened { [weak self] in self?.libraryOpened(for: reopening) }
        return reopening
    }

    /// Whether a launch is still reopening the source shown at quit.
    @_spi(Harness) public var isReopening: Bool {
        launch != nil
    }

    /// The library opened, or couldn't: what showing the source needs is looked up off the main thread, then it's
    /// shown, unless something else was opened meanwhile.
    private func libraryOpened(for reopening: LaunchReopening) {
        guard launch === reopening, let source = reopening.source else { return }
        guard let core = model?.library.service?.core else { return fallBack(reopening) }
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { await Self.lookUp(source, core: core) }.value
            guard let self, launch === reopening, let model else { return }
            guard model.library.generation == reopening.generation else {
                launch = nil
                return reopening.abandon()
            }
            guard let found else { return fallBack(reopening) }
            if case let .previousImport(previous, stamp, photos) = found {
                knowPreviousImport(previous, stamp: stamp, photos: photos)
            }
            if shown != source, !show(source) {
                fallBack(reopening)
            }
        }
    }

    /// Launch opens what it opens without a source shown at quit.
    func fallBack(_ reopening: LaunchReopening) {
        launch = nil
        model?.library.defaults?.removeObject(forKey: Self.shownKey)
        reopening.finish(reopened: false)
    }

    /// What showing a source at launch needs to know first.
    enum LookedUp: Sendable {
        case found
        /// The previous import, the journal's files as they were found, and its photos the library has and can read.
        case previousImport(PreviousImport, stamp: [String], photos: [Int64])
    }

    /// Whether `source` is still there, with Previous Import's photos; nil when it's gone. An entry or a check is
    /// judged by its first photos instead (`LaunchReopening.keeps`).
    nonisolated static func lookUp(_ source: LibrarySource, core: LibraryCore) async -> LookedUp? {
        switch source {
        case let .collection(path):
            let list = try? await LibraryMetadata(index: core.index, paths: core.paths).collections.list()
            return list?.collections[path] == nil ? nil : .found
        case .previousImport:
            let journal = ImportJournal(paths: core.paths)
            let stamp = stamp(of: journal.folder)
            guard let previous = try? journal.previousImport(),
                  let photos = try? await LibraryCounts.photos(of: previous, core: core), !photos.isEmpty
            else { return nil }
            return .previousImport(previous, stamp: stamp, photos: photos)
        default:
            return .found
        }
    }
}

/// A launch reopening the source shown at quit (`LibrarySources.reopenAtLaunch`), and what launch opens if it isn't.
@MainActor
final class LaunchReopening {
    enum State {
        case reopening, reopened, fellBack
        /// Something else was opened meanwhile.
        case abandoned
    }

    /// The source shown at quit; nil when none was.
    let source: LibrarySource?
    /// The module it was left in.
    let module: AppModule
    /// The library's opening as launch began (`FolderLibrary.generation`): any other opening since replaces it.
    let generation: Int
    private(set) var state: State
    private var otherwise: (@MainActor () -> Void)?

    init(_ source: LibrarySource?, module: AppModule = .library, generation: Int = 0) {
        self.source = source
        self.module = module
        self.generation = generation
        state = source == nil ? .fellBack : .reopening
    }

    /// Opens what `open` opens unless the source is reopened: at once when there's none or it couldn't be, otherwise
    /// once that's known.
    func otherwise(_ open: @escaping @MainActor () -> Void) {
        switch state {
        case .reopening: otherwise = open
        case .fellBack: open()
        case .reopened, .abandoned: break
        }
    }

    /// Whether the source's first photos show it's still there: a place in the collection list is, empty or not, and an
    /// entry or a check is while it holds photos, as the Library panel offers them.
    func keeps(_ change: LibrarySourceList.Change) -> Bool {
        if case .collection = source {
            return true
        }
        return change.total > 0
    }

    func finish(reopened: Bool) {
        guard state == .reopening else { return }
        state = reopened ? .reopened : .fellBack
        let open = otherwise
        otherwise = nil
        if !reopened {
            open?()
        }
    }

    /// Neither the source nor what launch opens without it opens: something else was opened meanwhile.
    func abandon() {
        guard state == .reopening else { return }
        state = .abandoned
        otherwise = nil
    }
}
