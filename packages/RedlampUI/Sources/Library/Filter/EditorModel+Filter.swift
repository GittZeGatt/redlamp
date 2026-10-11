import Foundation
import RedlampLibrary

/// The filter bar's actions (LIB-18): showing its rows (`\`), turning the filter on and off (⌘L), the lock,
/// the sorts, and searching All Photographs (DEC-67), by key, from the menus and the palette as from the bar itself.
public extension EditorModel {
    /// The filter bar, when the library is on.
    var libraryFilters: LibraryFilters? {
        library.filters
    }

    /// `\`: the rows open from the bar's search field shown or hidden; shown, the field takes the keyboard.
    func toggleFilterBar() {
        guard let filters = libraryFilters else { return }
        filters.setBarShown(!filters.isBarShown)
        if filters.isBarShown {
            showLibrary(.grid)
            followSource()
        }
    }

    /// A filter that left the active photo out makes another active: one of the photos still selected,
    /// or the one that took its place.
    func keepActivePhotoShown() {
        guard let selection, library.index(of: selection) == nil, !items.isEmpty else { return }
        guard let active = photoSelection.active, library.photoList.contains(active) else {
            return selectRow(min(selectionIndex ?? 0, items.count - 1))
        }
        library.whenRead([active]) { [weak self] in
            guard let self, let kept = library.url(ofPhoto: active) else { return }
            select(kept, keepingSelection: true)
        }
    }

    /// The source shown, in the bar: the open folder, or the Library panel's entry or the collection shown.
    func followSource() {
        guard let filters = libraryFilters else { return }
        if let shown = library.shownSource, let photos = library.shownSourcePhotos {
            filters.follow(shown, photos: photos)
        } else {
            filters.follow(folder, includingSubfolders: library.includesSubfolders)
        }
    }

    /// Search All (DEC-67): All Photographs in the grid, filtered by the bar's query, or by `text` in its place, as
    /// the command palette searches everything from anywhere.
    func searchAllPhotographs(_ text: String? = nil) {
        guard let filters = libraryFilters else { return }
        var carried = filters.filter
        if let text {
            carried.text = text
        }
        carried.isEnabled = true
        filters.carry(carried, to: LibrarySource.allPhotographs.key)
        guard library.shownSource == .allPhotographs || librarySources.show(.allPhotographs) else { return }
        showLibrary(.grid)
    }

    func sort(by field: LibrarySortField) {
        guard let filters = libraryFilters else { return }
        followSource()
        filters.setSort(LibrarySort(field, ascending: filters.sort.field == field ? filters.sort.ascending : true))
    }

    func reverseSort() {
        guard let filters = libraryFilters else { return }
        followSource()
        filters.setSort(LibrarySort(filters.sort.field, ascending: !filters.sort.ascending))
    }
}

public extension ShortcutAction {
    /// The sort a Sort by action chooses.
    var sortField: LibrarySortField? {
        switch self {
        case .sortByFolder: .folder
        case .sortByCaptureTime: .captured
        case .sortByName: .name
        case .sortByRating: .rating
        case .sortByEditTime: .edited
        case .sortByModified: .modified
        case .sortByFileSize: .size
        default: nil
        }
    }
}

extension EditorModel {
    /// Whether a source is shown that the bar filters: a folder, or the Library panel's entry or a collection.
    var hasFilterSource: Bool {
        folder != nil || library.shownSource != nil
    }

    /// The filter bar's actions; nil for every other.
    func performFilterShortcut(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .toggleFilterBar, .toggleFilters, .lockFilters, .reverseSort: break
        default:
            guard action.sortField != nil else { return nil }
        }
        guard let filters = libraryFilters, hasFilterSource else { return false }
        followSource()
        switch action {
        case .toggleFilterBar: toggleFilterBar()
        case .toggleFilters: filters.setEnabled(!filters.filter.isEnabled)
        case .lockFilters: filters.setLocked(!filters.isLocked)
        case .reverseSort: reverseSort()
        default:
            if let field = action.sortField {
                sort(by: field)
            }
        }
        return true
    }

    /// Whether `performFilterShortcut` would do something now; nil for the actions it leaves alone.
    func canPerformFilterShortcut(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .toggleFilterBar, .toggleFilters, .lockFilters, .reverseSort: break
        default:
            guard action.sortField != nil else { return nil }
        }
        return libraryFilters != nil && hasFilterSource
    }
}
