import AppKit

/// A scroll view whose scrollers are always the thin, translucent overlay kind that fade out once
/// scrolling stops, even with "Show scroll bars: Always": a permanent opaque track beside the panels
/// is a distraction while editing. It scrolls vertically; a horizontal scroller turned on is as thin.
public final class OverlayScrollView: NSScrollView {
    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasVerticalScroller = true
        useOverlayScrollers()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// AppKit sets the style again whenever the system preference changes.
    override public var scrollerStyle: NSScroller.Style {
        get { .overlay }
        // swiftlint:disable:next unused_setter_value
        set { super.scrollerStyle = .overlay }
    }

    override public var hasHorizontalScroller: Bool {
        didSet { horizontalScroller?.controlSize = .small }
    }
}

public extension NSScrollView {
    /// The app's scrollers: overlay, small, and hidden while there's nothing to scroll. AppKit sets the
    /// style back to the system's whenever its preference changes, which `OverlayScrollView` and
    /// `View.overlayScrollers()` undo.
    func useOverlayScrollers() {
        autohidesScrollers = true
        verticalScroller?.controlSize = .small
        horizontalScroller?.controlSize = .small
        scrollerStyle = .overlay
    }
}
