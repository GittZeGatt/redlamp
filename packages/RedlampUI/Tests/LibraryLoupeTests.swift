import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import RedlampUI

/// The Library loupe's zoom (LIB-14): fit and 1:1, by Z and by a click, from the preview and then the
/// photo itself, with the photo's name shown.
@MainActor
struct LibraryLoupeTests {
    /// Photos 1200 by 800 pixels: their previews at most 2048, so the same.
    private nonisolated static func photo(_ size: Int) -> CGImage? {
        ModuleFixture.image(min(size, 1200))
    }

    private func click(_ loupe: LibraryLoupeView, at point: CGPoint) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: loupe.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: loupe.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1,
            ))
            if type == .leftMouseDown {
                loupe.mouseDown(with: event)
            } else {
                loupe.mouseUp(with: event)
            }
        }
    }

    @Test func `the Z key and a click zoom the loupe to 1:1 from the photo itself and fit it again`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        fixture.engine.decodedThumbnail = { _, size in Self.photo(size) }
        try await fixture.open(count: 5)
        let modules = fixture.showModules()
        let model = fixture.model
        let loupe = modules.content.library.loupe
        model.showLibrary(.loupe)
        try await fixture.settle()
        loupe.layoutSubtreeIfNeeded()
        try await fixture.eventually { loupe.showsPreview }
        #expect(loupe.accessibilityLabel() == fixture.photos[0].lastPathComponent, "the photo's name is shown")
        let fitted = loupe.photoFrame
        let scale = loupe.window?.backingScaleFactor ?? 2
        #expect(model.libraryViews.loupeZoom == .fit && fitted.width > 0 && fitted.height > 0)
        #expect(abs(fitted.width / fitted.height - 1.5) < 0.01, "the photo keeps its shape")

        let toolbar = modules.content.library.toolbar
        toolbar.layoutSubtreeIfNeeded()
        let fit = try #require(toolbar.subviews.first { $0.accessibilityIdentifier() == "library.toolbar.fit" })
        let middle = toolbar.convert(CGPoint(x: fit.frame.midX, y: fit.frame.midY), to: toolbar.superview)
        #expect(toolbar.hitTest(middle) === fit, "the grid's buttons, hidden in the loupe, take no clicks")

        #expect(model.canPerform(.toggleZoom) && model.perform(.toggleZoom))
        #expect(model.libraryViews.loupeZoom == .actual)
        try await fixture.eventually { loupe.showsFullPhoto }
        #expect(loupe.showsFullPhoto, "1:1 decodes the photo itself")
        #expect(loupe.image?.width == 1200)
        #expect(abs(loupe.photoFrame.width - 1200 / scale) < 0.5, "one of the photo's pixels to one of the screen's")

        try click(loupe, at: CGPoint(x: loupe.bounds.midX, y: loupe.bounds.midY))
        #expect(model.libraryViews.loupeZoom == .fit, "a click fits it again")
        #expect(loupe.photoFrame == fitted)
        try click(loupe, at: CGPoint(x: fitted.minX + fitted.width / 4, y: fitted.midY))
        #expect(model.libraryViews.loupeZoom == .actual, "a click zooms where it lands")
        #expect(abs(loupe.focus.x - 0.25) < 0.02 && abs(loupe.focus.y - 0.5) < 0.02)
        try await fixture.settle()
        #expect(abs(loupe.photoFrame.width - 1200 / scale) < 0.5)

        model.perform(.nextPhoto)
        try await fixture.eventually { loupe.accessibilityLabel() == fixture.photos[1].lastPathComponent }
        #expect(model.libraryViews.loupeZoom == .actual, "the next photo is shown at the same zoom")
        model.showLibrary(.grid)
        #expect(!model.canPerform(.toggleZoom) && !model.perform(.toggleZoom), "Space and Z go on to the grid")
        model.showModule(.develop)
        #expect(model.perform(.toggleZoom) && model.libraryViews.loupeZoom == .actual, "Develop's Z zooms its canvas")
    }

    @Test func `the caption shows the date and settings in whole fields, as many as its width does, never part of one`(
    ) throws {
        var details = PhotoDetails()
        details.captured = Date(timeIntervalSinceReferenceDate: 542_652_000)
        details.shutter = 1.0 / 50
        details.aperture = 4
        details.iso = 400
        details.focal = 32
        let fields = ["1/50 s", "ƒ/4", "ISO 400", "32 mm"]
        let steps = [""] + (0 ... fields.count).map { count in
            [details.date, fields.prefix(count).joined(separator: "  ")].filter { !$0.isEmpty }
                .joined(separator: "  ·  ")
        }
        func width(_ text: String) -> CGFloat {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            return label.intrinsicContentSize.width
        }
        var shown: Set<String> = []
        for room in stride(from: CGFloat(0), through: 420, by: 3) {
            let caption = LibraryLoupeView.caption(details, width: room)
            let step = try #require(steps.firstIndex(of: caption), "\(room): “\(caption)” is whole fields")
            #expect(caption.isEmpty || width(caption) <= room, "\(room): the caption shows all of “\(caption)”")
            #expect(step == steps.count - 1 || width(steps[step + 1]) > room, "\(room): and a field more doesn't fit")
            shown.insert(caption)
        }
        #expect(shown == Set(steps), "from nothing to the whole caption")
    }
}
