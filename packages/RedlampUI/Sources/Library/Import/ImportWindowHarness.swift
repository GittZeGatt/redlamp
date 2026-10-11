import AppKit
@_spi(Harness) import RedlampLibrary

/// What the regression suite reads and sets in the import window: what a person sets through its
/// panels, which can't be driven, and what it shows.
@_spi(Harness) public extension ImportWindowController {
    /// The destination, the backup and the templates, as the panels and fields would set them.
    func prepare(destination: URL, backup: URL?, folders: String, names: String) {
        model.setDestination(destination)
        model.setBackup(backup)
        model.setFolders(folders)
        model.setNames(names)
    }

    /// Add Folder…'s folder.
    func add(folder: URL) async throws {
        try await model.addFolder(folder)
    }

    /// The card at `root`, its photos in `DCIM`, as the Mac would describe a card in a reader, shown.
    func add(card root: URL) async throws {
        let source = try await Task.detached(priority: .userInitiated) {
            try ImportSource.at(root, medium: .card(at: root))
        }.value
        model.add(source)
        model.show(source.id)
    }

    /// The photos the grid shows.
    var photoCount: Int {
        model.photos.count
    }

    /// Every source is listed, and each of its photos read.
    var isBrowsed: Bool {
        !model.sources.isEmpty && model.sources.allSatisfy(\.isBrowsed)
    }

    /// Previews put on screen in the grid so far.
    var imagesShown: Int {
        grid.imagesShown
    }

    /// Provisional previews put on screen in the grid so far: large JPEGs' EXIF thumbnails.
    var provisionalShown: Int {
        grid.provisionalShown
    }

    /// The photos shown whose grid thumbnails are made, and those still shown from a provisional preview.
    var previewed: (made: Int, provisional: Int) {
        (model.photos.count { $0.state == .previewed }, model.photos.count { $0.state == .provisional })
    }

    /// The grid's cells on screen.
    var visibleCount: Int {
        grid.collectionView.indexPathsForVisibleItems().count
    }

    /// The library's metadata presets the window offers, and the one chosen.
    var presetNames: [String] {
        model.metadataPresets.map(\.name)
    }

    var presetChosen: String? {
        model.preset?.name
    }

    /// The names of the photos given `rating` stars.
    func ratedNames(rating: Int) -> [String] {
        model.photos.filter { $0.choices.rating == rating }.map(\.primary.name)
    }

    /// Cancel Import.
    func stop() {
        model.cancel()
    }

    /// Stops the next import once `photos` photos are done, as a forced quit would, leaving it to be resumed or
    /// rolled back by the next window.
    func simulateForcedQuit(afterPhotos photos: Int) {
        model.importer.simulateForcedQuit(afterPhotos: photos)
    }

    /// An import a forced quit cut short, or a rollback, waits for Resume.
    var isInterrupted: Bool {
        !model.interrupted.isEmpty
    }

    /// Roll Back is offered.
    var canRollBack: Bool {
        model.rollBackTarget != nil && !model.isBusy
    }

    /// What the last rollback did: photos taken back, whether it's over, and where each file went in the Trash.
    var rollbackResult: (rolledBack: Int, isOver: Bool, trashed: [String])? {
        model.rollback.map { ($0.rolledBack.count, $0.state == .rolledBack, $0.trashed.map(\.to)) }
    }

    /// Selects the photos at these places in the grid, and gives the grid the keys.
    func select(_ items: [Int]) {
        grid.collectionView.selectionIndexPaths = Set(items.compactMap(grid.path(of:)))
        window?.makeFirstResponder(grid.collectionView)
    }

    /// The groups the grid shows, by their names, each with its photos' names; one without a name when it isn't
    /// grouped.
    var groups: [(name: String, photos: [String])] {
        model.groups.map { group in (group.name, model.photos[group.places].map(\.primary.name)) }
    }

    /// Group By, as it groups the photos shown.
    var grouping: String {
        model.grouping.title
    }

    /// The rating, flag and label given the photo at `item`, as the grid's badges write them.
    func badges(at item: Int) -> String? {
        model.photo(at: item).map { ImportGridCell.badges($0, leftOut: false, copied: false) }
    }

    func scroll(to fraction: Double) {
        grid.scroll(to: fraction)
    }

    var isCopying: Bool {
        model.phase == .copying && model.progress != nil
    }

    var isFinished: Bool {
        model.phase == .finished
    }

    /// What the import did: photos verified, and whether every source can be erased.
    var result: (verified: Int, safeToErase: Bool)? {
        model.outcome.map { ($0.verified, $0.isSafeToErase) }
    }

    var summary: String {
        model.summary
    }

    /// Takes the folder holding `url` out of Folders, as the scenarios leave Folders as they found it.
    static func forget(_ url: URL, in editor: EditorModel) {
        if let root = editor.library.root(containing: url) {
            editor.library.remove(root)
        }
    }
}
