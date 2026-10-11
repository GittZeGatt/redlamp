import Foundation
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// A source's stacks opened as its view kept them before the closed ones are covered (LIB-28, LIB-23): a photo active
/// inside a stack the view had open, found closed as the source is listed again, stays active, alone selected, the
/// stack open, rather than giving way to the stack's top with all its photos selected; at launch and when the source is
/// shown again.
@MainActor
struct LibraryStacksRestoreTests {
    @Test func `a photo active in a stack its view had open is active again when its folder is shown again`(
    ) async throws {
        let folder = StackFolder()
        defer { folder.cleanUp() }
        try await folder.open()
        try await folder.waitForStacks(open: 1, closed: 1, "the burst open, the pair closed")
        let model = try #require(folder.model)
        try model.clickInGrid(folder.url("S01.JPG"))
        try model.clickInGrid(folder.url("S02.JPG"), toggling: true)
        try model.clickInGrid(folder.url("S03.JPG"), toggling: true)
        #expect(model.perform(.stackPhotos))
        try await folder.waitForStacks(open: 1, closed: 2, "⌘G made a stack, closed")
        let stack = try #require(try folder.stack(holding: "S01.JPG"))
        try #require(stack.count == 3)
        try model.gridStacks.toggle(folder.id(stack[0]))
        try await folder.waitForStacks(open: 2, closed: 1, "the stack opened")
        let inner = try folder.url(stack[2])
        model.clickInGrid(inner)
        try #require(model.selection == inner && model.selectedPhotos == [inner])

        model.showFolder(folder.other)
        try await folder.eventually { model.folder == folder.other && model.items.count == StackFolder.others.count }
        try await folder.waitForStacks(open: 1, closed: 0, "Other's burst")
        model.showFolder(folder.root)
        try await folder.eventually { model.folder == folder.root && model.items.count == StackFolder.photos.count }
        try await folder.waitForStacks(open: 2, closed: 1, "the stack open again, as its view kept it")
        try await folder.eventually { model.gridStacks.isIdle }
        #expect(model.selection == inner, "\(stack[2]) active again, not the stack's top")
        #expect(model.selectedPhotos == [inner], "alone selected")
        #expect(folder.cells.contains(stack[2]), "with its cell")
        await model.libraryPanels.written()
    }

    @Test func `a photo active at quit in a stack its view had open is active again at launch`() async throws {
        let launches = try LaunchSandbox()
        defer { launches.remove() }
        let names = ["A.jpg", "B.jpg", "C.jpg", "D.jpg"]
        try launches.sandbox.photos(names.map { "Shoot/" + $0 })
        let first = launches.launch()
        try await launches.indexed()
        first.showModule(.library)
        first.showFolder(launches.sandbox.folder("Shoot"))
        try await launches.sandbox.eventually { first.library.isShownFromLibrary && first.items.count == 4 }
        let stacks = first.gridStacks
        first.select(launches.photo("A.jpg"))
        first.click(launches.photo("B.jpg"), toggling: true)
        first.click(launches.photo("C.jpg"), toggling: true)
        #expect(first.stackSelectedPhotos())
        try await launches.sandbox.eventually { stacks.list.map { $0.stacksShown == (0, 1) } == true }
        let a = try #require(first.library.photoID(of: launches.photo("A.jpg")))
        let ids = try #require(stacks.list?.stacks.stack(containing: a)?.photos)
        let photos = ids.compactMap(first.library.url(ofPhoto:))
        try #require(photos.count == 3, "the stack made")
        stacks.toggle(ids[0])
        try #require(stacks.list.map { $0.stacksShown == (1, 0) } == true, "the stack opened")
        first.select(photos[2])
        try await launches.sandbox.eventually { first.selection == photos[2] && first.selectedPhotos == [photos[2]] }
        await first.libraryPanels.written()
        await launches.quit()

        let model = launches.launch()
        try await launches.sandbox.eventually { model.items.count == 4 && model.selection != nil }
        try #require(model.folder == launches.sandbox.folder("Shoot") && model.selection == photos[2])
        let found = model.gridStacks
        try await launches.sandbox.eventually { found.list.map { $0.stacksShown == (1, 0) } == true && found.isIdle }
        #expect(found.list.map { $0.stacksShown == (1, 0) } == true, "the stack open, as it was at quit")
        #expect(model.selection == photos[2], "\(photos[2].lastPathComponent) active, not the stack's top")
        #expect(model.selectedPhotos == [photos[2]], "alone selected")
    }
}
