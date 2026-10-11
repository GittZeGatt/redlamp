import AppKit
import Foundation
import Testing
@testable import RedlampLibrary
@_spi(Harness) @testable import RedlampUI

/// The import window's Group By (DEC-69): a card's photos in moments until it's changed, any other source's only
/// once it's chosen, each source keeping its own; the moments found again as browsing reads the photos' capture
/// times; and the grid showing each group under its header, Library's keys acting on photos selected across them.
@MainActor
@Suite(.serialized)
struct ImportGroupingTests {
    /// A card of photos 0 to 3, taken a second apart from 09:00, and 7200 to 7202, two hours later: a pause past the
    /// hour starts a moment whatever the pace around it.
    private func twoMoments(_ fixture: ImportWindowFixture) throws -> URL {
        let root = try fixture.card("EOS_DIGITAL", count: 4)
        _ = try fixture.card("EOS_DIGITAL", count: 3, from: 7200)
        return root
    }

    private func names(_ numbers: [Int]) -> [String] {
        numbers.map(ImportWindowFixture.name)
    }

    @Test func `a card's photos are in moments by default, the newest first, and Group By changes how they're grouped`(
    ) async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        let model = fixture.model()
        model.start()
        try model.add(fixture.cardSource(twoMoments(fixture)))
        await model.browsed()
        await model.regrouped()
        #expect(model.grouping == .moment)
        #expect(model.groups.map(\.name) == ["5 October 2026, 11:00", "5 October 2026, 09:00"])
        #expect(model.groups.map { model.photos[$0.places].map(\.primary.name) } == [
            names([7202, 7201, 7200]), names([3, 2, 1, 0]),
        ])
        #expect(model.index(of: model.photos[4].id) == 4)

        model.setGrouping(.none)
        #expect(model.groups == [ImportGroup(name: "", places: 0 ..< 7)])
        #expect(model.photos.map(\.primary.name) == names([7202, 7201, 7200, 3, 2, 1, 0]), "newest first")
        model.setGrouping(.day)
        #expect(model.groups.map(\.name) == ["5 October 2026"])
        model.setGrouping(.moment)
        #expect(model.groups.count == 2)

        // A folder is grouped only once Group By says so, and each source keeps its own.
        try await model.addFolder(fixture.folder("Shelf", count: 3, from: 100))
        await model.browsed()
        #expect(model.grouping == .none && model.groups.count == 1)
        model.setGrouping(.moment)
        #expect(model.groups.map(\.name) == ["5 October 2026, 09:01"])
        let card = try #require(model.sources.first)
        model.show(card.id)
        #expect(model.grouping == .moment && model.groups.count == 2, "the card kept its own")
        model.setGrouping(.none)
        model.show(model.sources[1].id)
        #expect(model.grouping == .moment, "and the folder its own")
    }

    @Test func `a card's moments are found again as browsing reads the capture times its files' dates stood in for`(
    ) async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        let root = try twoMoments(fixture)
        // Copied to the card at one time: until their heads are read, the photos look taken together.
        let photos = root.appending(path: "DCIM/100CANON", directoryHint: .isDirectory)
        for name in try FileManager.default.contentsOfDirectory(atPath: photos.path) {
            try FileManager.default.setAttributes(
                [.modificationDate: ImportWindowFixture.taken(9999)], ofItemAtPath: photos.appending(path: name).path,
            )
        }
        let model = fixture.model()
        var reloads = 0
        model.onChange = { change in
            if change == .photos(ids: nil) {
                reloads += 1
            }
        }
        model.start()
        try model.add(fixture.cardSource(root))
        await model.browsed()
        await model.regrouped()
        #expect(model.groups.map { model.photos[$0.places].map(\.primary.name) } == [
            names([7202, 7201, 7200]), names([3, 2, 1, 0]),
        ])
        #expect(reloads >= 2, "listed, then grouped again")
        let settled = reloads
        model.rate([model.photos[0].id], 2)
        await model.regrouped()
        #expect(reloads == settled, "a change that leaves the capture times leaves the groups")
    }

    @Test func `the grid shows each group under its header, and the keys act on the photos selected across groups`(
    ) async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        let model = fixture.model()
        try model.add(fixture.cardSource(twoMoments(fixture)))
        await model.browsed()
        await model.regrouped()
        let grid = ImportGridViewController(model: model, thumbnails: ImportThumbnails(store: fixture.store))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 600), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.contentView = grid.view
        model.onChange = { grid.modelChanged($0) }
        grid.modelChanged(.photos(ids: nil))
        grid.view.layoutSubtreeIfNeeded()
        let collection = grid.collectionView
        #expect(collection.numberOfSections == 2)
        #expect(collection.numberOfItems(inSection: 0) == 3 && collection.numberOfItems(inSection: 1) == 4)
        #expect(grid.groupBy.titleOfSelectedItem == "Moment")
        let headers = collection.visibleSupplementaryViews(ofKind: NSCollectionView.elementKindSectionHeader)
        #expect(Set(headers.map { $0.accessibilityIdentifier() }) == [
            "import.group.5 October 2026, 11:00", "import.group.5 October 2026, 09:00",
        ])

        collection.selectionIndexPaths = [IndexPath(item: 0, section: 0), IndexPath(item: 3, section: 1)]
        let selected = try [#require(model.photo(at: 0)?.id), #require(model.photo(at: 6)?.id)]
        #expect(grid.selectedIDs == selected)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "3", charactersIgnoringModifiers: "3", isARepeat: false, keyCode: 0,
        ))
        collection.keyDown(with: event)
        #expect(selected.map { model.photo(id: $0)?.choices.rating } == [3, 3])
        #expect(model.photo(at: 1)?.choices.rating == 0)

        grid.groupBy.selectItem(withTitle: "None")
        grid.groupBy.sendAction(grid.groupBy.action, to: grid.groupBy.target)
        #expect(model.grouping == .none && collection.numberOfSections == 1)
        #expect(Set(grid.selectedIDs) == Set(selected), "the selection kept")
    }
}
