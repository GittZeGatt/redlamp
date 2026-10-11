import AppKit
import RedlampLibrary

/// A folder's files that can't be read (LIB-40), which its grid shows among its photos, as the Finder shows them, each
/// marked with what's wrong with it (`HealthProposals`). A file's menu says so and offers what Library Health offers
/// for
/// it: the Damaged Files check's batch to the Trash, confirmed in its sheet and taken back by ⌘Z, for the files the
/// check proposes, which leaves out those Redlamp may not read; and the check itself, with the file active. Open in
/// Loupe and Develop and Show in Finder are on every photo's menu.
extension EditorModel {
    /// What `photo`'s menu adds while it's a file of the folder shown that can't be read; nil for any other photo.
    func unreadableMenuItems(for photo: URL) -> [NSMenuItem]? {
        guard librarySources.shown == nil, let mark = healthProposals.mark(for: photo), mark.isInFolder else {
            return nil
        }
        let sentence = mark.sentence.prefix(1).uppercased() + mark.sentence.dropFirst()
        let found = NSMenuItem(
            title: sentence.count > 90 ? sentence.prefix(44) + "…" + sentence.suffix(45) : sentence, action: nil,
            keyEquivalent: "",
        )
        found.isEnabled = false
        found.setAccessibilityIdentifier("library.menu.unreadableFinding")
        let proposed = unreadableActedOn(from: photo).count { !$0.isForbidden }
        let trash = NSMenuItem(title: HealthWords.menuTitle(.damaged, count: max(proposed, 1))) { [weak self] in
            self?.trashUnreadable(photo)
        }
        trash.isEnabled = proposed > 0 && library.service?.isReady == true
        trash.setAccessibilityIdentifier("library.menu.trashUnreadable")
        let show = NSMenuItem(title: "Show in Library Health") { [weak self] in self?.showInLibraryHealth(photo) }
        show.isEnabled = librarySources.canShow(.health(.damaged))
        show.setAccessibilityIdentifier("library.menu.showInLibraryHealth")
        return [found, trash, show]
    }

    /// Move to Trash…: the Damaged Files check's batch for the folder's files that can't be read among `photo`, or the
    /// selection it's in, those the check proposes for the Trash, confirmed in its sheet. The check's findings are
    /// read again first, so the batch keeps its rules: what's rated, flagged or labelled is left out unless the sheet's
    /// box chooses it, and what was kept anyway isn't there.
    @discardableResult
    func trashUnreadable(_ photo: URL) -> Bool {
        let ids = unreadableActedOn(from: photo).filter { !$0.isForbidden }.map(\.finding.photo)
        guard !ids.isEmpty, !isModalDialogOpen, let core = library.service?.core else { return false }
        let requested = ContinuousClock.now
        let health = healthProposals.library(core)
        Task { [weak self] in
            guard let found = try? await health.findings(.damaged) else { return }
            let wanted = Set(ids)
            let chosen = found.findings.filter { wanted.contains($0.photo) }
            guard let self, !chosen.isEmpty else { return }
            let sheet = HealthSheetModel(
                findings: HealthFindings(check: .damaged, findings: chosen),
                selectedApart: chosen.filter { $0.apart != nil }.map(\.photo), health: health, requested: requested,
            )
            HealthSheetController.present(sheet, editor: self, requested: requested)
        }
        return true
    }

    /// Show in Library Health: the Damaged Files check, with `photo` active.
    @discardableResult
    func showInLibraryHealth(_ photo: URL) -> Bool {
        let check = LibrarySource.health(.damaged)
        guard librarySources.canShow(check), librarySources.show(check) else { return false }
        libraryViews.remember(check.key, selection: [], active: photo)
        return true
    }

    /// The marks of the folder's files that can't be read that an action from `photo`'s menu reaches: the selection's
    /// when `photo` is in it, `photo`'s alone when it isn't.
    private func unreadableActedOn(from photo: URL) -> [HealthMark] {
        let alone = photo != selection && library.photoID(of: photo).map(photoSelection.contains) != true
        return (alone ? [photo] : selectedPhotos).compactMap { healthProposals.mark(for: $0) }.filter(\.isInFolder)
    }
}
