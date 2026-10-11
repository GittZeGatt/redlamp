import AppKit
import RedlampLibrary

/// A press on a photo in the filmstrip, which a drag takes along.
struct FilmstripPress {
    /// Where it was pressed, in the strip.
    let point: CGPoint
    let url: URL
    /// Released without a drag, it selects the photo alone.
    let selectsOnRelease: Bool
}

/// The filmstrip's drags (LIB-28), as the grid's (`LibraryGridView+Drag`, `LibraryGridView+StackDrop`): a press on a
/// photo that moves a few points drags the selection when the photo is in it, else the photo alone, as Library's
/// dragging session (`LibraryDrags`), which the folders, the collections and the grid take as they take the grid's.
/// Over another photo of the same open burst or stack made by hand in the strip, that photo is ringed, and the drop
/// moves the photos dragged to its place (`EditorModel.movePhotos(_:inStackTo:)`), one change ⌘Z takes back.
extension FilmstripStripView: NSDraggingSource, LibraryDragSource {
    /// A press on `url`'s cell: a click, unless it's on a photo of several selected, whose selection stays for a drag
    /// and which a release without one selects alone.
    func pressed(_ event: NSEvent, on url: URL) {
        press = nil
        let point = convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags
        if flags.isDisjoint(with: [.command, .shift]), model.isMultiSelecting,
           model.library.photoID(of: url).map(model.photoSelection.contains) == true {
            press = FilmstripPress(point: point, url: url, selectsOnRelease: true)
        } else {
            click(url, holding: flags)
            press = FilmstripPress(point: point, url: url, selectsOnRelease: false)
        }
    }

    /// A click on `url`'s cell holding `modifiers`, as the grid takes one: ⌘ adds or removes the photo, ⇧ extends the
    /// selection to it in the grid's order.
    func click(_ url: URL, holding modifiers: NSEvent.ModifierFlags) {
        model.clickInGrid(url, toggling: modifiers.contains(.command), extending: modifiers.contains(.shift))
    }

    /// The press moved: past the grid's drag distance, its drag begins.
    func dragged(_ event: NSEvent) {
        guard !LibraryDrags.follow(event), let press else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - press.point.x, point.y - press.point.y) >= LibraryGridView.dragDistance else { return }
        self.press = nil
        beginDrag(press, event: event)
    }

    /// The press ended without a drag.
    func released(_ event: NSEvent) {
        guard !LibraryDrags.follow(event), let press else { return }
        self.press = nil
        if press.selectsOnRelease {
            model.clickInGrid(press.url)
        }
    }

    private func beginDrag(_ press: FilmstripPress, event: NSEvent) {
        let library = model.library
        let selection = model.photoSelection
        let fromLibrary = library.service?.isReady == true && !library.showsRecentlyTrashed && !model.showsMissingPhotos
        let photos = selection.count > 1 && library.photoID(of: press.url).map(selection.contains) == true
            ? DraggedPhotos(
                selection: selection, items: library.items, ids: library.photoIDs, source: library.rowSource,
                fromLibrary: fromLibrary,
            )
            : DraggedPhotos(photo: press.url, fromLibrary: fromLibrary)
        let pasteboard = NSPasteboardItem()
        pasteboard.setString(photos.token, forType: LibraryDrags.photos)
        let item = NSDraggingItem(pasteboardWriter: pasteboard)
        let cell = cell(showing: press.url)
        let frame = cell.map { convert($0.bounds, from: $0) }
            ?? CGRect(origin: press.point, size: FilmstripCellView.size)
        item.setDraggingFrame(frame, contents: LibraryDrags.image(cell?.image, size: frame.size, count: photos.count))
        LibraryDrags.begin(item, event: event, from: self, mask: LibraryGridContentView.photoOperations, photos: photos)
    }

    func draggingSession(_: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? LibraryGridContentView.photoOperations : []
    }

    func draggingSession(_: NSDraggingSession, endedAt _: NSPoint, operation _: NSDragOperation) {
        libraryDragEnded()
        LibraryDrags.ended()
    }

    func libraryDragEnded() {
        press = nil
    }

    // MARK: - Photos dropped in their stack

    /// What a drag over the strip would do there: move photos in their open stack, or nothing.
    func dropOperation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let operation = [NSDragOperation.move, .generic].first { sender.draggingSourceOperationMask.contains($0) }
        guard let operation, let target = stackMove(sender)?.target else {
            showDropTarget(nil)
            return []
        }
        showDropTarget(target)
        return operation
    }

    /// The drop: photos moved to the place of the photo under it in their open stack.
    func dropped(_ sender: any NSDraggingInfo) -> Bool {
        defer { showDropTarget(nil) }
        guard let (photos, target) = stackMove(sender) else { return false }
        return model.movePhotos(photos, inStackTo: target)
    }

    /// The photos a drag carries, by their IDs here, and the photo under it whose place they'd take, when they'd move
    /// in their open stack there.
    private func stackMove(_ sender: any NSDraggingInfo) -> (photos: [Int64], target: Int64)? {
        guard let dragged = LibraryDrags.photos(in: sender), dragged.fromLibrary else { return nil }
        let library = model.library
        let point = collectionView.convert(sender.draggingLocation, from: nil)
        // The photos a drag of thousands carries are listed only over a stack that could hold them.
        guard let index = collectionView.indexPathForItem(at: point)?.item, let row = row(ofItem: index),
              library.photoIDs.indices.contains(row), let size = model.openStackSize(of: library.photoIDs[row]),
              dragged.count < size
        else { return nil }
        let target = library.photoIDs[row]
        let photos: [Int64] = if dragged.count == 1 {
            dragged.listed?.urls.first.flatMap(library.photoID(of:)).map { [$0] } ?? []
        } else {
            Array(model.photoSelection.ids(in: library.photoList))
        }
        guard model.canMovePhotos(photos, inStackTo: target) else { return nil }
        return (photos, target)
    }

    /// Rings the cell of `target`, the photo a drop would move photos to the place of, or none.
    func showDropTarget(_ target: Int64?) {
        guard target != dropTarget else { return }
        dropTarget = target
        if target != nil {
            LibraryDrags.outlined += 1
        }
        let library = model.library
        for case let cell as FilmstripCellView in collectionView.subviews {
            cell.isDropTarget = target != nil && cell.item.flatMap { library.photoID(of: $0.url) } == target
        }
    }

    /// The cell on screen showing `url`'s photo.
    private func cell(showing url: URL) -> FilmstripCellView? {
        collectionView.subviews.lazy.compactMap { $0 as? FilmstripCellView }.first { $0.item?.url == url }
    }
}
