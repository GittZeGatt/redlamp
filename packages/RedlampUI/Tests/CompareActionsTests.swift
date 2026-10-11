import AppKit
import Foundation
import Testing
@_spi(Harness) @testable import RedlampUI

/// Compare's Swap (↓) and Make Select (↑) as actions of the command list (LIB-16): Library's keys, items in the View
/// menu, rows in the palette and in Settings › Shortcuts, run in Compare alone and by its buttons.
@MainActor
struct CompareActionsTests {
    /// A folder of `count` photos in Library's grid, with the window's module views around it.
    private func library(_ count: Int) async throws -> (ModuleFixture, ModuleWindow) {
        let fixture = ModuleFixture()
        try await fixture.open(count: count)
        let modules = fixture.showModules()
        fixture.model.showModule(.library)
        try await fixture.settle()
        return (fixture, modules)
    }

    private func names(_ urls: [URL?]) -> [String] {
        urls.map { $0?.lastPathComponent ?? "-" }
    }

    @Test func `Swap and Make Select are Library's ↓ and ↑, in the palette and in Settings › Shortcuts`() {
        #expect(ShortcutAction.resolve(KeyCombo(.down), in: .library)?.action == .swapCompared)
        #expect(ShortcutAction.resolve(KeyCombo(.up), in: .library)?.action == .makeSelect)
        #expect(ShortcutAction.resolve(KeyCombo(.down), in: .develop) == nil, "Develop leaves ↓ to its controls")
        #expect(ShortcutAction.resolve(KeyCombo(.up), in: .develop) == nil)
        #expect(ShortcutAction.swapCompared.title == "Swap Select and Candidate")
        #expect(ShortcutAction.makeSelect.title == "Make Select")
        let store = ShortcutKeymap(defaults: nil)
        store.keymap = .standard
        let editor = ShortcutEditor(store: store)
        for (action, words) in [(ShortcutAction.swapCompared, "swap"), (.makeSelect, "make select")] {
            #expect(action.category == .library && action.isLibraryOnly && !action.isMenuShortcut)
            #expect(PaletteCatalog.actionItems.contains { $0.kind == .action(action) }, "\(action.title) isn't listed")
            #expect(ShortcutAction.byCategory.contains { $0.0 == .library && $0.1.contains(action) })
            editor.search = words
            #expect(editor.sections.flatMap(\.1).contains(action), "searching \(words) doesn't find \(action.title)")
        }
        #expect(Keymap.standard.conflicts(assigning: KeyCombo(.down), to: .swapCompared).isEmpty)
        #expect(Keymap.standard.conflicts(assigning: KeyCombo(.up), to: .makeSelect).isEmpty)
    }

    @Test func `they run in Compare alone, as its keys and buttons run them`() async throws {
        let (fixture, modules) = try await library(5)
        defer { fixture.cleanUp() }
        let (model, photos) = (fixture.model, fixture.photos)
        model.click(photos[1])
        for action in [ShortcutAction.swapCompared, .makeSelect] {
            #expect(!model.canPerform(action) && !model.perform(action), "\(action.title) runs in the grid")
        }
        #expect(model.perform(.compareView))
        let compare = model.libraryCompare
        #expect(model.canPerform(.swapCompared) && model.canPerform(.makeSelect))
        #expect(model.perform(.swapCompared))
        #expect(names([compare.select, compare.candidate]) == names([photos[2], photos[1]]))
        #expect(model.perform(.makeSelect))
        #expect(names([compare.select, compare.candidate]) == names([photos[1], photos[2]]))
        #expect(model.activity.events.contains { $0.kind == .action && $0.text == "Swap Select and Candidate" })

        try await fixture.settle()
        let view = modules.content.library.compare
        #expect(view.swap.accessibilityPerformPress())
        #expect(names([compare.select, compare.candidate]) == names([photos[2], photos[1]]))
        #expect(view.makeSelect.accessibilityPerformPress())
        #expect(names([compare.select, compare.candidate]) == names([photos[1], photos[2]]))
        #expect(view.swap.toolTip == "Swap (↓)" && view.makeSelect.toolTip == "Make Select (↑)")

        #expect(model.perform(.surveyView))
        #expect(!model.canPerform(.swapCompared) && !model.perform(.makeSelect), "Survey keeps ↑ and ↓ for its rows")
        #expect(model.perform(.compareView))
        model.showModule(.develop)
        #expect(!model.canPerform(.swapCompared) && !model.perform(.swapCompared), "Develop leaves Compare alone")
    }
}
