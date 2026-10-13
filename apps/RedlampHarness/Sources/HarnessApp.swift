import AppKit
import RedlampLab
@_spi(Harness) import RedlampUI
import SwiftUI

@main
struct HarnessApp: App {
    @NSApplicationDelegateAdaptor(HarnessAppDelegate.self) private var appDelegate

    init() {
        ThemeSettings.turnOffDesktopTinting()
    }

    var body: some Scene {
        WindowGroup("Redlamp Harness") {
            HarnessRootView()
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1400, height: 900)
        .commands {
            // The keys the app's menus bind, so the command palette scenes behave as the app.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { PaletteSession.shared.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo") { PaletteSession.shared.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .textEditing) {
                Button("Command Palette…") { PaletteSession.shared.toggle(.all) }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Find Slider…") { PaletteSession.shared.toggle(.sliders) }
                    .keyboardShortcut("f", modifiers: .command)
            }
        }
    }
}

/// The Recipe Lab's bench hub runs for as long as the harness does, so the iPhone app can reach
/// it from any scene; a `.redtask` opened from the Finder or AirDrop is filed by it.
final class HarnessAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    func applicationDidFinishLaunching(_: Notification) {
        LabBench.shared.startIfEnabled()
        HarnessLab.connectBench()
        if HarnessLaunch.value(after: "--snapshot") != nil {
            // A Library scene takes it once its surface is open; the delay is then how long it may take.
            let library = HarnessLaunch.value(after: "--library-surface") != nil
            let delay = HarnessLaunch.value(after: "--snapshot-delay").flatMap(Double.init) ?? (library ? 180 : 8)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Self.snapshotIfRequested() }
        }
    }

    /// `--snapshot <path>`: the window as its views draw it, without Screen Recording, then quit.
    /// Views backed by Metal layers draw blank, so it suits SwiftUI scenes like the Lab's tabs. A window or sheet a
    /// Library scene opened is captured instead, on its own.
    @MainActor
    static func snapshotIfRequested() {
        guard let path = HarnessLaunch.value(after: "--snapshot") else { return }
        let url = URL(fileURLWithPath: path)
        let harness = LibrarySceneState.harnessWindow
        let opened = harness?.attachedSheet
            ?? NSApp.windows.first { $0.isVisible && $0 !== harness && $0.sheetParent == nil && $0.canBecomeMain }
        if let window = opened ?? NSApp.windows.first(where: \.isVisible), let view = window.contentView,
           let rep = image(of: view, in: window) {
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        // The app doesn't quit while a sheet is up.
        if let harness, let sheet = harness.attachedSheet {
            harness.endSheet(sheet)
        }
        NSApp.terminate(nil)
    }

    /// `view` drawn over its window's background colour: a sheet's glass is its window's, not drawn by its views.
    @MainActor
    private static func image(of view: NSView, in window: NSWindow) -> NSBitmapImageRep? {
        // At 1x: a view drawn into a context of its own doesn't take the context's scale.
        let scale: CGFloat = 1
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale),
            pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = view.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: view.bounds.size).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        view.displayIgnoringOpacity(view.bounds, in: context)
        return rep
    }

    @MainActor
    func application(_: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "redtask" {
            LabBench.shared.receive(url)
        }
    }
}
