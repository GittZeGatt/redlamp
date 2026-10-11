import AppKit
import Foundation
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// Photos dragged within their open stack in the filmstrip (LIB-28), as in the grid: over another photo of the same
/// open burst or stack made by hand, that photo is ringed, and the drop moves the photos dragged to its place, one
/// change ⌘Z takes back; anywhere else nothing moves. A press on a photo of several selected keeps them for a drag, and
/// a release without one selects it alone.
@MainActor
struct FilmstripStackDragTests {
    @Test func `a frame dragged onto another of its open burst in the filmstrip takes its place, and ⌘Z puts it back`(
    ) async throws {
        let folder = StackFolder()
        defer { folder.cleanUp() }
        try await folder.open()
        try await folder.waitForStacks(open: 1, closed: 1, "the burst open, as found")
        let model = try #require(folder.model)
        try await folder.eventually { folder.strip.prefix(3) == ["B01.JPG", "B02.JPG", "B03.JPG"] }
        let outlined = LibraryDrags.outlined

        try folder.dragInStrip("B03.JPG", onto: "B01.JPG")
        try await folder.eventually { try (folder.stack(holding: "B01.JPG")) == ["B03.JPG", "B01.JPG", "B02.JPG"] }
        #expect(try folder.stack(holding: "B01.JPG") == ["B03.JPG", "B01.JPG", "B02.JPG"])
        #expect(LibraryDrags.outlined > outlined, "the photo it would take the place of was ringed")
        #expect(try model.gridStacks.list?.stacks.stack(containing: folder.id("B01.JPG"))?.kind == .manual)
        try await folder.eventually { folder.strip.prefix(3) == ["B03.JPG", "B01.JPG", "B02.JPG"] }
        #expect(folder.strip.prefix(3) == ["B03.JPG", "B01.JPG", "B02.JPG"], "the filmstrip in the stack's order")
        #expect(try folder.stripCell("B01.JPG").isDropTarget == false, "the ring gone with the drag")
        #expect(model.selection?.lastPathComponent == "B03.JPG", "the photo pressed is the one dragged")

        #expect(model.perform(.undo))
        try await folder.eventually { try (folder.stack(holding: "B01.JPG")) == ["B01.JPG", "B02.JPG", "B03.JPG"] }
        #expect(try folder.stack(holding: "B01.JPG") == ["B01.JPG", "B02.JPG", "B03.JPG"])
        #expect(try model.gridStacks.list?.stacks.stack(containing: folder.id("B01.JPG"))?.kind == .burst)
        await model.libraryPanels.written()
    }

    @Test func `two frames selected drag together, and a drag outside their open stack moves nothing`() async throws {
        let folder = StackFolder()
        defer { folder.cleanUp() }
        try await folder.open()
        try await folder.waitForStacks(open: 1, closed: 1, "the burst open, as found")
        let model = try #require(folder.model)
        try model.clickInGrid(folder.url("B02.JPG"))
        try model.clickInGrid(folder.url("B03.JPG"), toggling: true)

        // Onto a photo of no stack, and onto the pair: nothing moves, and the selection stays.
        try folder.dragInStrip("B03.JPG", onto: "S01.JPG")
        try folder.dragInStrip("B02.JPG", onto: "P01.JPG")
        try await Task.sleep(for: .milliseconds(200))
        #expect(try folder.stack(holding: "B01.JPG") == ["B01.JPG", "B02.JPG", "B03.JPG"])
        #expect(Set(model.selectedPhotos.map(\.lastPathComponent)) == ["B02.JPG", "B03.JPG"])

        try folder.dragInStrip("B03.JPG", onto: "B01.JPG")
        try await folder.eventually { try (folder.stack(holding: "B01.JPG")) == ["B02.JPG", "B03.JPG", "B01.JPG"] }
        #expect(try folder.stack(holding: "B01.JPG") == ["B02.JPG", "B03.JPG", "B01.JPG"])
        #expect(model.perform(.undo))
        try await folder.eventually { try (folder.stack(holding: "B01.JPG")) == ["B01.JPG", "B02.JPG", "B03.JPG"] }

        // A press on one of the photos selected, released without a drag, selects it alone.
        try model.clickInGrid(folder.url("B02.JPG"))
        try model.clickInGrid(folder.url("B03.JPG"), toggling: true)
        try folder.dragInStrip("B02.JPG", onto: nil, by: 1, steps: 1)
        #expect(model.selectedPhotos.map(\.lastPathComponent) == ["B02.JPG"] && !model.isMultiSelecting)
        await model.libraryPanels.written()
    }

    @Test func `a closed stack's frames don't move by a drag`() async throws {
        let folder = StackFolder()
        defer { folder.cleanUp() }
        try await folder.open()
        try await folder.waitForStacks(open: 1, closed: 1, "the burst open, as found")
        let model = try #require(folder.model)
        model.gridStacks.closeAll()
        try await folder.waitForStacks(open: 0, closed: 2, "closed")
        try await folder.eventually { folder.strip.first == "B01.JPG" && !folder.strip.contains("B02.JPG") }
        try folder.dragInStrip("B01.JPG", onto: "S01.JPG")
        try await Task.sleep(for: .milliseconds(200))
        #expect(try folder.stack(holding: "B01.JPG") == ["B01.JPG", "B02.JPG", "B03.JPG"])
        #expect(try model.canMovePhotos([folder.id("B03.JPG")], inStackTo: folder.id("B01.JPG")) == false)
    }
}
