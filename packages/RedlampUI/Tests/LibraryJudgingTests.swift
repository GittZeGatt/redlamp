import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import RedlampUI

/// The judging tools in the Library loupe and Compare (LIB-38): their buttons and Develop's ⌥J, each tool drawn over
/// the photo as it comes with the photo on screen first, both of Compare's photos at once, and the following loupe.
@MainActor
struct LibraryJudgingTests {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "tests/fixtures")

    /// A sharp board of greys, 1200 by 800 at most: every photo's previews and the photo itself.
    private nonisolated static func board(_ size: Int) -> CGImage? {
        let (width, height) = (min(size, 1200), min(size, 1200) * 2 / 3)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ) else { return nil }
        context.setFillColor(gray: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 0.85, alpha: 1)
        for column in stride(from: 0, to: width, by: 100) {
            context.fill(CGRect(x: column, y: 0, width: 50, height: height))
        }
        return context.makeImage()
    }

    /// The modules shown in the loupe over five photos, the first a Sony raw whose maker notes give an AF point,
    /// sensor clipping read through `engine`.
    private func loupe(_ fixture: ModuleFixture, engine: FakeClippingEngine) async throws -> ModuleWindow {
        fixture.engine.decodedThumbnail = { _, size in Self.board(size) }
        try await fixture.open(count: 5)
        let sony = Self.fixtures.appending(path: "cameras/Sony_ILCE-7M4.ARW")
        if FileManager.default.fileExists(atPath: sony.path) {
            try FileManager.default.removeItem(at: fixture.photos[0])
            try FileManager.default.copyItem(at: sony, to: fixture.photos[0])
        }
        fixture.model.libraryJudging.clipping = SensorClipping { engine }
        let modules = fixture.showModules()
        fixture.model.showLibrary(.loupe)
        try await fixture.settle()
        modules.content.library.loupe.layoutSubtreeIfNeeded()
        try await fixture.eventually { modules.content.library.loupe.image != nil }
        return modules
    }

    private func optionJ(_ window: NSWindow?) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil, characters: "∆", charactersIgnoringModifiers: "j",
            isARepeat: false, keyCode: 38,
        ))
    }

    /// Points a window's coordinates bring back a hair off.
    private func close(_ point: CGPoint?, _ expected: CGPoint) -> Bool {
        guard let point else { return false }
        return abs(point.x - expected.x) < 0.01 && abs(point.y - expected.y) < 0.01
    }

    private func move(_ view: NSView, to point: CGPoint) throws {
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0,
        ))
        view.mouseMoved(with: event)
    }

    @Test func `the bar's buttons turn each tool on and off, sensor clipping as Develop's own setting`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        let modules = try await loupe(fixture, engine: .corner())
        let model = fixture.model
        let bar = modules.content.library.loupe.judgingBar
        let judging = model.libraryJudging
        #expect(bar.clipping.toolTip == "Show Sensor Clipping (⌥J)", "Develop's button's name and key")
        #expect(bar.clipping.accessibilityPerformPress() && model.showRawClipping)
        #expect(bar.histogram.accessibilityPerformPress() && judging.showsHistogram)
        #expect(bar.peaking.accessibilityPerformPress() && judging.showsPeaking)
        #expect(bar.afPoint.accessibilityPerformPress() && judging.showsAFPoints)
        #expect(bar.loupe.accessibilityPerformPress() && judging.magnification == .double)
        try await fixture.settle()
        #expect(bar.magnifications.values.allSatisfy { !$0.isHidden }, "the magnifications show while it's on")
        #expect(bar.magnifications[.quadruple]?.accessibilityPerformPress() == true && judging
            .magnification == .quadruple)
        #expect(bar.loupe.accessibilityPerformPress() && judging.magnification == nil)
        #expect(bar.loupe.accessibilityPerformPress() && judging.magnification == .quadruple, "back at its last")
        try await fixture.settle()
        #expect(bar.clipping.isOn && bar.histogram.isOn && bar.peaking.isOn && bar.afPoint.isOn && bar.loupe.isOn)
        let compareBar = modules.content.library.compare.judgingBar
        #expect(compareBar.clipping.isOn, "Compare's bar shows the same tools")
        #expect(model.activity.events(since: .distantPast).contains { $0.text == "Focus Peaking" })
        for button in [bar.clipping, bar.histogram, bar.peaking, bar.afPoint, bar.loupe] {
            _ = button.accessibilityPerformPress()
        }
        #expect(!model.showRawClipping && !judging.showsHistogram && !judging.showsPeaking && !judging.showsAFPoints)
        #expect(judging.magnification == nil)
    }

    @Test func `⌥J shows sensor clipping from the loupe and Compare, as Develop's key does`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        let modules = try await loupe(fixture, engine: .corner())
        let model = fixture.model
        #expect(!model.perform(.rawClipping), "the key monitor leaves Develop's view keys to Library's views")
        let window = modules.window
        #expect(try window.performKeyEquivalent(with: optionJ(window)) && model.showRawClipping, "in the loupe")
        #expect(try window.performKeyEquivalent(with: optionJ(window)) && !model.showRawClipping)

        model.perform(.compareView)
        try await fixture.settle()
        let compare = modules.content.library.compare
        try compare.keyDown(with: optionJ(window))
        #expect(model.showRawClipping, "in Compare, which has the keyboard")
        #expect(try window.performKeyEquivalent(with: optionJ(window)) && !model.showRawClipping)

        model.showLibrary(.grid)
        try await fixture.settle()
        #expect(try !window.performKeyEquivalent(with: optionJ(window)) && !model.showRawClipping, "not in the grid")
        model.showModule(.develop)
        #expect(model.perform(.rawClipping) && model.showRawClipping, "Develop's own")
    }

    @Test func `the loupe draws each tool over its photo as it comes, the photo shown first`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        let engine = FakeClippingEngine.corner()
        let modules = try await loupe(fixture, engine: engine)
        let model = fixture.model
        let loupe = modules.content.library.loupe
        let judging = loupe.judging
        model.toggleSensorClipping()
        model.toggleRawHistogram()
        model.toggleFocusPeaking()
        model.toggleAFPoints()
        #expect(loupe.image != nil, "the photo stays on screen while the tools read")
        try await fixture.eventually { judging.marks != nil && judging.peakingEntry != nil }
        try await fixture.settle()
        let drawn = judging.drawn
        #expect(drawn.clipping && drawn.peaking && drawn.histogram)
        #expect(judging.clippingFrame == loupe.photoFrame, "the marks lie over the photo")
        #expect(judging.histogram
            .summary == "Clipped on the sensor: red 20%, green 20%, blue 20%, all three 4.0% of the photo")
        if case let .read(reading) = judging.histogram.state {
            #expect(reading.histogram == engine.histogram, "the developed photo's histogram, from the same render")
        }
        #expect(engine.opened.withLock { $0 }.first == fixture.photos[0])
        #expect(
            engine.prefetched.withLock { $0 }.first?.dropFirst().first == fixture.photos[1],
            "the next decoded ahead",
        )
        #expect((judging.peakingEntry?.mask.markedShare ?? 0) > 0.001, "the board's edges are marked")

        if FileManager.default.fileExists(atPath: Self.fixtures.appending(path: "cameras/Sony_ILCE-7M4.ARW").path) {
            try await fixture.eventually { judging.points != nil }
            try await fixture.settle()
            let outline = try #require(judging.afOutline)
            let frame = loupe.photoFrame
            let expected = CGPoint(
                x: frame.minX + frame.width * 3832 / 7008,
                y: frame.minY + frame.height * 2102 / 4672,
            )
            #expect(judging.drawn.afPoints && abs(outline.midX - expected.x) < 1 && abs(outline.midY - expected.y) < 1)
        }

        model.toggleFocusPeaking()
        try await fixture.settle()
        #expect(!judging.drawn.peaking && judging.drawn.clipping, "each tool goes alone")
        model.perform(.nextPhoto)
        try await fixture.settle()
        #expect(loupe.image != nil && judging.url == fixture.photos[1])
        try await fixture.eventually { judging.marks != nil }
        #expect(engine.opened.withLock { $0 } == [fixture.photos[0], fixture.photos[1]])
    }

    @Test func `a photo with no AF point, and one whose preview can't be read, are asked once`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        let peakingReads = ModuleFixture.Counter()
        fixture.engine.decodedThumbnail = { _, size in
            guard size != FocusPeaking.longestEdge else {
                peakingReads.increment()
                return nil
            }
            return Self.board(size)
        }
        try await fixture.open(count: 3)
        fixture.model.libraryJudging.clipping = SensorClipping { FakeClippingEngine.corner() }
        let modules = fixture.showModules()
        let model = fixture.model
        model.showLibrary(.loupe)
        let loupe = modules.content.library.loupe
        // The following loupe decodes the photo itself, which gives the overlay its size to read the AF point in.
        model.setFollowingLoupe(.double)
        try await fixture.eventually { loupe.showsFullPhoto }
        model.toggleAFPoints()
        model.toggleFocusPeaking()
        try await fixture.eventually { peakingReads.value > 0 }
        for _ in 0 ..< 10 {
            try await fixture.settle()
        }
        #expect(loupe.judging.points == nil && !loupe.judging.drawn.afPoints, "a 1-byte file records no AF point")
        #expect(model.libraryJudging.afPoints.cached(fixture.photos[0]) != nil, "its file was read")
        #expect(peakingReads.value == 1, "the preview was read \(peakingReads.value) times")
        model.toggleFocusPeaking()
        model.toggleFocusPeaking()
        model.toggleAFPoints()
        model.toggleAFPoints()
        try await fixture.settle()
        #expect(peakingReads.value == 1, "turning the tools off and on doesn't ask again")
    }

    @Test func `at 1:1 the part on screen is rendered with its marks once a pan rests`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        // A band down the middle clipped in red, which the part on screen at 1:1 takes in.
        let engine = FakeClippingEngine { point in [abs(point.x - 0.5) < 0.05, false, false] }
        let modules = try await loupe(fixture, engine: engine)
        let model = fixture.model
        let loupe = modules.content.library.loupe
        model.toggleSensorClipping()
        try await fixture.eventually { loupe.judging.marks != nil }
        model.perform(.toggleZoom)
        try await fixture.eventually { loupe.showsFullPhoto }
        try await fixture.eventually { loupe.judging.regionMarks != nil }
        try await fixture.settle()
        let region = try #require(loupe.judging.regionMarks?.region)
        let state = "\(region), marks \(loupe.judging.regionMarks?.image != nil), \(loupe.judging.placement)"
        #expect(loupe.judging.placement.isZoomed && loupe.judging.drawn.region, "the part on screen, drawn: \(state)")
        let render = try #require(engine.renders.withLock { $0 }.last)
        #expect(render.region == region && render.targetSize.width > 0)
    }

    @Test func `Compare draws each tool over both photos at once`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        let engine = FakeClippingEngine.corner()
        let modules = try await loupe(fixture, engine: engine)
        let model = fixture.model
        model.toggleSensorClipping()
        model.toggleRawHistogram()
        model.toggleFocusPeaking()
        model.perform(.compareView)
        try await fixture.settle()
        let compare = modules.content.library.compare
        compare.layoutSubtreeIfNeeded()
        let photos = [CompareSide.select, .candidate].compactMap { compare.halves[$0]?.photo }
        #expect(photos.count == 2)
        try await fixture.eventually {
            photos.allSatisfy { $0.judging.marks != nil && $0.judging.peakingEntry != nil }
        }
        try await fixture.settle()
        for photo in photos {
            #expect(photo.judging.drawn.clipping && photo.judging.drawn.peaking && photo.judging.drawn.histogram)
            #expect(photo.judging.clippingFrame == photo.photoFrame)
        }
        #expect(Set(engine.opened.withLock { $0 }) == Set([fixture.photos[0], fixture.photos[1]]))
        #expect(!modules.content.library.loupe.judging.drawn.clipping, "the loupe, not shown, draws nothing")
    }

    @Test func `the following loupe magnifies the photo under the pointer at 100, 200 and 400%`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        let modules = try await loupe(fixture, engine: .corner())
        let model = fixture.model
        let loupe = modules.content.library.loupe
        let lens = loupe.judging.lens
        model.setFollowingLoupe(.double)
        try await fixture.eventually { loupe.showsFullPhoto }
        try await fixture.settle()
        let frame = loupe.photoFrame
        let scale = loupe.window?.backingScaleFactor ?? 2
        // The photo's own pixels, which the stub's smaller image stands in for.
        let pixels = try loupe.judging.pixelSize?.width ?? CGFloat(#require(loupe.image).width)
        try move(loupe, to: CGPoint(x: frame.midX, y: frame.midY))
        #expect(lens.isShown && close(lens.center, CGPoint(x: frame.midX, y: frame.midY)))
        #expect(abs((lens.photoPoint?.x ?? 0) - 0.5) < 0.001 && abs((lens.photoPoint?.y ?? 0) - 0.5) < 0.001)
        #expect(abs(lens.magnified.width - pixels * 2 / scale) < 1, "two of the screen's pixels to one")
        model.setFollowingLoupe(.quadruple)
        try move(loupe, to: CGPoint(x: frame.minX + frame.width / 4, y: frame.midY))
        #expect(abs(lens.magnified.width - pixels * 4 / scale) < 1)
        #expect(abs((lens.photoPoint?.x ?? 0) - 0.25) < 0.001)
        model.setFollowingLoupe(.actual)
        try move(loupe, to: CGPoint(x: frame.midX, y: frame.midY))
        #expect(abs(lens.magnified.width - pixels / scale) < 1, "one to one")
        try move(loupe, to: CGPoint(x: frame.minX - 5, y: frame.midY))
        #expect(!lens.isShown, "off the photo")
        model.setFollowingLoupe(nil)
        try move(loupe, to: CGPoint(x: frame.midX, y: frame.midY))
        #expect(!lens.isShown)
    }

    @Test func `in Compare the following loupe shows the same point of both photos`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        let modules = try await loupe(fixture, engine: .corner())
        let model = fixture.model
        model.perform(.compareView)
        model.setFollowingLoupe(.double)
        try await fixture.settle()
        let compare = modules.content.library.compare
        compare.layoutSubtreeIfNeeded()
        let select = try #require(compare.halves[.select]?.photo)
        let candidate = try #require(compare.halves[.candidate]?.photo)
        try await fixture.eventually { select.showsFullPhoto && candidate.showsFullPhoto }
        try await fixture.settle()
        let frame = select.photoFrame
        try move(select, to: CGPoint(x: frame.minX + frame.width * 0.3, y: frame.minY + frame.height * 0.6))
        #expect(select.judging.lens.isShown && candidate.judging.lens.isShown, "a lens over each photo")
        let point = try #require(candidate.judging.lens.photoPoint)
        #expect(abs(point.x - 0.3) < 0.001 && abs(point.y - 0.6) < 0.001, "the same point of the candidate: \(point)")
        let exit = try #require(NSEvent.enterExitEvent(
            with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: select.window?.windowNumber ?? 0, context: nil, eventNumber: 0, trackingNumber: 0,
            userData: nil,
        ))
        select.mouseExited(with: exit)
        #expect(!select.judging.lens.isShown && !candidate.judging.lens.isShown, "both go when the pointer leaves")
    }

    @Test(.measuresSpeed) func `the following loupe keeps up with the pointer within a frame`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        let modules = try await loupe(fixture, engine: .corner())
        let model = fixture.model
        let loupe = modules.content.library.loupe
        model.toggleSensorClipping()
        model.toggleFocusPeaking()
        model.toggleAFPoints()
        model.setFollowingLoupe(.quadruple)
        try await fixture.eventually { loupe.showsFullPhoto && loupe.judging.marks != nil }
        try await fixture.settle()
        let frame = loupe.photoFrame
        let clock = ContinuousClock()
        var moves: [Duration] = []
        for step in 0 ..< 600 {
            let t = Double(step) / 600
            let point = CGPoint(
                x: frame.minX + frame.width * (0.1 + 0.8 * t), y: frame.minY + frame.height * (0.5 + 0.3 * sin(t * 12)),
            )
            let took = try clock.measure { try move(loupe, to: point) }
            moves.append(took)
            #expect(close(loupe.judging.lens.center, point), "the lens is where the pointer is when the move returns")
        }
        moves.sort()
        let median = moves[moves.count / 2]
        let worst = moves[moves.count * 99 / 100]
        print("Following loupe at 400%: a move takes \(median) at the median, \(worst) at the 99th percentile")
        #expect(worst < .milliseconds(4), "a move takes \(worst) at the 99th percentile, \(median) at the median")
    }

    @Test(.measuresSpeed) func `stepping with every tool on shows each photo at once and its tools as they come`(
    ) async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        let engine = FakeClippingEngine.corner()
        fixture.engine.decodedThumbnail = { _, size in Self.board(size) }
        try await fixture.open(count: 12)
        fixture.model.libraryJudging.clipping = SensorClipping { engine }
        let modules = fixture.showModules()
        let model = fixture.model
        model.showLibrary(.loupe)
        let loupe = modules.content.library.loupe
        try await fixture.settle()
        model.toggleSensorClipping()
        model.toggleRawHistogram()
        model.toggleFocusPeaking()
        model.toggleAFPoints()
        var blank = 0
        var ready: [Duration] = []
        for _ in 0 ..< 10 {
            model.perform(.nextPhoto)
            let stepped = ContinuousClock.now
            let url = model.selection
            try await fixture.eventually { loupe.judging.url == url }
            if loupe.image == nil {
                blank += 1
            }
            try await fixture.eventually { loupe.judging.marks != nil && loupe.judging.peakingEntry != nil }
            ready.append(.now - stepped)
        }
        ready.sort()
        print("Stepping with the tools on: \(blank) blank frames in 10 steps; tools ready in \(ready[5]) at the median")
        #expect(blank == 0, "a step shows the photo at once")
        #expect(ready[5] < .seconds(1), "the tools came in \(ready[5]) at the median")
    }
}
