import AppKit
import Foundation
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// A folder's files that can't be read (LIB-40): in its grid among its photos, as the Finder shows them, each marked
/// with what's wrong with it; counted in Folders and in the folder's summary; and with what Library Health offers for
/// them in their menu. Other lists still leave them out.
@MainActor
struct UnreadableInFolderTests {
    /// Two photos and a file Redlamp may not read in Shoot, the folder shown once the library has read them all.
    private static func shoot(_ sandbox: SourcesSandbox) async throws -> EditorModel {
        try sandbox.photos(["Shoot/A.JPG", "Shoot/B.JPG", "Shoot/Locked.JPG"])
        let locked = sandbox.photo("Shoot/Locked.JPG")
        // A file written in the last minute may still be being written, and isn't listed as damaged yet.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-600), .posixPermissions: 0], ofItemAtPath: locked.path,
        )
        let model = try await sandbox.open()
        let core = try #require(sandbox.service?.core)
        let unreadable = try LibraryQuery(parsing: "unreadable:yes")
        try await SourcesSandbox
            .eventually { try await core.engine.list(.allPhotographs, matching: unreadable).count == 1 }
        model.showFolder(sandbox.folder("Shoot"))
        try await sandbox.eventually { model.library.isShownFromLibrary && model.items.count == 3 }
        try await sandbox.eventually { model.healthProposals.mark(for: locked) != nil }
        return model
    }

    private static func unlock(_ sandbox: SourcesSandbox) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: sandbox.photo("Shoot/Locked.JPG").path,
        )
    }

    @Test func `a folder's file that can't be read is in its grid, marked with what's wrong, and Folders counts it`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer {
            Self.unlock(sandbox)
            sandbox.remove()
        }
        let model = try await Self.shoot(sandbox)
        let locked = sandbox.photo("Shoot/Locked.JPG")
        #expect(model.items.map(\.name) == ["A.JPG", "B.JPG", "Locked.JPG"])
        let mark = try #require(model.healthProposals.mark(for: locked))
        #expect(mark.word == "No Access" && mark.isInFolder && !mark.isFramed && mark.proposal == .none)
        #expect(mark.sentence == "can't be read: \(String(cString: strerror(EACCES)))")
        #expect(model.healthProposals.mark(for: sandbox.photo("Shoot/A.JPG")) == nil, "a photo that reads has none")
        #expect(model.healthProposals.unreadableInFolder == 1)
        try await sandbox.eventually { model.library.photoCount(of: sandbox.folder("Shoot")) == 3 }
        #expect(model.library.photoCount(of: sandbox.folder("Shoot")) == 3, "Folders counts what the grid shows")

        try await sandbox.counts { $0.count(of: .allPhotographs) == 2 }
        #expect(model.librarySources.count(of: .allPhotographs) == 2, "All Photographs still leaves it out")
        #expect(model.librarySources.show(.allPhotographs))
        try await sandbox.eventually { !model.librarySources.isListing && model.items.count == 2 }
        #expect(model.healthProposals.mark(for: locked) == nil && model.healthProposals.unreadableInFolder == 0)
        model.showFolder(sandbox.folder("Shoot"))
        try await sandbox.eventually { model.items.count == 3 && model.healthProposals.mark(for: locked) != nil }
        #expect(model.healthProposals.mark(for: locked)?.word == "No Access", "marked again as the folder is shown")
    }

    @Test func `its menu says what's wrong and offers Library Health for it, and nothing to the Trash it may not read`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer {
            Self.unlock(sandbox)
            sandbox.remove()
        }
        let model = try await Self.shoot(sandbox)
        let locked = sandbox.photo("Shoot/Locked.JPG")
        try await sandbox.counts { $0.count(of: .health(.damaged)) == 1 }
        @MainActor func item(_ identifier: String, in menu: NSMenu) -> NSMenuItem? {
            menu.items.first { $0.accessibilityIdentifier() == identifier }
        }
        let menu = LibraryGridMenu.menu(for: locked, model: model)
        let found = try #require(item("library.menu.unreadableFinding", in: menu))
        #expect(found.title == "Can't be read: \(String(cString: strerror(EACCES)))" && !found.isEnabled)
        let trash = try #require(item("library.menu.trashUnreadable", in: menu))
        #expect(trash.title == "Move 1 Damaged File to the Trash…" && !trash.isEnabled, "proposed for nothing")
        #expect(!model.trashUnreadable(locked))
        let show = try #require(item("library.menu.showInLibraryHealth", in: menu))
        #expect(show.isEnabled)
        #expect(menu.items.contains { $0.title == ShortcutAction.showInFinder.title })
        #expect(menu.items.contains { $0.title.hasPrefix("Open in Loupe") })
        let readable = LibraryGridMenu.menu(for: sandbox.photo("Shoot/A.JPG"), model: model)
        #expect(item("library.menu.unreadableFinding", in: readable) == nil, "a photo that reads offers none of it")

        try NSApplication.shared.sendAction(#require(show.action), to: show.target, from: show)
        try await sandbox.eventually { model.librarySources.shown == .health(.damaged) && model.selection == locked }
        #expect(model.librarySources.shown == .health(.damaged))
        #expect(model.selection == locked, "Damaged Files shown with the file active")
    }

    @Test func `a folder's summary says how many of its files can't be read, and All Photographs' none`() async throws {
        let sandbox = SourcesSandbox()
        defer {
            Self.unlock(sandbox)
            sandbox.remove()
        }
        let model = try await Self.shoot(sandbox)
        let service = try #require(model.library.service)
        let shoot = PhotoSource.folder(sandbox.folder("Shoot"), includingSubfolders: true)
        #expect(await service.unreadableCount(in: shoot) == 1)
        #expect(await service.unreadableCount(in: .allPhotographs) == 0)
        #expect(await service.unreadableCount(in: .health(.damaged)) == 1)
        let summary = try #require(await service.summary(of: shoot))
        let lines = SourceSummaryText.lines(summary, unreadable: 1)
        #expect(lines.prefix(2) == ["3 photos", "1 file can't be read"], "\(lines)")
        #expect(!SourceSummaryText.lines(summary).contains { $0.contains("can't be read") })
    }
}
