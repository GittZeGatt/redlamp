import AppKit
import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@_spi(Harness) @testable import RedlampUI

/// One Undo for Library and Develop (LIB-13): ⌘Z in either module takes back the newest change of either, Develop's
/// edits of the open photo and Library's changes in the one order they were made, ⇧⌘Z makes them again in turn, a
/// change of either module ends every Redo, and Develop's steps leave Undo once Develop lets their photo go.
@MainActor
struct OneUndoTests {
    private typealias Folder = CullingTests.IndexedFolder

    /// The first photo's sidecar as it is once `condition` holds of it, or after 30 s: culling's batches and
    /// Develop's saves land in the background, in the order they were asked for.
    private func sidecar(of folder: Folder, when condition: (Sidecar?) -> Bool) async throws -> Sidecar? {
        try await folder.eventually { condition(SidecarStore().load(for: folder.photos[0])) }
        return SidecarStore().load(for: folder.photos[0])
    }

    @Test func `⌘Z in either module takes back Develop's edits and Library's culling in the order they were made`()
        async throws {
        let folder = Folder()
        defer { folder.cleanUp() }
        try await folder.open(count: 3)
        let model = try #require(folder.model)
        #expect(model.module == .library && model.info?.url == folder.photos[0])
        #expect(!model.canPerform(.undo))

        #expect(model.perform(.rating3))
        model.showModule(.develop)
        model.setValue(.exposure, 0.5)
        model.showModule(.library)
        #expect(model.perform(.flagPick))
        model.showModule(.develop)
        model.setValue(.contrast, 20)
        await folder.written()

        // In Develop: its edit, newest, then Library's flag.
        #expect(model.perform(.undo) && model.value(.contrast) == 0, "the contrast went first")
        #expect(model.undoNotice.text == "Undo Contrast")
        #expect(model.photoMetadata.flag == .pick)
        #expect(model.perform(.undo))
        #expect(model.undoNotice.text == "Undo Flag as Pick in Library", "the notice names the module out of sight")
        #expect(model.photoMetadata.flag == nil && folder.shown(0).flag == nil, "then the flag, made in Library")
        #expect(try await sidecar(of: folder) { $0?.metadata?.flag == nil }?.metadata?.flag == nil)
        #expect(model.value(.exposure) == 0.5 && model.photoMetadata.rating == 3)

        // In Library: Develop's edit, on the photo it keeps open behind Library, then the rating.
        model.showModule(.library)
        #expect(model.canPerform(.undo) && model.perform(.undo))
        #expect(model.value(.exposure) == 0, "Develop's exposure, from Library")
        #expect(model.undoNotice.text == "Undo Exposure in Develop")
        model.saveNow()
        #expect(try await sidecar(of: folder) { $0?.recipe[.exposure] == 0 }?.recipe[.exposure] == 0, "and saved")
        #expect(model.photoMetadata.rating == 3)
        #expect(model.perform(.undo))
        #expect(model.photoMetadata.rating == 0 && folder.shown(0).rating == 0, "then the rating")
        #expect(try await sidecar(of: folder) { ($0?.metadata?.rating ?? 0) == 0 }?.metadata?.rating ?? 0 == 0)
        #expect(!model.canPerform(.undo) && !model.perform(.undo))

        // ⇧⌘Z makes them again in turn, in whichever module.
        #expect(model.perform(.redo) && folder.shown(0).rating == 3, "the rating again")
        #expect(model.undoNotice.text == "Redo 3 Stars")
        #expect(model.perform(.redo) && model.value(.exposure) == 0.5, "then Develop's exposure")
        model.showModule(.develop)
        #expect(model.perform(.redo) && model.photoMetadata.flag == .pick, "then the flag, from Develop")
        #expect(model.perform(.redo) && model.value(.contrast) == 20, "then the contrast")
        #expect(!model.canPerform(.redo))
        model.saveNow()
        let redone = try await sidecar(of: folder) { sidecar in
            sidecar?.recipe[.contrast] == 20 && sidecar?.metadata?.flag == .pick
        }
        #expect(redone?.recipe[.exposure] == 0.5 && redone?.recipe[.contrast] == 20)
        #expect(redone?.metadata?.rating == 3 && redone?.metadata?.flag == .pick)
    }

