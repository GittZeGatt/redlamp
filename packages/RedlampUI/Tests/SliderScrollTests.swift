import AppKit
import RedlampDesign
import RedlampEngineAPI
import Testing

/// ⌘-scroll over a slider adjusts it; plain scrolling leaves it for the panel column (UX-02).
@MainActor
struct SliderScrollTests {
    final class Editor: ParameterEditing {
        var values: [ParameterID: Double] = [:]
        var edits = 0
        var ends = 0
        var openEdit: Int?
        var focusedParameter: ParameterID?
        var revealedParameter: ParameterID?
        var optionKeyHeld: Bool {
            false
        }

        func sliderValue(_ parameter: ParameterID) -> Double {
            values[parameter] ?? parameter.spec.defaultValue
        }

        func setSliderValue(_ parameter: ParameterID, _ value: Double) {
            values[parameter] = value
        }

        func isEdited(_ parameter: ParameterID) -> Bool {
            values[parameter] != nil
        }

        func resetSlider(_ parameter: ParameterID) {
            values[parameter] = nil
        }

        func resetParameters(_ parameters: [ParameterID], name _: String) {
            parameters.forEach { values[$0] = nil }
        }

        func beginEdit(_: ParameterID?) {
            edits += 1
            openEdit = edits
        }

        func endEdit(name _: String?) {
            ends += 1
            openEdit = nil
        }

        func setTemporaryClipping(_: Bool) {}
    }

    private func scroll(lines: Int32, flags: CGEventFlags) throws -> NSEvent {
        let event = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0,
        ))
        event.flags = flags
        return try #require(NSEvent(cgEvent: event))
    }

    @Test func `command-scroll adjusts the slider under the pointer`() throws {
        let editor = Editor()
        let row = SliderRowView(parameter: .contrast, editor: editor)
        let event = try scroll(lines: 3, flags: .maskCommand)
        row.scrollWheel(with: event)
        let expected = (event.isDirectionInvertedFromDevice ? -3 : 3) * ParameterID.contrast.spec.step
        #expect(editor.values[.contrast] == expected)
        #expect(editor.focusedParameter == .contrast)
        #expect(editor.edits == 1)
    }

    @Test func `plain scrolling leaves the slider alone`() throws {
        let editor = Editor()
        let row = SliderRowView(parameter: .contrast, editor: editor)
        try row.scrollWheel(with: scroll(lines: 3, flags: []))
        #expect(editor.values.isEmpty)
    }

    @Test func `the scroll's edit ends once scrolling pauses`() async throws {
        let editor = Editor()
        let row = SliderRowView(parameter: .contrast, editor: editor)
        try row.scrollWheel(with: scroll(lines: 3, flags: .maskCommand))
        let deadline = Date().addingTimeInterval(5)
        while editor.ends == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(editor.ends == 1)
        #expect(editor.openEdit == nil)
    }

    /// A drag of another slider begun before the scroll pauses is one History step of its own.
    @Test func `the scroll's pause leaves a drag begun since to end its own edit`() async throws {
        let editor = Editor()
        let row = SliderRowView(parameter: .highlights, editor: editor)
        try row.scrollWheel(with: scroll(lines: 3, flags: .maskCommand))
        editor.beginEdit(.shadows)
        let drag = editor.openEdit
        try await Task.sleep(for: .seconds(1))
        #expect(editor.ends == 0)
        #expect(editor.openEdit == drag)
    }
}
