import Foundation
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// The filter and sort carried across modules (LIB-13): the filter bar's filter and the sort a source is shown with
/// in Library are the filmstrip's in Develop, which steps through those photos in that order, and a filter or sort
/// chosen in Develop, from the menus or the palette, is Library's.
@MainActor
struct FilterAcrossModulesTests {
    private func url(_ name: String, in model: EditorModel) throws -> URL {
        try #require(model.items.first { $0.name == name }?.url)
    }

    @Test func `Library's filter and sort are the filmstrip's in Develop, which steps through them in their order`()
        async throws {
        let fixture = LibraryFilterTests()
        defer { fixture.cleanUp() }
        let (model, _) = try await fixture.open()
        let filters = try #require(model.libraryFilters)
        model.showModule(.library)
        try await fixture.filtered(model, "rating>=2")
        filters.setSort(LibrarySort(.rating, ascending: false))
        try await fixture.listed(model)
        let shown = ["IMG_0001.JPG", "DSC_0005.JPG", "IMG_0002.JPG"]
        #expect(fixture.names(model) == shown)
        let first = try url(shown[0], in: model)
        model.click(first)

        model.showModule(.develop)
        #expect(fixture.names(model) == shown, "the filmstrip shows Library's photos, in its order")
        #expect(model.library.isFiltered && filters.listed?.shown == 3 && filters.listed?.total == 5)
        try await fixture.eventually { model.info?.url == first }
        for name in shown.dropFirst() {
            #expect(model.perform(.nextPhoto))
            try await fixture.eventually { model.info?.url.lastPathComponent == name }
            #expect(model.selection?.lastPathComponent == name, "→ in Develop goes to \(name)")
        }
        #expect(!model.canPerform(.nextPhoto), "the last photo the filter finds is the last")

        model.showModule(.library)
        #expect(fixture.names(model) == shown && model.selection?.lastPathComponent == shown[2])
        #expect(filters.filter.text == "rating>=2" && filters.sort == LibrarySort(.rating, ascending: false))
    }

    @Test func `a filter or sort chosen in Develop is Library's, and the filter turned off there is off in both`()
        async throws {
        let fixture = LibraryFilterTests()
        defer { fixture.cleanUp() }
        let (model, _) = try await fixture.open()
        let filters = try #require(model.libraryFilters)
        model.showModule(.develop)
        #expect(model.canPerform(.sortByName) && model.canPerform(.toggleFilters))
        #expect(!model.canPerform(.toggleFilterBar), "the bar is Library's, as \\ is Before / After in Develop")

        #expect(model.perform(.sortByName) && model.perform(.reverseSort))
        try await fixture.listed(model)
        let byName = ["IMG_0004.PNG", "IMG_0003.JPG", "IMG_0002.JPG", "IMG_0001.JPG", "DSC_0005.JPG"]
        #expect(fixture.names(model) == byName)
        try filters.choose(#require(filters.presets.first { $0.name == "Rated" }))
        try await fixture.listed(model)
        let rated = fixture.names(model)
        #expect(rated == ["IMG_0004.PNG", "IMG_0002.JPG", "IMG_0001.JPG", "DSC_0005.JPG"], "\(rated)")

        model.showModule(.library)
        #expect(fixture.names(model) == rated, "Library shows what Develop chose")
        #expect(filters.preset?.name == "Rated" && filters.sort == LibrarySort(.name, ascending: false))

        model.showModule(.develop)
        #expect(model.perform(.toggleFilters))
        try await fixture.eventually { fixture.names(model) == byName }
        #expect(fixture.names(model) == byName && !filters.filter.isEnabled)
        model.showModule(.library)
        #expect(fixture.names(model) == byName, "⌘L in Develop turned it off in Library too")
    }

    @Test func `a photo culled out of the filter in Develop gives its place to the next, as in Library`()
        async throws {
        let fixture = LibraryFilterTests()
        defer { fixture.cleanUp() }
        let (model, _) = try await fixture.open()
        let filters = try #require(model.libraryFilters)
        try await fixture.filtered(model, "rating>=2")
        filters.setSort(LibrarySort(.rating, ascending: false))
        try await fixture.listed(model)
        model.showModule(.develop)
        let third = try url("IMG_0002.JPG", in: model)
        model.select(third)
        try await fixture.eventually { model.info?.url == third }

        #expect(model.perform(.rating1))
        try await fixture.eventually { model.items.count == 2 && model.info?.url.lastPathComponent == "DSC_0005.JPG" }
        #expect(fixture.names(model) == ["IMG_0001.JPG", "DSC_0005.JPG"])
        #expect(model.info?.url.lastPathComponent == "DSC_0005.JPG", "Develop opens the photo that took its place")
        model.showModule(.library)
        #expect(fixture.names(model) == ["IMG_0001.JPG", "DSC_0005.JPG"])
    }
}
