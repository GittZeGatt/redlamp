import AppKit
import CoreGraphics
import Foundation
import ImageIO
import RedlampEngineAPI
import RedlampLibrary
import Testing
import UniformTypeIdentifiers
@_spi(Harness) @testable import RedlampUI

/// A folder the library has indexed, with stacks for it to find (LIB-28), in `LibrarySandbox.scratch`, a library and
/// defaults of its own: a burst of three frames a third of a second apart, B01 to B03; a JPEG beside its HEIC, P01, a
/// minute later; S01 to S04 alone, ten minutes apart; and in its subfolder Other, which it's shown without, a burst of
/// two, O01 and O02, and O03 alone. Open in an editor, its grid and filmstrip in a window of their own.
@MainActor
final class StackFolder {
    struct Photo {
        var path: String
        /// Seconds after 10:00 on 14 June 2024.
        var time: Double
        var type = UTType.jpeg
    }

    static let photos = [
        Photo(path: "B01.JPG", time: 0), Photo(path: "B02.JPG", time: 0.33), Photo(path: "B03.JPG", time: 0.66),
        Photo(path: "P01.JPG", time: 60), Photo(path: "P01.HEIC", time: 60, type: .heic),
        Photo(path: "S01.JPG", time: 600), Photo(path: "S02.JPG", time: 1200), Photo(path: "S03.JPG", time: 1800),
        Photo(path: "S04.JPG", time: 2400),
    ]
    static let others = [
        Photo(path: "Other/O01.JPG", time: 3000), Photo(path: "Other/O02.JPG", time: 3000.5),
        Photo(path: "Other/O03.JPG", time: 3600),
    ]

    let base = LibrarySandbox.scratch.appending(path: "stack-folder-\(UUID().uuidString)", directoryHint: .isDirectory)
        .standardizedFileURL
    let suite = "stack-folder-tests-\(UUID().uuidString)"
    private(set) var service: LibraryService?
    private(set) var model: EditorModel!
    private(set) var grid: LibraryGridView!
    private(set) var filmstrip: FilmstripStripView!
    private(set) var window: NSWindow!

    var root: URL {
        base.appending(path: "Photos", directoryHint: .isDirectory)
    }

    var other: URL {
        root.appending(path: "Other", directoryHint: .isDirectory)
    }