    @Test func `a change of either module ends every Redo, and Develop's steps taken back stay in its History`()
        async throws {
        let folder = Folder()
        defer { folder.cleanUp() }
        try await folder.open(count: 3)
        let model = try #require(folder.model)

        model.showModule(.develop)
        model.setValue(.exposure, 0.5)
        #expect(model.perform(.undo) && model.canPerform(.redo))
        model.showModule(.library)
        #expect(model.canPerform(.redo), "Develop's step taken back is on Redo in Library too")
        #expect(model.perform(.rating2))
        #expect(!model.canPerform(.redo), "Library's rating ended Develop's Redo")
        #expect(model.history.count == model.historyIndex + 2, "the exposure stays in History")
        model.showModule(.develop)
        #expect(!model.canPerform(.redo))
        model.goToHistory(model.historyIndex + 1)
        #expect(model.value(.exposure) == 0.5, "a click in History still makes it again")

        model.showModule(.library)
        #expect(model.perform(.undo) && model.value(.exposure) == 0, "History's step, made again last, goes first")
        #expect(model.perform(.undo) && folder.shown(0).rating == 0)
        #expect(model.canPerform(.redo))
        model.showModule(.develop)
        model.setValue(.contrast, 10)
        #expect(!model.canPerform(.redo), "Develop's edit ended Library's Redo")
        await folder.written()
    }

    @Test func `Develop's steps leave Undo once Develop lets their photo go, and ⌘Z goes on to Library's changes`()
        async throws {
        let folder = Folder()
        defer { folder.cleanUp() }
        try await folder.open(count: 3)
        let model = try #require(folder.model)

        #expect(model.perform(.rating4))
        model.showModule(.develop)
        model.setValue(.exposure, 0.5)
        model.showModule(.library)
        #expect(model.perform(.flagPick))
        model.click(folder.photos[1])
        #expect(model.info == nil, "Develop let the first photo go")
        await folder.written()
        #expect(try await sidecar(of: folder) { $0?.recipe[.exposure] == 0.5 }?.recipe[.exposure] == 0.5)

        #expect(model.perform(.undo) && folder.shown(0).flag == nil, "the flag")
        #expect(model.perform(.undo) && folder.shown(0).rating == 0, "then the rating, past the exposure let go")
        #expect(!model.canPerform(.undo))
        let undone = try await sidecar(of: folder) { sidecar in
            sidecar?.metadata?.flag == nil && (sidecar?.metadata?.rating ?? 0) == 0
        }
        #expect(undone?.recipe[.exposure] == 0.5, "the exposure stays as it was")

        model.showModule(.develop)
        try await folder.eventually { model.info?.url == folder.photos[1] }
        #expect(model.info?.url == folder.photos[1] && !model.canPerform(.undo))
        #expect(model.canPerform(.redo) && model.perform(.redo))
        #expect(folder.shown(0).rating == 4, "Redo makes Library's changes again from Develop")
        #expect(try await sidecar(of: folder) { $0?.metadata?.rating == 4 }?.metadata?.rating == 4)
    }

    @Test func `the notice over both modules says what Undo and Redo reached, then goes`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        try await fixture.open(count: 2)
        let modules = fixture.showModules()
        let model = fixture.model
        let notice = try #require(modules.content.notice)
        #expect(notice.text.isEmpty && notice.hitTest(CGPoint(x: notice.bounds.midX, y: notice.bounds.midY)) == nil)
        model.setValue(.exposure, 0.5)
        model.showModule(.library)
        #expect(model.perform(.undo))
        try await fixture.settle()
        #expect(notice.text == "Undo Exposure in Develop")
        #expect(model.perform(.redo))
        try await fixture.settle()
        #expect(notice.text == "Redo Exposure in Develop")
        try await fixture.eventually { notice.text.isEmpty }
        #expect(notice.text.isEmpty, "gone after \(UndoNotice.shown)")
    }

    @Test func `a run of nudges still open is recorded and taken back first`() async throws {
        let folder = Folder()
        defer { folder.cleanUp() }
        try await folder.open(count: 2)
        let model = try #require(folder.model)
        #expect(model.perform(.rating2))
        model.showModule(.develop)
        model.focusedParameter = .exposure
        #expect(model.perform(.increaseSetting) && model.perform(.increaseSetting))
        #expect(model.hasOpenNudgeRun && model.value(.exposure) > 0)
        #expect(model.canPerform(.undo) && model.perform(.undo))
        #expect(model.value(.exposure) == 0 && !model.hasOpenNudgeRun, "the run, whole")
        #expect(model.photoMetadata.rating == 2, "the rating made before it stays")
        await folder.written()
    }
}
