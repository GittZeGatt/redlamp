import AppKit
import Foundation
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// The library's sheets and windows laid out at their smallest with long text (LIB-49): no label clipped that
/// doesn't truncate or wrap, nothing past the window's content, and no control laid out ambiguously.
@MainActor
@Suite(.serialized)
struct SheetLayoutTests {
    @Test func `the check finds a label too narrow for its text and a view past the edge`() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        let label = NSTextField(labelWithString: "A label much wider than the room it has")
        label.frame = NSRect(x: 10, y: 10, width: 60, height: 20)
        content.addSubview(label)
        let past = NSView(frame: NSRect(x: 180, y: 0, width: 40, height: 20))
        content.addSubview(past)
        #expect(LayoutCheck.problems(in: content).count == 2)
        label.lineBreakMode = .byTruncatingTail
        past.frame.origin.x = 150
        #expect(LayoutCheck.problems(in: content).isEmpty)
    }

    @Test func `Import from Lightroom Classic fits its report at its smallest`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["A.jpg"])
        let other = sandbox.base.appending(
            path: "Archive 2019 to 2023, the scanned negatives and the prints", directoryHint: .isDirectory,
        )
        try sandbox.photos(["Day/B.jpg"], under: other, from: 1)
        let catalog = sandbox.base.appending(path: "Catalogs from the old Mac/Lightroom Catalog-2-2-v13.lrcat")
        try LightroomWindowTests.catalog(root: sandbox.root, other: other, at: catalog)
        let model = try await sandbox.open()

        LightroomWindowController.show(editor: model)
        let controller = try #require(LightroomWindowController.current)
        defer { controller.close() }
        controller.choose(catalog: catalog)
        try await sandbox.eventually { controller.isReported }
        let window = try #require(controller.window)
        window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: true)
        let content = try #require(window.contentView)
        #expect(LayoutCheck.problems(in: content) == [])
    }

    @Test func `the import window's To fits at the window's smallest`() async throws {
        let imports = try await ImportWindowFixture.make()
        defer { imports.remove() }
        let controller = ImportWindowController(model: imports.model())
        let window = try #require(controller.window)
        defer { window.orderOut(nil) }
        window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: true)
        let content = try #require(window.contentView)
        #expect(LayoutCheck.problems(in: content) == [])
    }

    @Test func `a sheet's heading, labels, fields and buttons fit`() throws {
        let model = EditorModel(engine: StubEngine())
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        parent.orderFront(nil)
        EditorWindowController.harnessWindow = parent
        defer {
            EditorWindowController.harnessWindow = nil
            parent.orderOut(nil)
        }
        let sheet = PanelSheet(title: "Merge “Places › Portugal › Lisbon › Alfama” Into Another Keyword", model: model)
        let field = NSTextField(string: "")
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        sheet.add("Merge “Places › Portugal › Lisbon › Alfama” into:", field)
        sheet.add(nil, NSButton(checkboxWithTitle: "Include on Export", target: nil, action: nil))
        #expect(sheet.begin(button: "Merge") { true })
        defer { sheet.end() }
        let content = try #require(sheet.window.contentView)
        #expect(LayoutCheck.problems(in: content) == [])
    }
}

/// What a polish pass looks for in a window's views: a one-line label narrower than its text that doesn't truncate,
/// a view past the window's content, and a control whose layout is ambiguous. A scroll view's document is let be
/// wider or taller than the window: it scrolls.
@MainActor
enum LayoutCheck {
    static func problems(in root: NSView) -> [String] {
        root.layoutSubtreeIfNeeded()
        var found: [String] = []
        func visit(_ view: NSView, scrolled: Bool) {
            guard !view.isHidden else { return }
            let frame = view.convert(view.bounds, to: root)
            let name = describe(view)
            if view !== root, !scrolled, frame.minX < root.bounds.minX - 0.5 || frame.maxX > root.bounds.maxX + 0.5 {
                found
                    .append(
                        "past the edge (\(Int(frame.minX)) to \(Int(frame.maxX)) of \(Int(root.bounds.width))): \(name)",
                    )
            }
            if let label = view as? NSTextField, clips(label) {
                found.append("clipped (\(Int(label.frame.width)) of \(Int(label.intrinsicContentSize.width))): \(name)")
            }
            if view is NSControl, view.hasAmbiguousLayout {
                found.append("ambiguous: \(name)")
            }
            for subview in view.subviews {
                visit(subview, scrolled: scrolled || view is NSClipView)
            }
        }
        visit(root, scrolled: false)
        return found
    }

    private static func clips(_ label: NSTextField) -> Bool {
        guard !label.isEditable, !label.stringValue.isEmpty else { return false }
        switch label.lineBreakMode {
        case .byTruncatingHead, .byTruncatingMiddle, .byTruncatingTail: return false
        default: break
        }
        if label.maximumNumberOfLines != 1, label.cell?.wraps == true {
            return false
        }
        return label.intrinsicContentSize.width > label.frame.width + 1
    }

    private static func describe(_ view: NSView) -> String {
        let text = (view as? NSTextField)?.stringValue ?? (view as? NSButton)?.title ?? ""
        let identifier = view.accessibilityIdentifier()
        return "\(type(of: view))" + (identifier.isEmpty ? "" : " \(identifier)") + (text.isEmpty ? "" : " “\(text)”")
    }
}