    private func write(_ photo: Photo) throws {
        let url = root.appending(path: photo.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ))
        context.setFillColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data, photo.type.identifier as CFString, 1, nil,
        ))
        let whole = photo.time.rounded(.down)
        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "FUJIFILM", kCGImagePropertyTIFFModel: "X-T5"],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: String(
                    format: "2024:06:14 %02d:%02d:%02d", 10 + Int(whole) / 3600, Int(whole) % 3600 / 60,
                    Int(whole) % 60,
                ),
                kCGImagePropertyExifSubsecTimeOriginal: String(format: "%02d", Int((photo.time - whole) * 100)),
                kCGImagePropertyExifExposureTime: 1.0 / 500,
            ],
        ]
        try CGImageDestinationAddImage(destination, #require(context.makeImage()), properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url)
    }

    /// Writes the photos, indexes them, and opens the folder in Library's grid, its stacks not yet found.
    func open() async throws {
        for photo in Self.photos + Self.others {
            try write(photo)
        }
        let library = FolderLibrary(defaults: UserDefaults(suiteName: suite))
        library.setIncludesSubfolders(false)
        library.add([root])
        let service = LibraryService(
            paths: LibraryPaths(root: base.appending(path: "Library", directoryHint: .isDirectory)),
            sidecars: library.sidecars, defaults: UserDefaults(suiteName: suite)!,
        ) { url, size in
            StoreThumbnailMaker.imageIO(url, nil, size)
        }
        self.service = service
        library.attach(service)
        let deadline = ContinuousClock.now + .seconds(30)
        while await !service.canShow(root, includingSubfolders: true), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        model = EditorModel(engine: StubEngine(), library: library)
        model.open([root])
        try await eventually { library.isShownFromLibrary && !library.isListing && library.count == Self.photos.count }
        try #require(library.isShownFromLibrary && library.count == Self.photos.count, "the folder shown")
        model.showLibrary(.grid)
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 1200), styleMask: [.borderless], backing: .buffered,
            defer: false,
        )
        grid = LibraryGridView(model: model)
        filmstrip = FilmstripStripView(model: model)
        let content = NSView(frame: window.contentLayoutRect)
        grid.frame = CGRect(x: 0, y: FilmstripStripView.height, width: 900, height: 1200 - FilmstripStripView.height)
        filmstrip.frame = CGRect(x: 0, y: 0, width: 900, height: FilmstripStripView.height)
        content.addSubview(grid)
        content.addSubview(filmstrip)
        window.contentView = content
        content.layoutSubtreeIfNeeded()
    }

    func cleanUp() {
        window?.contentView = nil
        LibrarySandbox.remove(base, closing: [service])
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func eventually(seconds: Double = 30, _ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while try !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Waits until the source's stacks are found, `open` of them open and `closed` closed.
    func waitForStacks(open: Int, closed: Int, _ comment: Comment) async throws {
        try await eventually {
            model.gridStacks.list.map {
                $0.list.source == model.library.photoList.source && $0.stacksShown == (open, closed)
            } == true
        }
        let shown = model.gridStacks.list?.stacksShown
        try #require(shown.map { $0 == (open, closed) } == true, "\(comment): \(String(describing: shown))")
    }

    func url(_ name: String) throws -> URL {
        try #require(model.items.first { $0.url.lastPathComponent == name }?.url)
    }

    func id(_ name: String) throws -> Int64 {
        try #require(model.library.photoID(of: url(name)))
    }

    /// The photos with cells in the grid, by name, in its order.
    var cells: [String] {
        (0 ..< grid.shownCount).compactMap { grid.row(ofItem: $0) }.map { model.items[$0].url.lastPathComponent }
    }

    /// The photos with cells in the filmstrip, by name, in its order.
    var strip: [String] {
        let count = filmstrip.collectionView.numberOfItems(inSection: 0)
        return (0 ..< count).compactMap { filmstrip.row(ofItem: $0) }.map { model.items[$0].url.lastPathComponent }
    }

    /// The photos, by name, of the burst or stack made by hand holding `name`, in its order.
    func stack(holding name: String) throws -> [String]? {
        try model.gridStacks.list?.stacks.stack(containing: id(name))?.photos
            .compactMap { model.library.url(ofPhoto: $0)?.lastPathComponent }
    }

    /// The filmstrip's cell for `name`, laid out and on screen.
    func stripCell(_ name: String) throws -> FilmstripCellView {
        filmstrip.collectionView.layoutSubtreeIfNeeded()
        let cell = filmstrip.collectionView.subviews.compactMap { $0 as? FilmstripCellView }
            .first { $0.item?.url.lastPathComponent == name }
        return try #require(cell, "\(name) has a cell in the filmstrip")
    }

    /// A mouse event at `point` in the window.
    func mouse(_ type: NSEvent.EventType, at point: NSPoint, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1,
        ))
    }

    /// Presses the filmstrip's cell of `name`, drags it in `steps` moves onto the cell of `target`, or by `offset`
    /// points when there's no target, and lets go there, as the mouse does, through the regression suite's dragging
    /// session.
    func dragInStrip(_ name: String, onto target: String?, by offset: CGFloat = 0, steps: Int = 6) throws {
        let cell = try stripCell(name)
        let from = cell.convert(CGPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: nil)
        let to = try target.map { name in
            let cell = try stripCell(name)
            return cell.convert(CGPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: nil)
        } ?? CGPoint(x: from.x + offset, y: from.y)
        let simulated = LibraryDrags.simulates
        LibraryDrags.simulates = true
        defer { LibraryDrags.simulates = simulated }
        try cell.mouseDown(with: mouse(.leftMouseDown, at: from))
        for step in 1 ... steps {
            let t = CGFloat(step) / CGFloat(steps)
            try cell.mouseDragged(with: mouse(
                .leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t),
            ))
        }
        try cell.mouseUp(with: mouse(.leftMouseUp, at: to))
    }
}
