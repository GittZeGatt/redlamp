import AppKit
import Foundation
import RedlampCanvas
import RedlampEngineAPI
import SwiftUI
import Testing
@testable import RedlampUI

/// The editor's panel columns, as its split view lays them out from the model's visibility.
@MainActor
struct EditorPanelsTests {
    /// Hidden and shown again while the window can't be seen (behind another window, or on a display
    /// that sleeps), the panels are back on the window, not left where they slide in from.
    @Test func `panels hidden and shown again while the window is covered come back onto it`() async throws {
        _ = NSApplication.shared
        let model = EditorModel(engine: StubEngine())
        let controller = EditorWindowController(
            model: model, theme: ThemeSettings(), onOpen: {}, onExport: {}, onExportWithPrevious: {},
        )
        let window = try #require(controller.window)
        window.orderFront(nil)
        let cover = NSWindow(contentRect: window.frame, styleMask: .borderless, backing: .buffered, defer: false)
        cover.level = .floating
        cover.backgroundColor = .black
        cover.orderFrontRegardless()
        defer {
            cover.orderOut(nil)
            window.orderOut(nil)
        }
        // Where the window server doesn't report the window covered, the panels slide as on screen.
        for _ in 0 ..< 300 where window.occlusionState.contains(.visible) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(300))

        // As the regression suite's checks of Tab and F7 do: both panels hidden and shown, then the left.
        model.leftPanelVisible = false
        model.rightPanelVisible = false
        try await Task.sleep(for: .milliseconds(100))
        model.leftPanelVisible = true
        model.rightPanelVisible = true
        try await Task.sleep(for: .milliseconds(500))
        model.leftPanelVisible = false
        try await Task.sleep(for: .milliseconds(100))
        model.leftPanelVisible = true
        try await Task.sleep(for: .milliseconds(1000))

