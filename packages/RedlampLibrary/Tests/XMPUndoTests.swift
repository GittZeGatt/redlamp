import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// With `.xmp` writing on, the Undo of a change Redlamp wrote over another app's fields gives that app's `.xmp`
/// back what it had written (LIB-24), as the app's syncs leave other apps' fields in their files.
struct XMPUndoTests {
    private static func fields(_ path: String, in sandbox: XMPSandbox) throws -> XMPFields {
        try #require(XMPSource(xmp: Data(contentsOf: sandbox.url(path)))).fields
    }

    private static func sync(_ id: Int64, in sandbox: XMPSandbox) async throws -> XMPPhotoSync {
        try #require(try await sandbox.xmp.sync([id], filling: false).photos.first { $0.photo == id })
    }

    @Test func `undoing a label set over another app's gives its .xmp that app's label back, shown as theirs`(
    ) async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        try sandbox.photo("IMG_0001.ARW")
        try sandbox.write(
            "IMG_0001.xmp", OtherApps.lightroom(rating: 2, label: "Red", keywords: ["Birds"]), modified: -600,
        )
        try await sandbox.indexAll()
        try await sandbox.xmp.setSettings(XMPSettings(writes: true))
        let id = try await sandbox.id("IMG_0001.ARW")
        #expect(try await Self.sync(id, in: sandbox).written == [])

        let metadata = LibraryMetadata(index: sandbox.index)
        try await metadata.apply(.set([.label(.yellow)], on: [id]))
        #expect(try await Self.sync(id, in: sandbox).written == [.label])
        #expect(try Self.fields("IMG_0001.xmp", in: sandbox).label == .yellow)

        _ = try await metadata.undo()
        let undone = try await Self.sync(id, in: sandbox)
        #expect(undone.written == [.label] && undone.restored == [.label] && undone.taken == [])
        #expect(undone.problem == nil)
        let fields = try Self.fields("IMG_0001.xmp", in: sandbox)
        #expect(fields.label == .red, "the other app's label is back")
        #expect(fields.rating == 2 && fields.keywords == ["Birds"], "its other fields stay as it wrote them")
        #expect(!sandbox.exists("IMG_0001.ARW.redlamp"), "the .redlamp the change made is gone")
        let row = try #require(try await sandbox.index.read { try $0.photo(id: id) })
        #expect(row.label == .red && row.otherFields.contains(.label), "the index shows the label as theirs")
        let record = try #require(try await sandbox.index.read { try XMPMergeRecord.records([id], in: $0) }[id])
        #expect(record.replaced == nil, "nothing is left to give back")

