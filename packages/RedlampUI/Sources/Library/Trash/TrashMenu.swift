import AppKit
import RedlampDesign
import RedlampLibrary

/// A Recently Trashed photo's context menu, in the filmstrip and, after the grid's own items, in the grid
/// (LIB-26): Put Back, for the selection when the photo is in it and for the photo alone when it isn't, and
/// Put Back for every photo of the batch that moved it to the Trash.
@MainActor
enum TrashMenu {
    /// The menu for `photo`; nil for a photo that isn't in Recently Trashed.
    static func menu(for photo: URL, model: EditorModel) -> NSMenu? {
        guard let trashed = model.library.trashedPhoto(at: photo), !model.isModalDialogOpen else { return nil }
        let menu = NSMenu()
        menu.addItem(putBack(photo, count: model.trashedPhotos(for: photo).count, model: model))
        menu.addItem(putBackBatch(photo, trashed: trashed, model: model))
        return menu
    }

    private static func putBack(_ photo: URL, count: Int, model: EditorModel) -> NSMenuItem {
        let title: String = count > 1 ? "Put Back \(count) Photos" : ShortcutAction.putBack.title
        let item = NSMenuItem(title: title) {
            model.putBack(photo)
            model.activity.record(.action, ShortcutAction.putBack.title)
        }
        item.keyEquivalent = "\u{7F}"
        item.keyEquivalentModifierMask = [.command]
        item.setAccessibilityIdentifier("library.menu.putBack")
        return item
    }

    private static func putBackBatch(_ photo: URL, trashed: TrashedPhoto, model: EditorModel) -> NSMenuItem {
        let item = NSMenuItem(title: "Put Back All of “\(trashed.title)”") {
            model.putBackBatch(of: photo)
            model.activity.record(.action, ShortcutAction.putBackBatch.title)
        }
        let when: String = trashed.trashed.formatted(date: .abbreviated, time: .shortened)
        item.toolTip = "Every photo still in the Trash that went there with this one, \(when)"
        item.setAccessibilityIdentifier("library.menu.putBackBatch")
        return item
    }
}
