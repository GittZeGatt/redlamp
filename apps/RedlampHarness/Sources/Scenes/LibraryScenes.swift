import AppKit
import Observation
@_spi(Harness) import RedlampUI
import SwiftUI

extension HarnessScene {
    static var libraryImport: HarnessScene {
        HarnessScene(
            id: "library-import",
            title: "Import Photos",
            symbol: "sdcard",
            synopsis: "The import window on a card, part of it already in the library, in each state",
            section: .library,
        ) {
            LibraryScene(surfaces: [.importPhotos], states: [.opened, .finished, .interrupted, .minimum])
        }
    }

    static var libraryLightroom: HarnessScene {
        HarnessScene(
            id: "library-lightroom",
            title: "Lightroom Classic",
            symbol: "square.stack.3d.down.right",
            synopsis: "Import from Lightroom Classic on a catalog with roots in, out of and missing from the library",
            section: .library,
        ) {
            LibraryScene(surfaces: [.lightroom], states: [.noCatalog, .opened, .imported, .undone, .minimum])
        }
    }

    static var librarySheets: HarnessScene {
        HarnessScene(
            id: "library-sheets",
            title: "Sheets",
            symbol: "rectangle.on.rectangle",
            synopsis: "Every library sheet over this window, on a library of the harness's own",
            section: .library,
        ) {
            LibraryScene(
                surfaces: LibrarySurface.allCases.filter { $0 != .importPhotos && $0 != .lightroom }, states: [.opened],
            )
        }
    }
}

/// What a surface shows when it opens.
enum LibrarySurfaceState: String, CaseIterable, Identifiable {
    case opened, noCatalog = "no-catalog", finished, interrupted, imported, undone, minimum

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .opened: "Open"
        case .noCatalog: "No catalog"
        case .finished: "Finished"
        case .interrupted: "Interrupted"
        case .imported: "Imported"
        case .undone: "Undone"
        case .minimum: "At its minimum size"
        }
    }
}

/// Opens the Library scenes' surfaces, one at a time, closing the one before.
@MainActor @Observable
final class LibrarySceneState {
    static let shared = LibrarySceneState()

    private(set) var status = "Opening the harness's library…"
    private(set) var isReady = false
    @ObservationIgnored private var launched = false

    private var model: EditorModel {
        HarnessLibrary.model
    }

    func prepare() async {
        await HarnessLibrary.ready()
        isReady = true
        status = "\(model.items.count) photos in \(HarnessLibrary.fixture.photos.path)"
    }

    /// `--library-surface <id>` and `--library-state <state>` at launch, for the scene that has the surface.
    func openRequested(among surfaces: [LibrarySurface]) async {
        guard !launched, let id = HarnessLaunch.value(after: "--library-surface"),
              let surface = surfaces.first(where: { $0.id == id })
        else { return }
        launched = true
        let state = HarnessLaunch.value(after: "--library-state").flatMap(LibrarySurfaceState.init) ?? .opened
        await open(surface, state)
        try? await Task.sleep(for: .seconds(2))
        HarnessAppDelegate.snapshotIfRequested()
    }

    func open(_ surface: LibrarySurface, _ state: LibrarySurfaceState) async {
        let harness = Self.harnessWindow
        EditorWindowController.harnessWindow = harness
        model.closeHarnessSurface(over: harness)
        harness?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(300))
        var fixture = HarnessLibrary.fixture
        if state == .noCatalog {
            fixture.catalog = nil
        }
        guard await model.openHarnessSurface(surface, fixture: fixture) else {
            status = "\(surface.title) didn't open: it needs a selection, a collection or a keyword the library lacks"
            return
        }
        status = "\(surface.title): \(state.title)"
        switch state {
        case .finished:
            await ImportWindowController.current?.importAndWait()
        case .interrupted:
            ImportWindowController.current?.simulateForcedQuit(afterPhotos: 3)
            await ImportWindowController.current?.importAndWait()
            ImportWindowController.current?.close()
            await model.openHarnessSurface(surface, fixture: fixture)
        case .imported, .undone:
            guard let window = await until({ LightroomWindowController.current?.isReported == true }) else { return }
            window.pressImport()
            guard await until({ LightroomWindowController.current?.isImported == true }) != nil, state == .undone
            else { return }
            window.pressUndoImport()
        case .minimum:
            for window in [ImportWindowController.current?.window, LightroomWindowController.current?.window] {
                guard let window else { continue }
                window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: true)
            }
        case .opened, .noCatalog:
            break
        }
    }

    private func until(_ condition: () -> Bool) async -> LightroomWindowController? {
        for _ in 0 ..< 600 where !condition() {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition() ? LightroomWindowController.current : nil
    }

    static var harnessWindow: NSWindow? {
        NSApp.windows.first { window in
            window.isVisible && window.canBecomeMain && window.sheetParent == nil
                && !(window.windowController is ImportWindowController)
                && !(window.windowController is LightroomWindowController)
        }
    }
}

private struct LibraryScene: View {
    let surfaces: [LibrarySurface]
    let states: [LibrarySurfaceState]
    @State private var state = LibrarySceneState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(state.status).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(surfaces) { surface in
                    GridRow {
                        Text(surface.title)
                        HStack {
                            ForEach(states) { surfaceState in
                                Button(surfaceState.title) {
                                    Task { await state.open(surface, surfaceState) }
                                }
                            }
                        }
                    }
                }
            }
            .disabled(!state.isReady)
            SpecimenGroup(title: "Look for", note: """
            Labels and fields lined up in their columns, nothing clipped or truncated that has room, the Mac's \
            margins (20 points) and spacing, a heading on every sheet, and the same in light and dark (the theme \
            controls below the scene list). Each sheet opens over this window; Cancel closes it.
            """) {
                EmptyView()
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .task {
            await state.prepare()
            await state.openRequested(among: surfaces)
        }
    }
}
