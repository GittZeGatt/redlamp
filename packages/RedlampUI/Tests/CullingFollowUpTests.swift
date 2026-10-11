import AppKit
import Foundation
import RedlampDocument
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// Culling's follow-ups (LIB-15, DEC-62): custom labels' colours given, shown and changed with Undo; a change some
/// photos didn't get shown with them, selected and tried again; B on the target collection; and a custom label in
/// Compare and Survey reaching the active photo alone.
@MainActor
struct CullingFollowUpTests {
    typealias Folder = CullingTests.IndexedFolder

    /// Until the changes asked for are made and the library has settled.
    private func settled(_ folder: Folder) async {
        await folder.written()
        await folder.model.libraryPanels.written()
        await folder.service.settled()
    }

    /// Until `condition` holds of the sources, counted again as the library settles.
    private func made(_ folder: Folder, until condition: (LibrarySources) -> Bool) async throws {
        let sources = folder.model.librarySources
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            await settled(folder)
            sources.recount()
            await sources.counted()
            if condition(sources) {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("the sources didn't get there in 30 s")
    }

    // MARK: - Custom labels' colours

    @Test func `a custom label's colour goes into its batch with it, and a colour label takes it off`() {
        let urgent = CullingValues(PhotoMetadata(customLabel: "Urgent", customLabelColor: .orange))
        #expect(urgent.fields(.label) == [.namedLabel("Urgent"), .customLabelColor(.orange)])
        let given = CullingChange.toggleCustomLabel("Hero").resolved([CullingValues(PhotoMetadata())], color: .teal)
        #expect(given[0].customLabel == "Hero" && given[0].customLabelColor == .teal)
        let red = CullingChange.label(.red).resolved([urgent])[0]
        #expect(red.customLabel == nil && red.customLabelColor == nil && red.fields(.label) == [.label(.red)])
        let plain = CullingValues(PhotoMetadata(customLabel: "Urgent"))
        #expect(urgent.matches(plain, in: .label), "a photo shows its label in the label's colour, whatever it holds")
    }

    @Test func `a custom label is drawn in the library's colour, else its photo's, else the one it's named after`() {
        let colors: [String: LabelColor] = ["Urgent": .teal]
        #expect(GridBadges.color(ofCustomLabel: "Urgent", own: .pink, colors: colors) == LabelColor.teal.nsColor)
        #expect(GridBadges.color(ofCustomLabel: "Hero", own: .pink, colors: colors) == LabelColor.pink.nsColor)
        #expect(GridBadges.color(ofCustomLabel: "Orange", colors: colors) == LabelColor.orange.nsColor)
        let newer = LabelColor(rawValue: "chartreuse")
        #expect(GridBadges.color(ofCustomLabel: "Hero", own: newer, colors: colors) == GridBadges.neutral)
        #expect(LabelColor.palette.allSatisfy { $0.nsColor != nil } && newer.nsColor == nil)
    }

    @Test func `a label is named with its colour, given with it, and its colour changed on every photo, with Undo`(
    ) async throws {
        let folder = Folder()
        defer { folder.cleanUp() }
        try await folder.open(count: 4)
        let model = try #require(folder.model)
        model.click(folder.photos[2])
        model.click(folder.photos[3], toggling: true)
        #expect(model.giveCustomLabel("Urgent", color: .orange))
        #expect(folder.shown(2).customLabel == "Urgent" && folder.shown(3).customLabel == "Urgent", "shown at once")
        await settled(folder)
        #expect(folder.sidecar(2)?.customLabelColor == .orange && folder.sidecar(3)?.customLabelColor == .orange)
        try await folder.eventually { model.customLabelCounts.first?.photos == 2 }
        #expect(model.customLabelCounts == [CustomLabelCount(name: "Urgent", photos: 2, color: .orange)])

        model.click(folder.photos[1])
        model.setCustomLabel("Urgent")
        await settled(folder)
        #expect(folder.sidecar(1)?.customLabelColor == .orange, "the label's key gives the library's colour with it")

        let recolour = try #require(model.setColor(.teal, ofCustomLabel: "Urgent"))
        #expect(model.customLabelColor(of: "Urgent") == .teal, "the colour shows at once")
        #expect(model.setColor(.teal, ofCustomLabel: "Urgent") == nil, "it has that colour already")
        await recolour.value
        await settled(folder)
        #expect([1, 2, 3].allSatisfy { folder.sidecar($0)?.customLabelColor == .teal }, "on every photo of the label")
        #expect(folder.sidecar(1)?.rating == 2, "each keeps what else it held")

        #expect(model.perform(.undo))
        await settled(folder)
        #expect([1, 2, 3].allSatisfy { folder.sidecar($0)?.customLabelColor == .orange })
        try await folder.eventually { model.customLabelColor(of: "Urgent") == .orange }
        #expect(model.customLabelColor(of: "Urgent") == .orange)
    }

    @Test func `a colour label's name can't name a custom label, and the menus show custom labels in their colours`(
    ) async throws {
        #expect(!EditorModel.canNameCustomLabel("Red") && !EditorModel.canNameCustomLabel("Approved"))
        #expect(!EditorModel.canNameCustomLabel("  ") && EditorModel.canNameCustomLabel("Second Look"))
        let folder = Folder()
        defer { folder.cleanUp() }
        try await folder.open(count: 2)
        let model = try #require(folder.model)
        #expect(!model.giveCustomLabel("Red", color: .pink))
        #expect(model.giveCustomLabel("Hero", color: .pink))
        await settled(folder)
        let menu = LibraryGridMenu.labels(for: folder.photos[0], model: model)
        let hero = try #require(menu.items.first { $0.title == "Hero" })
        #expect(hero.image != nil && hero.state == .on)
        #expect(menu.items.contains { $0.title == "Custom Labels…" })
        let catalog = PaletteCatalog.customLabelItems(editor: model)
        #expect(catalog.map(\.kind) == [.customLabel("Hero"), .customLabels])
    }

    // MARK: - Photos a change didn't reach

    @Test func `a change some photos didn't get is named with them, selects them, and is tried again`() async throws {
        let folder = Folder()
        defer { folder.cleanUp() }
        try await folder.open(count: 4)
        let model = try #require(folder.model)
        // Another photo active, so Develop has none open.
        model.click(folder.photos[2])
        #expect(model.perform(.selectAllPhotos) && model.info == nil)
        let edit = SidecarStore().editURL(for: folder.photos[1])
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: edit.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: edit.path) }

