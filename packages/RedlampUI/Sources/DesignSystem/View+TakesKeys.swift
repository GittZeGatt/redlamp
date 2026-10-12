import AppKit
import SwiftUI

extension View {
    /// Makes the window this is in key as it appears. A popover opened by a click on the photo or a
    /// menu leaves the editor window key; its own window takes the keys instead, so its field can be
    /// typed in at once.
    func takesKeys() -> some View {
        background(KeyWindow())
    }
}

private struct KeyWindow: NSViewRepresentable {
    final class View: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeKey()
        }
    }

    func makeNSView(context _: Context) -> View {
        View()
    }

    func updateNSView(_: View, context _: Context) {}
}
