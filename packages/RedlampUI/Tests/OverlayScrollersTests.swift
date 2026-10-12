import AppKit
import RedlampDesign
import SwiftUI
import Testing
@_spi(Harness) @testable import RedlampUI

/// Every scroller in the app is the thin overlay kind, with "Show scroll bars: Always" or a mouse too: AppKit sets a
/// scroll view's style to the system's whenever its preference changes, and each kind of scroll view sets it back.
@MainActor
struct OverlayScrollersTests {
    @Test func `the app's own scroll view keeps its thin scrollers, a horizontal one included`() {
        let scrollView = OverlayScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.scrollerStyle = .legacy
        #expect(scrollView.scrollerStyle == .overlay)
        #expect(scrollView.verticalScroller?.scrollerStyle == .overlay)
        #expect(scrollView.horizontalScroller?.scrollerStyle == .overlay)
        #expect(scrollView.verticalScroller?.controlSize == .small)
        #expect(scrollView.horizontalScroller?.controlSize == .small)
        #expect(scrollView.autohidesScrollers)
    }

    enum Container: String, CaseIterable, CustomTestStringConvertible {
        case scrollView, horizontalScrollView, list, form, textEditor

        var testDescription: String {
            rawValue
        }

        @MainActor @ViewBuilder var view: some View {
            let rows = ForEach(0 ..< 60, id: \.self) { Text("Row \($0)") }
            switch self {
            case .scrollView: ScrollView { VStack { rows } }.overlayScrollers()
            case .horizontalScrollView: ScrollView(.horizontal) { HStack { rows } }.overlayScrollers()
            case .list: List { rows }.overlayScrollers()
            case .form: Form { rows }.overlayScrollers().formStyle(.grouped)
            case .textEditor: TextEditor(text: .constant(String(repeating: "A line\n", count: 60))).overlayScrollers()
            }
        }
    }

    @Test(arguments: Container.allCases)
    func `SwiftUI's scroll views keep thin scrollers`(_ container: Container) async throws {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        let root = container.view.frame(width: 300, height: 200).focusEffectDisabled()
        window.contentView = NSHostingView(rootView: root)
        defer { window.contentView = nil }
        var scrollViews: [NSScrollView] = []
        for _ in 0 ..< 200 {
            window.contentView?.layoutSubtreeIfNeeded()
            scrollViews = Self.scrollViews(in: window.contentView)
            if !scrollViews.isEmpty, scrollViews.allSatisfy(Self.isThin) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!scrollViews.isEmpty, "no scroll view behind the \(container)")
        for scrollView in scrollViews {
            #expect(Self.isThin(scrollView), "\(type(of: scrollView))")
            scrollView.scrollerStyle = .legacy
            #expect(scrollView.scrollerStyle == .overlay, "\(type(of: scrollView)) set to legacy")
        }
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        for scrollView in Self.scrollViews(in: window.contentView) {
            #expect(scrollView.scrollerStyle == .overlay, "\(type(of: scrollView)) after the preference changed")
        }
    }

    /// The editor window's every scroll view, its panels', grid's, filmstrips' and command palette's, both modules'.
    @Test func `no scroll view in the editor window takes the legacy style`() async throws {
        _ = NSApplication.shared
        let model = EditorModel(engine: StubEngine())
        let controller = EditorWindowController(
            model: model, theme: ThemeSettings(), onOpen: {}, onExport: {}, onExportWithPrevious: {},
        )
        let window = try #require(controller.window)
        window.orderFront(nil)
        defer {
            model.closeCommandPalette()
            window.orderOut(nil)
        }
        model.openCommandPalette(scope: .all)
        try await Task.sleep(for: .milliseconds(400))
        let frame = try #require(window.contentView?.superview)
        let scrollViews = Self.scrollViews(in: frame)
        #expect(scrollViews.count >= 6, "\(scrollViews.map { type(of: $0) })")
        #expect(scrollViews.contains { !($0 is OverlayScrollView) }, "the palette's, SwiftUI's")
        for scrollView in scrollViews {
            scrollView.scrollerStyle = .legacy
            #expect(scrollView.scrollerStyle == .overlay, "\(type(of: scrollView)) in \(Self.path(of: scrollView))")
        }
    }

    private static func isThin(_ scrollView: NSScrollView) -> Bool {
        let scrollers = [scrollView.verticalScroller, scrollView.horizontalScroller].compactMap(\.self)
        return scrollView.scrollerStyle == .overlay && scrollers.allSatisfy { $0.controlSize == .small }
    }

    private static func scrollViews(in view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        return ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private static func path(of view: NSView) -> String {
        let ancestors = sequence(first: view, next: \.superview).dropFirst().prefix(6)
        return ancestors.map { "\(type(of: $0))" }.joined(separator: " < ")
    }
}
