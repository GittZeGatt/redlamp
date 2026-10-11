import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampDocument

/// A custom label's colour in the sidecar (LIB-15): written with the custom label alone, read back as it was, and a
/// colour this build doesn't know kept as it's written.
struct CustomLabelColorTests {
    private func metadataJSON(_ metadata: PhotoMetadata) throws -> [String: JSONValue] {
        let data = try JSONEncoder.sidecar.encode(metadata)
        guard case let .object(object) = try JSONDecoder().decode(JSONValue.self, from: data) else { return [:] }
        return object
    }

    private func decoded(_ json: String) throws -> PhotoMetadata {
        try JSONDecoder.sidecar.decode(PhotoMetadata.self, from: Data(json.utf8))
    }

    @Test func `a custom label's colour is written beside it and read back`() throws {
        let metadata = PhotoMetadata(customLabel: "Urgent", customLabelColor: .orange)
        #expect(try metadataJSON(metadata) == [
            "rating": .number(0), "customLabel": .string("Urgent"), "customLabelColor": .string("orange"),
        ])
        #expect(try decoded(#"{"rating": 0, "customLabel": "Urgent", "customLabelColor": "orange"}"#) == metadata)
    }

    @Test func `a colour without a custom label isn't written`() throws {
        var metadata = PhotoMetadata(label: .red)
        metadata.customLabelColor = .teal
        #expect(try metadataJSON(metadata) == ["rating": .number(0), "label": .string("red")])
        #expect(metadata.isEmpty == PhotoMetadata(label: .red).isEmpty)
    }

    @Test func `a colour a newer build wrote is kept as it's written and isn't one of the palette's`() throws {
        let metadata = try decoded(#"{"rating": 2, "customLabel": "Hero", "customLabelColor": "chartreuse"}"#)
        #expect(metadata.customLabelColor?.rawValue == "chartreuse" && metadata.customLabelColor?.isKnown == false)
        #expect(try metadataJSON(metadata)["customLabelColor"] == .string("chartreuse"))
    }

    @Test func `a sidecar from before custom labels' colours reads as one without a colour`() throws {
        let metadata = try decoded(#"{"rating": 1, "customLabel": "Second Look"}"#)
        #expect(metadata == PhotoMetadata(rating: 1, customLabel: "Second Look"))
        #expect(metadata.customLabelColor == nil)
    }

    @Test func `the palette's colours are found by their names, in any case`() {
        #expect(LabelColor(named: "Orange") == .orange && LabelColor(named: " pink ") == .pink)
        #expect(LabelColor(named: "Grey") == .gray && LabelColor(named: "GRAY") == .gray)
        #expect(LabelColor(named: "Urgent") == nil && LabelColor(named: "") == nil)
        #expect(LabelColor.palette.allSatisfy(\.isKnown) && LabelColor.palette.count == 10)
        #expect(LabelColor.teal.name == "Teal")
    }

    @Test func `a merge of two writers keeps the colour the one that changed it gave`() {
        let base = PhotoMetadata(customLabel: "Urgent", customLabelColor: .orange)
        var theirs = base
        theirs.customLabelColor = .pink
        var ours = base
        ours.rating = 3
        let merged = PhotoMetadata.merge(ours, theirs, base: base, opened: base)
        #expect(merged == PhotoMetadata(rating: 3, customLabel: "Urgent", customLabelColor: .pink))
    }
}
