import AppKit
import Foundation
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// Photos with edits and metadata in both places in Move Edits and Metadata… (DEC-63, LIB-11): the sheet says the move
/// keeps the copy saved last and sets the other aside, rather than refusing; the move settles them, the sheet staying
/// up
/// to say how many and offer the copies it set aside, which it shows in Finder, as it shows those earlier moves set
/// aside.
@MainActor
struct MoveEditsSettleTests {
    typealias Folder = MoveEditsTests.Folder

    /// Saves, for each of `photos`, a sidecar on this Mac rated as given and saved `age` seconds ago, the root keeping
    /// its sidecars beside its photos after.
    static func saveOnThisMac(_ photos: [(name: String, rating: Int, age: TimeInterval)], in folder: Folder)
        async throws {
        let sidecars = try folder.core.sidecars
        let id = try await folder.record().id
        try await sidecars.setPlacement(.onThisMac, forRoot: id)
        let store = try await SidecarStore(locator: sidecars.locator())
        for photo in photos {
            var recipe = EditRecipe()
            recipe[.exposure] = Double(photo.rating) / 10
            try store.save(
                Sidecar(
                    recipe: recipe, metadata: PhotoMetadata(rating: photo.rating),
                    modified: Date(timeIntervalSinceNow: -photo.age),
                ),
                for: folder.photo(photo.name),
            )
        }
        try await sidecars.setPlacement(.besidePhotos, forRoot: id)
    }

    /// Each of `names`' sidecars on this Mac, as the library's locator places them now.
    static func onThisMac(_ names: [String], in folder: Folder) async throws -> [String: [String: Data]] {
        let locator = try await folder.core.sidecars.locator()
        return names.reduce(into: [:]) { found, name in
            found[name] = locator.onThisMac(folder.photo(name)).flatMap(Folder.files)
        }
    }

    @Test func `the move settles photos with edits and metadata in both places, and the sheet says so`() async throws {
        let folder = Folder()
        defer { folder.cleanUp() }
        try folder.write(["A.JPG", "B.JPG", "C.JPG", "D.JPG"], edited: ["A.JPG", "B.JPG", "C.JPG"])
        try await folder.open()
        // B saved later on this Mac than beside it, C earlier.
        try await Self.saveOnThisMac([("B.JPG", 5, -3600), ("C.JPG", 1, 86400)], in: folder)
        let beside = folder.beside(["B.JPG", "C.JPG"])
        let onThisMac = try await Self.onThisMac(["B.JPG", "C.JPG"], in: folder)
        #expect(beside.count == 2 && onThisMac.count == 2)

        let sheet = try await folder.sheet()
        #expect(sheet.conflicts.map(\.photo) == ["B.JPG", "C.JPG"] && sheet.canMove && !sheet.statusIsProblem)
        #expect(sheet.count == "3 photos have edits or metadata beside the photos.")
        #expect(sheet.status == "2 photos have edits and metadata in both places: B.JPG, C.JPG. Moving keeps the "
            + "copy saved last, which Redlamp reads, and sets the other aside.")
        #expect(sheet.setAside == nil, "no move has set any aside yet")

        let model = try #require(folder.model)
        #expect(await !model.moveEdits(sheet), "the sheet stays up to say what it settled")
        #expect(sheet.phase == .settled(
            "Moved 2 photos' edits and metadata to Redlamp on this Mac. 2 photos had edits and metadata in both "
                + "places: the copy saved last was kept in Redlamp on this Mac, and the other set aside.",
        ))
        #expect(sheet.isOver && !sheet.statusIsProblem)
        let aside = try #require(sheet.setAside)
        #expect(aside.deletingLastPathComponent() == folder.paths.setAsideEdits)
        #expect(Folder.files(aside.appending(path: "B.JPG.redlamp")) == beside["B.JPG"], "B's copy beside it")
        #expect(Folder.files(aside.appending(path: "C.JPG.redlamp")) == onThisMac["C.JPG"], "C's copy on this Mac")
        let kept = try await Self.onThisMac(["B.JPG", "C.JPG"], in: folder)
        #expect(kept["B.JPG"] == onThisMac["B.JPG"], "B's copy on this Mac kept")
        #expect(kept["C.JPG"] == beside["C.JPG"], "C's copy beside it kept")
        #expect(folder.beside(["A.JPG", "B.JPG", "C.JPG"]).isEmpty)
        let store = folder.library.sidecars.store(for: folder.photo("B.JPG"))
        #expect(store.load(for: folder.photo("B.JPG"))?.metadata?.rating == 5, "read as before")
        #expect(model.activity.events.contains { event in
            event.text.hasPrefix("Move Edits and Metadata of Photos settled ")
                && event.text.hasSuffix("the other set aside in \(aside.path)")
        })
        #expect(try await folder.core.sidecars.census(ofRoot: folder.record().id).both == 0)
    }

    @Test func `Show Set-Aside Edits shows the move's copies in Finder, and a later sheet shows all of them`(
    ) async throws {
        _ = NSApplication.shared
        let folder = Folder()
        defer { folder.cleanUp() }
        try folder.write(["A.JPG", "B.JPG"], edited: ["A.JPG", "B.JPG"])
        try await folder.open()
        try await Self.saveOnThisMac([("B.JPG", 4, -3600)], in: folder)
        let sheet = try await folder.sheet()
        let controller = MoveEditsSheetController(model: sheet, editor: folder.model, requested: .now)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: MoveEditsSheetController.width, height: 300), styleMask: [.titled],
            backing: .buffered, defer: false,
        )
        window.contentViewController = controller
        window.layoutIfNeeded()
        func button() -> NSButton? {
            func views(in view: NSView) -> [NSView] {
                [view] + view.subviews.flatMap(views)
            }
            return views(in: controller.view).compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == "moveEdits.showSetAside" }
        }
        #expect(button()?.isHidden == true)

        let shown = SetAsideEdits.reveal
        defer { SetAsideEdits.reveal = shown }
        var revealed: [[URL]] = []
        SetAsideEdits.reveal = { revealed.append($0) }
        #expect(await !folder.model.moveEdits(sheet))
        let aside = try #require(sheet.setAside)
        let show = try #require(button())
        #expect(!show.isHidden && show.title == "Show Set-Aside Edits")
        show.performClick(nil)
        #expect(revealed == [[aside]])

        let back = try await folder.sheet()
        #expect(back.destination == .besidePhotos && back.conflicts.isEmpty)
        #expect(back.setAside == folder.paths.setAsideEdits, "the library's copies set aside, from earlier moves")
    }
}
