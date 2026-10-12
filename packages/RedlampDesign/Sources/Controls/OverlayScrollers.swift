import AppKit
import SwiftUI

public extension View {
    /// Keeps the scroll views AppKit makes for this `ScrollView`, `List`, `Form` or `TextEditor` on the app's
    /// scrollers (`NSScrollView.useOverlayScrollers()`), as `OverlayScrollView` keeps its own: SwiftUI's follow
    /// "Show scroll bars", which draws a thick track beside them on a Mac with a mouse.
    func overlayScrollers() -> some View {
        background(OverlayScrollersAnchor())
    }
}

private struct OverlayScrollersAnchor: NSViewRepresentable {
    func makeNSView(context _: Context) -> OverlayScrollersKeeper {
        OverlayScrollersKeeper()
    }

    func updateNSView(_ keeper: OverlayScrollersKeeper, context _: Context) {
        keeper.findSoon()
    }
}

/// Behind the view it's the background of: finds the scroll views SwiftUI made beside it (or the one it's in) and
/// keeps them overlay, setting the style back as soon as anything changes it.
final class OverlayScrollersKeeper: NSView {
    private var kept: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var isFinding = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        kept = [:]
        NotificationCenter.default.removeObserver(self)
        guard window != nil else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferenceChanged), name: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
        )
        findSoon()
    }

    /// SwiftUI puts its scroll view beside the background after making the background.
    func findSoon() {
        guard !isFinding else { return }
        isFinding = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isFinding = false
            keep(found())
        }
    }

    @objc private func preferenceChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.kept = [:]
            self?.findSoon()
        }
    }

    private func keep(_ scrollViews: [NSScrollView]) {
        for scrollView in scrollViews where kept[ObjectIdentifier(scrollView)] == nil {
            scrollView.useOverlayScrollers()
            kept[ObjectIdentifier(scrollView)] = scrollView.observe(\.scrollerStyle) { scrollView, _ in
                MainActor.assumeIsolated {
                    if scrollView.scrollerStyle != .overlay {
                        scrollView.useOverlayScrollers()
                    }
                }
            }
        }
    }

    /// The scroll view it's in, or those in the nearest of its ancestors that holds any beside it.
    private func found() -> [NSScrollView] {
        guard window != nil else { return [] }
        if let enclosingScrollView {
            return [enclosingScrollView]
        }
        var view: NSView = self
        while let parent = view.superview {
            let beside = parent.subviews.filter { $0 !== view }.flatMap(Self.scrollViews(in:))
            if !beside.isEmpty {
                return beside
            }
            view = parent
        }
        return []
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] + $0.subviews.flatMap(scrollViews(in:)) }
            ?? view.subviews.flatMap(scrollViews(in:))
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}
