import AppKit
import RedlampDesign
import SwiftUI
import Testing
@_spi(Harness) @testable import RedlampUI

/// Every scroller is drawn for the theme's appearance, whatever the system's: a scroll view that resolves the other
/// draws that appearance's scroller, a light knob and track on a dark sheet or a dark one on a light, as do the
/// other native controls around it.
@MainActor
struct ThemeAppearanceTests {
    @Test func `the windows' scroll views take the theme's appearance, not the system's`() async throws {
        _ = NSApplication.shared
        NSApp.appearance = nil
        let system = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        let suite = "theme-appearance-\(UUID().uuidString)"
        let theme = try ThemeSettings(defaults: #require(UserDefaults(suiteName: suite)))
        theme.selection.appearance = system == .darkAqua ? .light : .dark
        let expected: NSAppearance.Name = theme.selection.appearance == .dark ? .darkAqua : .aqua

        let folder = RenameTests.RenameFolder()
        try await folder.open()
        let model = try #require(folder.model)
        let controller = EditorWindowController(
            model: model, theme: theme, onOpen: {}, onExport: {}, onExportWithPrevious: {},
        )
        let editor = try #require(controller.window)
        editor.orderFront(nil)
        model.showShortcuts = true

        let sheet = try await folder.sheet()
        let rename = NSWindow(contentViewController: RenameSheetController(model: sheet, editor: model))
        editor.beginSheet(rename, completionHandler: nil)

        let imports = try await ImportWindowFixture.make()
        let importWindow = try #require(ImportWindowController(model: imports.model()).window)
        importWindow.orderFront(nil)

        let settings = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(theme: theme)))
        settings.orderFront(nil)
        defer {
            for window in [settings, importWindow, editor] {
                window.orderOut(nil)
            }
            editor.endSheet(rename)
            imports.remove()
            folder.cleanUp()
            NSApp.appearance = nil
            UserDefaults().removePersistentDomain(forName: suite)
        }
        try await Task.sleep(for: .milliseconds(600))

        let windows = [
            "the editor window": editor,
            "the Rename sheet": rename,
            "the import window": importWindow,
            "Settings": settings,
        ]
        for (name, window) in windows {
            let scrollViews = Self.scrollViews(in: window.contentView?.superview)
            #expect(!scrollViews.isEmpty, "\(name) has no scroll view")
            for scrollView in scrollViews {
                let resolved = scrollView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
                #expect(resolved == expected, "\(name): \(type(of: scrollView)) in \(Self.path(of: scrollView))")
            }
        }
        let shortcuts = Self.scrollViews(in: editor.contentView).filter {
            !($0 is OverlayScrollView) && !($0 is FilmstripScrollView)
        }
        #expect(!shortcuts.isEmpty, "the Shortcuts sheet's scroll view isn't in the editor window")
    }

    private static func scrollViews(in view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        return ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private static func path(of view: NSView) -> String {
        let ancestors = sequence(first: view, next: \.superview).dropFirst().prefix(5)
        return ancestors.map { "\(type(of: $0))" }.joined(separator: " < ")
    }
}
