import AppKit
import ImageIO
import RedlampEngineAPI
@_spi(Harness) import RedlampLibrary
@_spi(Harness) import RedlampUI
import UniformTypeIdentifiers

/// The Library scenes' library: an index of its own in the temporary folder, made afresh each launch, never the app's
/// (`LibraryPaths.standard` is the app's library). Its photos are copies of three raw fixtures and small JPEGs, some
/// with long names and one pair byte for byte the same; beside them a card to import from, holding copies of some of
/// them and photos the library doesn't have, and a Lightroom Classic catalog naming a folder the library doesn't
/// have, the library's own folder and a folder that has moved.
@MainActor
enum HarnessLibrary {
    private static let base = FileManager.default.temporaryDirectory
        .appending(path: "redlamp-harness-library", directoryHint: .isDirectory)
    private static let defaultsSuite = "app.redlamp.harness.library"

    static let fixture: LibraryHarnessFixture = {
        try? FileManager.default.removeItem(at: base)
        let photos = folder("Photos")
        let card = folder("Cards/Untitled")
        let fixture = LibraryHarnessFixture(
            photos: photos, card: card, destination: folder("Pictures"), backup: folder("Backup"), catalog: nil,
        )
        try? makePhotos(in: photos, card: card)
        var made = fixture
        made.catalog = try? makeCatalog(library: photos)
        return made
    }()

    static let model: EditorModel = {
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
        let defaults = UserDefaults(suiteName: defaultsSuite)
        let engine = HarnessEditor.model.engine
        let library = FolderLibrary(defaults: defaults)
        let service = LibraryService(
            paths: LibraryPaths(root: base.appending(path: "Library", directoryHint: .isDirectory)),
            sidecars: library.sidecars, defaults: defaults,
        ) { url, size in engine.decodeThumbnail(for: url, maxPixelSize: size) }
        library.attach(service)
        return EditorModel(engine: engine, library: library)
    }()

    private static var prepared: Task<Void, Never>?

    /// Returns once the library is open, lists its photos and holds the collections, keywords and label the sheets
    /// show; the first call prepares them.
    static func ready() async {
        let task = prepared ?? Task {
            await model.waitForHarnessLibrary(fixture)
            await model.prepareHarnessLibrary()
        }
        prepared = task
        await task.value
    }

    private static func folder(_ path: String) -> URL {
        let url = base.appending(path: path, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `tests/fixtures/raw` in this checkout (`mise run fixtures` downloads it).
    private static let raws = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "tests/fixtures/raw", directoryHint: .isDirectory)

    private static let longName = "2026-09-14 Lisbon, Alfama at dusk from the Miradouro de Santa Luzia, the trams below"

    private static func makePhotos(in photos: URL, card: URL) throws {
        let files = (try? FileManager.default.contentsOfDirectory(at: raws, includingPropertiesForKeys: nil)) ?? []
        for raw in files.filter(SupportedFormats.isSupported)
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .prefix(3) {
            try FileManager.default.copyItem(at: raw, to: photos.appending(path: raw.lastPathComponent))
        }
        let names = ["IMG_0001.JPG", "IMG_0002.JPG", "IMG_0003.JPG", "\(longName) 1.jpg", "\(longName) 2.jpg"]
        for (number, name) in names.enumerated() {
            try jpeg(number).write(to: photos.appending(path: name))
        }
        try jpeg(0).write(to: photos.appending(path: "IMG_0001 copy.JPG"))
        let dcim = card.appending(path: "DCIM/100CANON", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
        for number in 0 ..< 12 {
            let name = number == 11 ? "\(longName) on the card.JPG" : String(format: "IMG_%04d.JPG", number + 1)
            try jpeg(number < 3 ? number : number + 20).write(to: dcim.appending(path: name))
        }
    }

    /// A catalog of a folder the library doesn't have, `Lightroom/Shoot`, also naming the library's own folder and
    /// one that has moved.
    private static func makeCatalog(library photos: URL) throws -> URL {
        let lightroom = folder("Lightroom")
        let shoot = lightroom.appending(path: "Shoot", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        for number in 1 ... 3 {
            try jpeg(40 + number).write(to: shoot.appending(path: String(format: "LR_%04d.jpg", number)))
        }
        let moved = base.appending(
            path: "Moved Drive/Archive 2019 to 2023, scanned negatives",
            directoryHint: .isDirectory,
        )
        return try LightroomScratchCatalog.make(of: lightroom, tag: "harness", otherRoots: [photos, moved])
    }

    /// A 96 × 64 JPEG of its own colour, taken on 14 September 2026 from 18:00, `number` minutes apart, by the
    /// camera's clock.
    private static func jpeg(_ number: Int) throws -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(
            red: CGFloat(number % 7) / 7, green: CGFloat(number % 5) / 5, blue: CGFloat(number % 3) / 3, alpha: 1,
        )
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        let taken = String(format: "2026:09:14 %02d:%02d:00", 18 + number / 60, number % 60)
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: taken],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Canon",
                kCGImagePropertyTIFFModel: "Canon EOS R6",
            ],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}
