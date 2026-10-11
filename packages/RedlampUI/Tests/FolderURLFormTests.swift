import Foundation
import RedlampDocument
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// A folder opened by a URL in another form than the path the library keeps for it: with an empty component, as
/// appending an empty path to a URL Foundation's `FileManager` made gives (the temporary and home folders' on CI), a
/// `.` or a `..`. Its photos are named as the library names them from anywhere else, so a photo reached by its usual
/// URL is the one listed, and culled.
@MainActor
@Suite(.serialized)
struct FolderURLFormTests {
    /// `folder` as a URL with an empty component, a `.` and a `..`.
    private static func forms(of folder: URL) -> [URL] {
        [
            URL(fileURLWithPath: folder.path + "//", isDirectory: true),
            folder.appending(path: ".", directoryHint: .isDirectory),
            folder.deletingLastPathComponent().appending(
                path: "Other/../" + folder.lastPathComponent, directoryHint: .isDirectory,
            ),
        ]
    }

    @Test func `a folder shown from the library by another form of its URL names its photos as the library does`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["Shoot/A.JPG", "Shoot/B.JPG", "Other/C.JPG"])
        let model = try await sandbox.open()
        let (shoot, other) = (sandbox.folder("Shoot"), sandbox.folder("Other"))
        let (a, b) = (sandbox.photo("Shoot/A.JPG"), sandbox.photo("Shoot/B.JPG"))
        let ratings: [(ShortcutAction, Int)] = [(.rating1, 1), (.rating2, 2), (.rating3, 3)]
        for (form, (action, rating)) in zip(Self.forms(of: shoot), ratings) {
            try #require(form != shoot && form.standardizedFileURL == shoot)
            model.showFolder(other)
            try await sandbox.eventually { model.folder == other && model.items.count == 1 }
            model.showFolder(form)
            try await sandbox.eventually {
                model.folder == shoot && model.library.isShownFromLibrary && !model.library.isListing
                    && model.items.count == 2
            }
            #expect(model.folder == shoot, "\(form) opened as \(shoot)")
            #expect(model.items.map(\.url) == [a, b], "\(form)'s photos named as the library names them")
            model.select(b)
            #expect(model.library.index(of: b) == 1)
            #expect(model.canPerform(action) && model.perform(action), "B, listed, culled from \(form)")
            try await sandbox.eventually { !model.isWritingCulling }
            await sandbox.service?.settled()
            #expect(SidecarStore().load(for: b)?.metadata?.rating == rating)

            let generation = model.library.generation
            model.showFolder(form)
            #expect(model.library.generation == generation, "shown again by the same form, it stays as it is")
        }
    }

    @Test func `a folder listed from the disk by another form of its URL names its photos as the library does`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["Shoot/A.JPG", "Shoot/B.JPG"])
        let shoot = sandbox.folder("Shoot")
        let (a, b) = (sandbox.photo("Shoot/A.JPG"), sandbox.photo("Shoot/B.JPG"))
        for form in Self.forms(of: shoot) {
            for subfolders in [true, false] {
                let library = FolderLibrary()
                library.add([sandbox.root])
                library.setIncludesSubfolders(subfolders)
                library.open(form)
                try await sandbox.eventually { !library.isListing && library.count == 2 }
                #expect(library.openFolder == shoot, "\(form) opened as \(shoot)")
                #expect(library.items.map(\.url) == [a, b], "\(form)'s photos named as the library names them")
                #expect(library.index(of: b) == 1)
            }
        }
    }
}