        let after = try sandbox.text("IMG_0001.xmp")
        #expect(try await Self.sync(id, in: sandbox).written == [])
        #expect(try sandbox.text("IMG_0001.xmp") == after, "the .xmp is the other app's from then on")
    }

    @Test func `No Label over another app's label clears it in its .xmp, and each Undo brings back what was there`(
    ) async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        try sandbox.photo("IMG_0005.ARW")
        try sandbox.write("IMG_0005.xmp", OtherApps.lightroom(rating: 2, label: "Red"), modified: -600)
        try await sandbox.indexAll()
        try await sandbox.xmp.setSettings(XMPSettings(writes: true))
        let id = try await sandbox.id("IMG_0005.ARW")
        _ = try await Self.sync(id, in: sandbox)
        let metadata = LibraryMetadata(index: sandbox.index)
        try await metadata.apply(.set([.label(.yellow)], on: [id]))
        _ = try await Self.sync(id, in: sandbox)

        try await metadata.apply(.set([.label(nil)], on: [id]))
        let cleared = try await Self.sync(id, in: sandbox)
        #expect(cleared.written == [.label] && cleared.restored == [])
        #expect(try Self.fields("IMG_0005.xmp", in: sandbox).holds(.label) == false, "No Label stays no label")
        #expect(try Self.fields("IMG_0005.xmp", in: sandbox).rating == 2)

        _ = try await metadata.undo()
        _ = try await Self.sync(id, in: sandbox)
        #expect(try Self.fields("IMG_0005.xmp", in: sandbox).label == .yellow, "the Undo of No Label")
        _ = try await metadata.undo()
        #expect(try await Self.sync(id, in: sandbox).restored == [.label])
        #expect(try Self.fields("IMG_0005.xmp", in: sandbox).label == .red, "the Undo of Yellow: the other app's")
    }

    @Test func `undoing a keyword added to another app's gives its .xmp that app's keywords back`() async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        try sandbox.photo("IMG_0002.ARW")
        try sandbox.write(
            "IMG_0002.xmp", OtherApps.lightroom(rating: 3, keywords: ["Birds", "Places/Lisbon"]), modified: -600,
        )
        try await sandbox.indexAll()
        try await sandbox.xmp.setSettings(XMPSettings(writes: true))
        let id = try await sandbox.id("IMG_0002.ARW")
        _ = try await Self.sync(id, in: sandbox)

        let keywords = LibraryKeywords(index: sandbox.index)
        _ = try await keywords.apply(.add([kw("Gulls")], to: [id]))
        #expect(try await Self.sync(id, in: sandbox).written == [.keywords])
        #expect(try Set(Self.fields("IMG_0002.xmp", in: sandbox).keywords ?? []) == ["Birds", "Places/Lisbon", "Gulls"])

        _ = try await keywords.undo()
        #expect(try await Self.sync(id, in: sandbox).written == [.keywords])
        let fields = try Self.fields("IMG_0002.xmp", in: sandbox)
        #expect(Set(fields.keywords ?? []) == ["Birds", "Places/Lisbon"], "the other app's keywords are back")
        #expect(fields.rating == 3)
    }

    @Test func `a change other apps make after Redlamp's stands, and the earlier value isn't given back over it`(
    ) async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        try sandbox.photo("IMG_0003.ARW")
        try sandbox.write("IMG_0003.xmp", OtherApps.lightroom(rating: 1, label: "Red"), modified: -600)
        try await sandbox.indexAll()
        try await sandbox.xmp.setSettings(XMPSettings(writes: true))
        let id = try await sandbox.id("IMG_0003.ARW")
        _ = try await Self.sync(id, in: sandbox)
        let metadata = LibraryMetadata(index: sandbox.index)
        try await metadata.apply(.set([.label(.green)], on: [id]))
        _ = try await Self.sync(id, in: sandbox)

        // The other app relabels it, which the .redlamp takes in; it's that app's latest label from then on.
        try sandbox.write("IMG_0003.xmp", OtherApps.lightroom(rating: 1, label: "Blue"), modified: 60)
        #expect(try await Self.sync(id, in: sandbox).taken == [.label])
        #expect(sandbox.metadata("IMG_0003.ARW")?.label == .blue)
        let record = try #require(try await sandbox.index.read { try XMPMergeRecord.records([id], in: $0) }[id])
        #expect(record.replaced?.present.contains(.label) != true, "the red it replaced is forgotten")
    }

    @Test func `a .redlamp that decided a field before another app's .xmp came keeps nothing to give back`(
    ) async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        try sandbox.photo("IMG_0004.ARW")
        try sandbox.sidecar("IMG_0004.ARW", PhotoMetadata(rating: 4, label: .purple))
        try await sandbox.indexAll()
        try await sandbox.xmp.setSettings(XMPSettings(writes: true))
        let id = try await sandbox.id("IMG_0004.ARW")
        #expect(try await Self.sync(id, in: sandbox).written == [.rating, .label])
        let record = try #require(try await sandbox.index.read { try XMPMergeRecord.records([id], in: $0) }[id])
        #expect(record.replaced == nil, "the .xmp Redlamp made held nothing of other apps'")
    }
}
