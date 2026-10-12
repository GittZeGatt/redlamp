import AppKit
import Testing
@testable import RedlampUI

@MainActor
@Suite(.serialized)
struct FilterSearchFieldFocusTests {
    /// The box of the darkest or brightest pixels the field draws, in its points from the top, from a capture at 2x.
    private func ink(_ field: NSView) throws -> CGRect {
        let rep = try #require(field.bitmapImageRepForCachingDisplay(in: field.bounds))
        field.cacheDisplay(in: field.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / field.bounds.width
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0 ..< rep.pixelsHigh {
            for x in 0 ..< rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        #expect(maxX >= 0, "the field drew nothing")
        return CGRect(
            x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale,
        )
    }

    private func window(_ field: FilterSearchField) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 60), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        field.frame = CGRect(x: 20, y: 16, width: 440, height: FilterSearchField.height)
        window.contentView?.addSubview(field)
        field.layoutSubtreeIfNeeded()
        return window
    }

    /// The text alone: the field's own subviews (the magnifying glass and the buttons) hidden while it's captured.
    private func textInk(_ field: FilterSearchField) throws -> CGRect {
        let others = field.subviews.filter { !($0 is NSClipView) && !($0 is NSText) }
        for view in others {
            view.isHidden = true
        }
        defer {
            for view in others {
                view.isHidden = false
            }
        }
        return try ink(field)
    }

    @Test func `the placeholder stays where it is when the field takes the keyboard`() throws {
        let field = FilterSearchField()
        field.placeholderString = "Search All Photographs"
        let window = window(field)
        defer { window.close() }
        let resting = try textInk(field)
        #expect(window.makeFirstResponder(field))
        field.layoutSubtreeIfNeeded()
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.layoutSubtreeIfNeeded()
        let editing = try textInk(field)
        #expect(abs(editing.minX - resting.minX) <= 0.5, "moved across: \(resting) then \(editing)")
        #expect(abs(editing.minY - resting.minY) <= 0.5, "moved up or down: \(resting) then \(editing)")
        #expect(resting.minX >= 24, "the placeholder starts after the magnifying glass: \(resting)")
    }

    @Test func `typed text stays where it is when the field takes the keyboard`() throws {
        let field = FilterSearchField()
        field.stringValue = "sunset"
        let window = window(field)
        defer { window.close() }
        let resting = try textInk(field)
        #expect(window.makeFirstResponder(field))
        field.layoutSubtreeIfNeeded()
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectedRange = NSRange(location: editor.string.count, length: 0)
        editor.layoutSubtreeIfNeeded()
        let editing = try textInk(field)
        #expect(abs(editing.minX - resting.minX) <= 0.5, "moved across: \(resting) then \(editing)")
        #expect(abs(editing.minY - resting.minY) <= 0.5, "moved up or down: \(resting) then \(editing)")
    }

    @Test func `the field's editor draws no fill of its own`() throws {
        let field = FilterSearchField()
        let window = window(field)
        defer { window.close() }
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(!editor.drawsBackground, "the editor fills its background")
        #expect((editor.enclosingScrollView?.drawsBackground ?? false) == false)
    }
}