        #expect(model.perform(.rating4))
        await settled(folder)
        let problem = try #require(model.cullingProblem)
        #expect(problem.title == "4 Stars" && problem.photos == [folder.photos[1]])
        #expect(problem.message.hasPrefix("4 Stars wasn't saved to IMG_0001.JPG: "), "\(problem.message)")
        #expect(folder.shown(1).rating == 2 && folder.shown(3).rating == 4, "each shows what its sidecar holds")

        model.selectCullingProblem()
        #expect(model.selection == folder.photos[1] && model.selectedCount == 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: edit.path)
        #expect(model.retryCulling() && model.cullingProblem == nil)
        #expect(folder.shown(1).rating == 4, "Try Again shows at once")
        await settled(folder)
        #expect(folder.sidecar(1)?.rating == 4 && model.cullingProblem == nil)
        #expect(!model.retryCulling(), "nothing is left to try")

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: edit.path)
        #expect(model.perform(.selectAllPhotos) && model.perform(.flagPick))
        await settled(folder)
        #expect(model.cullingProblem?.title == "Flag as Pick")
        #expect(model.perform(.undo) && model.cullingProblem == nil, "it goes with the Undo of its change")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: edit.path)
        await settled(folder)
        model.closeCullingProblem()
        #expect(model.cullingProblem == nil)
    }

    // MARK: - B on the target collection (DEC-62)

    @Test func `B puts the selection in the target collection, takes it out again, and marks it while Marked is the target`(
    ) async throws {
        let folder = Folder()
        defer { folder.cleanUp() }
        try await folder.open(count: 4)
        let model = try #require(folder.model)
        let sources = model.librarySources
        let selects = try #require(CollectionPath("Selects"))
        #expect(sources.create(.collection, named: "Selects"))
        try await made(folder) { $0.collections[selects] != nil }
        #expect(sources.setTarget(selects))
        try await made(folder) { $0.target == selects }
        model.click(folder.photos[1])
        model.click(folder.photos[2], toggling: true)

        #expect(model.perform(.toggleMark))
        try await made(folder) { $0.count(of: .collection(selects)) == 2 }
        #expect(!folder.shown(1).mark && !folder.shown(2).mark, "B didn't mark them")
        #expect(model.perform(.toggleMark), "B again, every one in it")
        try await made(folder) { $0.count(of: .collection(selects)) == 0 }
        #expect(model.perform(.undo))
        try await made(folder) { $0.count(of: .collection(selects)) == 2 }

        #expect(sources.setTarget(nil))
        try await made(folder) { $0.target == nil }
        #expect(model.perform(.toggleMark))
        #expect(folder.shown(1).mark && folder.shown(2).mark, "with Marked the target, B marks them")
        await settled(folder)
        #expect(folder.sidecar(1)?.mark == true && folder.sidecar(2)?.mark == true)
    }

    // MARK: - Compare and Survey

    @Test func `in Compare and Survey a custom label from the Photo menu reaches the active photo alone`() async throws {
        let folder = Folder()
        defer { folder.cleanUp() }
        try await folder.open(count: 4)
        let model = try #require(folder.model)
        model.click(folder.photos[1])
        model.click(folder.photos[2], toggling: true)
        func labelled() -> [URL] {
            folder.photos.indices.filter { folder.shown($0).customLabel == "Hero" }.map { folder.photos[$0] }
        }

        #expect(model.perform(.compareView) && model.libraryView == .compare)
        let compared = try #require(model.selection)
        model.setCustomLabel("Hero")
        #expect(labelled() == [compared])
        await settled(folder)
        #expect(model.perform(.undo))
        #expect(labelled().isEmpty)
        await settled(folder)

        #expect(model.perform(.surveyView) && model.libraryView == .survey)
        let surveyed = try #require(model.selection)
        model.setCustomLabel("Hero")
        #expect(labelled() == [surveyed])
        await settled(folder)
    }
}
