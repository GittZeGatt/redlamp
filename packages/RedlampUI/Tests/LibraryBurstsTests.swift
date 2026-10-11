import AppKit
import Foundation
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// Bursts the library finds start open (DEC-64, LIB-28): every frame has its cell in the grid and the filmstrip, the
/// burst marked as one by its first cell's badge, until it's closed; a raw and its JPEG and stacks made by hand start
/// closed. Each source keeps how its stacks start and only the stacks that aren't as they'd start; a source without a
/// view starts with its bursts open, and a view kept before they did shows its stacks as they were.
@MainActor
struct LibraryBurstsTests {
    @Test func `a folder's bursts start open, every frame shown and the burst marked as one, and pairs closed`(
    ) async throws {
        let folder = StackFolder()
        defer { folder.cleanUp() }
        try await folder.open()
        try await folder.waitForStacks(open: 1, closed: 1, "the burst open, the pair closed")
        let model = try #require(folder.model)
        #expect(model.gridStacks.start == .found)
        let shown = ["B01.JPG", "B02.JPG", "B03.JPG", "P01.JPG", "S01.JPG", "S02.JPG", "S03.JPG", "S04.JPG"]
        try await folder.eventually { folder.cells == shown && folder.strip == shown }
        #expect(folder.cells == shown && folder.strip == shown, "every frame has its cell, the HEIC with its JPEG")
        let list = try #require(model.gridStacks.list)
        let burst = try list.badges(of: folder.id("B01.JPG")).stack
        #expect(burst?.kind == .burst && burst?.count == 3 && burst?.isOpen == true, "the burst marked as one")
        #expect(try list.badges(of: folder.id("B02.JPG")).stack == nil, "only its first cell is marked")
        let pair = try list.badges(of: folder.id("P01.JPG")).pair
        #expect(pair?.kind == .pair && pair?.count == 2 && pair?.isOpen == false)

        // S on a frame closes the burst, which then selects all its frames.
        try model.clickInGrid(folder.url("B02.JPG"))
        #expect(model.perform(.toggleStack))
        try await folder.waitForStacks(open: 0, closed: 2, "S closed the burst")
        #expect(Set(model.selectedPhotos.map(\.lastPathComponent)) == ["B01.JPG", "B02.JPG", "B03.JPG"])

        // A stack made by hand starts closed.
        try model.clickInGrid(folder.url("S01.JPG"))
        try model.clickInGrid(folder.url("S02.JPG"), toggling: true)
        #expect(model.perform(.stackPhotos))
        try await folder.waitForStacks(open: 0, closed: 3, "⌘G made a stack, closed")
        #expect(model.perform(.undo))
        try await folder.waitForStacks(open: 0, closed: 2, "⌘Z took it back")
        await model.libraryPanels.written()
    }

    @Test func `each source keeps a burst closed by hand, and a source without a view starts with its bursts open`(
    ) async throws {
        let folder = StackFolder()
        defer { folder.cleanUp() }
        try await folder.open()
        try await folder.waitForStacks(open: 1, closed: 1, "the root's burst open")
        let model = try #require(folder.model)
        try model.gridStacks.toggle(folder.id("B01.JPG"))
        try await folder.waitForStacks(open: 0, closed: 2, "the burst closed by hand")
        let kept = model.gridStacks.openness
        #expect(try kept.start == .found && kept.others.map(\.path) == [folder.url("B01.JPG").path])

        model.showFolder(folder.other)
        try await folder.eventually { model.folder == folder.other && model.items.count == 3 }
        try await folder.waitForStacks(open: 1, closed: 0, "Other's burst open: it has no view yet")
        #expect(model.gridStacks.start == .found && model.gridStacks.openness.others.isEmpty)

        // Close All in Other: its stacks start closed, and it keeps none as not starting so.
        model.gridStacks.closeAll()
        try await folder.waitForStacks(open: 0, closed: 1, "Close All")
        #expect(model.gridStacks.openness == LibraryStacks.Openness(start: .closed, others: []))

        model.showFolder(folder.root)
        try await folder.eventually { model.folder == folder.root && model.items.count == StackFolder.photos.count }
        try await folder.waitForStacks(open: 0, closed: 2, "the root's burst still closed")
        #expect(model.gridStacks.start == .found)
        model.showFolder(folder.other)
        try await folder.eventually { model.folder == folder.other && model.items.count == 3 }
        try await folder.waitForStacks(open: 0, closed: 1, "Other's burst closed, as Close All left it")
        #expect(model.gridStacks.start == .closed)
    }

    @Test func `a view kept before found bursts started open shows its stacks as they were, and new bursts open`(
    ) async throws {
        let folder = StackFolder()
        defer { folder.cleanUp() }
        try await folder.open()
        try await folder.waitForStacks(open: 1, closed: 1, "the burst open, as found")
        let model = try #require(folder.model)
        let decoder = JSONDecoder()

        // An earlier build's view: every stack started closed, the pair opened.
        let (pair, burst) = try (folder.url("P01.JPG").path, folder.url("B01.JPG").path)
        let opened = try decoder.decode(LibraryStacks.Openness.self, from: Data("""
        {"all": false, "others": [{"path": "\(pair)", "pair": true}]}
        """.utf8))
        model.gridStacks.restore(opened)
        try await folder.eventually { folder.cells.contains("P01.HEIC") && !folder.cells.contains("B02.JPG") }
        #expect(
            folder.cells.contains("P01.HEIC") && !folder.cells.contains("B02.JPG"),
            "the burst closed, the pair open",
        )
        #expect(model.gridStacks.start == .found, "the stacks it gains start as found")
        #expect(model.gridStacks.openness.others.map(\.path).sorted() == [burst, pair].sorted())

        // An earlier build's view after Open All: every stack open, the burst closed.
        let all = try decoder.decode(LibraryStacks.Openness.self, from: Data("""
        {"all": true, "others": [{"path": "\(burst)", "pair": false}]}
        """.utf8))
        model.gridStacks.restore(all)
        try await folder.waitForStacks(open: 1, closed: 1, "the pair open and the burst closed")
        #expect(model.gridStacks.start == .open && folder.cells.contains("P01.HEIC") && !folder.cells
            .contains("B02.JPG"))

        let encoded = try JSONEncoder().encode(LibraryStacks.Openness(start: .closed, others: []))
        let read = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(read?["all"] as? Bool == false && read?["start"] as? String == "closed", "an earlier build reads all")
    }

    @Test func `Close All asked for as the stacks are being found leaves them closed`() async throws {
        let folder = StackFolder()
        defer { folder.cleanUp() }
        try await folder.open()
        let model = try #require(folder.model)
        model.gridStacks.closeAll()
        try await folder.waitForStacks(open: 0, closed: 2, "found closed")
        #expect(model.gridStacks.start == .closed)
    }
}