        let bounds = try #require(window.contentView?.bounds)
        let panels = try splitItems(of: window).filter { $0.behavior != .default }
        #expect(panels.count == 2)
        for item in panels {
            let view = item.viewController.view
            let frame = view.convert(view.bounds, to: nil)
            #expect(!item.isCollapsed)
            #expect(
                bounds.contains(frame),
                "\(item.behavior == .sidebar ? "the sidebar" : "the inspector") at \(frame)",
            )
        }
        #expect(model.leftPanelVisible && model.rightPanelVisible)
    }

    /// A slide the window stops drawing (covered, on a display that sleeps, or going to or from full screen) can stop
    /// part of the way, AppKit's slide width holding each panel across the window's edge while its item says it's
    /// shown: three quarters of the way in, the sidebar's first letters and the inspector's values are cut off. As the
    /// window's occlusion changes, a panel left part of the way is put where its item says, at its width.
    @Test func `panels a slide leaves part of the way are put back as the window's occlusion changes`() async throws {
        _ = NSApplication.shared
        let model = EditorModel(engine: StubEngine())
        let controller = EditorWindowController(
            model: model, theme: ThemeSettings(), onOpen: {}, onExport: {}, onExportWithPrevious: {},
        )
        let window = try #require(controller.window)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let bounds = try #require(window.contentView?.bounds)
        let panels = try splitItems(of: window).filter { $0.behavior != .default }
        try #require(panels.count == 2)
        let widths = panels.map(\.viewController.view.bounds.width)
        func frame(_ item: NSSplitViewItem) -> CGRect {
            let view = item.viewController.view
            return view.convert(view.bounds, to: nil)
        }
        model.leftPanelVisible = false
        model.rightPanelVisible = false
        for _ in 0 ..< 100 where panels.contains(where: { !$0.isCollapsed }) {
            try await Task.sleep(for: .milliseconds(10))
        }

        // As the split view slides them back in while the window can be seen.
        for item in panels {
            item.animator().isCollapsed = false
        }
        for _ in 0 ..< 50 where panels.allSatisfy({ bounds.contains(frame($0)) }) {
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(panels.contains { !bounds.contains(frame($0)) }, "the panels part of the way in")
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)

        for item in panels {
            #expect(
                bounds.contains(frame(item)),
                "\(item.behavior == .sidebar ? "the sidebar" : "the inspector") at \(frame(item))",
            )
        }
        try await Task.sleep(for: .milliseconds(600))
        for (item, width) in zip(panels, widths) {
            #expect(!item.isCollapsed && bounds.contains(frame(item)), "after the slide's time, at \(frame(item))")
            #expect(item.viewController.view.bounds.width == width)
        }
        #expect(model.leftPanelVisible && model.rightPanelVisible)
    }

    /// The Library and Develop picker sits in the middle of the window, whichever panels show and whichever module is
    /// shown, rather than after the window's title; the toolbar has no Open Folder button (the Folders panel's +
    /// adds folders, and File › Open Folder… and ⌘O open one).
    @Test func `the module picker is centred on the window, with or without either panel`() async throws {
        _ = NSApplication.shared
        let model = EditorModel(engine: StubEngine())
        let controller = EditorWindowController(
            model: model, theme: ThemeSettings(), onOpen: {}, onExport: {}, onExportWithPrevious: {},
        )
        let window = try #require(controller.window)
        // The window keeps its frame by name, and other tests leave it at its smallest.
        window.setContentSize(CGSize(width: 1600, height: 1000))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let toolbar = try #require(window.toolbar)
        #expect(!toolbar.items.contains { $0.itemIdentifier.rawValue == "openFolder" || $0.label == "Open Folder" })
        func views(in view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(views)
        }
        let item = try #require(toolbar.items.first { $0.itemIdentifier.rawValue == "modules" }?.view)
        let picker = try #require(views(in: item).first { $0 is ModulePickerView })
        for (left, right, module) in [
            (true, true, AppModule.develop), (false, true, .develop), (true, false, .develop), (false, false, .develop),
            (true, true, .library), (false, false, .library),
        ] {
            model.module = module
            model.leftPanelVisible = left
            model.rightPanelVisible = right
            try await Task.sleep(for: .milliseconds(150))
            window.layoutIfNeeded()
            let middle = picker.convert(picker.bounds, to: nil).midX
            #expect(
                abs(middle - window.frame.width / 2) <= 1,
                "\(module), sidebar \(left), inspector \(right): the picker's middle at \(middle)",
            )
        }
    }

    /// #358: Tab hides the side panels for a bigger view of the photo, as in Lightroom. At Fit the photo
    /// grows into the room they leave and is rendered again at its new size; F7 and F8 give one side's.
    @Test func `hiding the side panels gives the photo their room, rendered again at its new size`() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = StubEngine()
        engine.pixelSize = PixelSize(width: 6000, height: 4000)
        let model = EditorModel(engine: engine)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1400, height: 640), styleMask: [.titled],
            backing: .buffered, defer: false,
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: EditorContentView(model: model, theme: ThemeSettings(), onOpen: {}),
        )
        defer { window.contentView = nil }
        model.select(folder.appending(path: "IMG_0001.ARW"))
        let canvas = model.canvas
        func eventually(_ condition: () -> Bool) async throws {
            for _ in 0 ..< 400 where !condition() {
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        /// At Fit, rendered at the size the stage needs.
        func rendered() -> Bool {
            engine.lastRender?.targetSize == canvas.renderTarget.size
        }

        try await eventually {
            canvas.imageSize == engine.pixelSize && canvas.viewSize.width > 0 && canvas.stageInsets.leading > 0
                && rendered()
        }
        let shown = canvas.stageInsets
        let fit = canvas.imageRect(in: canvas.viewSize)
        let size = canvas.renderTarget.size
        #expect(shown.leading == PanelMetrics.inset + PanelMetrics.sidebarNominal + PanelMetrics.inset)
        #expect(shown.trailing == PanelMetrics.inspectorNominal + PanelMetrics.inset)

        #expect(model.perform(.toggleSidePanels))
        try await eventually { canvas.stageInsets != shown && rendered() }
        #expect(!model.leftPanelVisible && !model.rightPanelVisible)
        #expect(canvas.stageInsets == StageInsets(
            leading: PanelMetrics.inset, trailing: PanelMetrics.inset, top: shown.top, bottom: shown.bottom,
        ))
        let grown = canvas.imageRect(in: canvas.viewSize)
        let stage = canvas.stage(in: canvas.viewSize)
        #expect(grown.width > fit.width && grown.height > fit.height, "\(grown.size), from \(fit.size)")
        #expect(abs(grown.width - stage.width) < 0.5 || abs(grown.height - stage.height) < 0.5, "it fills the stage")
        #expect(rendered() && canvas.renderTarget.size.width > size.width, "rendered at \(canvas.renderTarget.size)")

        #expect(model.perform(.toggleSidePanels))
        try await eventually { canvas.stageInsets == shown && rendered() }
        #expect(canvas.imageRect(in: canvas.viewSize) == fit, "Tab again gives the panels their room back")
        #expect(canvas.renderTarget.size == size)

        #expect(model.perform(.toggleLeftPanel))
        try await eventually { canvas.stageInsets != shown }
        #expect(canvas.stageInsets.leading == PanelMetrics.inset && canvas.stageInsets.trailing == shown.trailing)
        #expect(model.perform(.toggleLeftPanel))
        #expect(model.perform(.toggleRightPanel))
        try await eventually { canvas.stageInsets.trailing != shown.trailing }
        #expect(canvas.stageInsets.leading == shown.leading && canvas.stageInsets.trailing == PanelMetrics.inset)
    }

    private func splitItems(of window: NSWindow) throws -> [NSSplitViewItem] {
        func controllers(_ controller: NSViewController) -> [NSViewController] {
            [controller] + controller.children.flatMap(controllers)
        }
        let root = try #require(window.contentViewController)
        let split = try #require(controllers(root).lazy.compactMap { $0 as? NSSplitViewController }.first)
        return split.splitViewItems
    }
}
