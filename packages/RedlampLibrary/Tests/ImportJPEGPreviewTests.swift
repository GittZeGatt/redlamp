import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RedlampLibrary

/// Previews of cards of JPEGs (LIB-27): what a camera JPEG's first bytes offer is shown first.
struct ImportJPEGPreviewTests {
    @Test func `a JPEG's EXIF thumbnail is found in its first bytes`() throws {
        let jpeg = try CameraJPEG.make(width: 1200, height: 800, seed: 1)
        let head = jpeg.prefix(PhotoMetadataReader.headLength)
        let found = EmbeddedPreviews.inJPEG(head, size: jpeg.count)
        let thumbnail = try #require(found.thumbnail)
        #expect(found.large.isEmpty && thumbnail.range.upperBound <= 65536)
        let image = try #require(EmbeddedPreviews.thumbnail(
            ofJPEG: jpeg.subdata(in: thumbnail.range), edge: 320, orientation: nil,
        ))
        #expect(image.width == 160 && image.height < 160)
        // A JPEG without one, and bytes that aren't a JPEG, offer nothing.
        let plain = try CameraJPEG.make(width: 600, height: 400, seed: 2, thumbnail: false)
        #expect(EmbeddedPreviews.inJPEG(plain, size: plain.count) == EmbeddedPreviews.JPEGPreviews())
        #expect(EmbeddedPreviews.inJPEG(Data(repeating: 7, count: 4096), size: 4096) == EmbeddedPreviews.JPEGPreviews())
    }

    @Test func `a large thumbnail a JPEG's Multi-Picture Format index lists is found`() throws {
        let (file, large) = try CameraJPEG.withLargeThumbnail(width: 2400, height: 1600, seed: 3)
        let found = EmbeddedPreviews.inJPEG(file.prefix(PhotoMetadataReader.headLength), size: file.count)
        #expect(found.large == [large])
        let image = try #require(EmbeddedPreviews.thumbnail(
            ofJPEG: file.subdata(in: large.range),
            edge: 384,
            orientation: nil,
        ))
        #expect(image.width == 384 && image.height == 256)
        // The photo itself still decodes, its own size.
        let source = try #require(CGImageSourceCreateWithData(file as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 2400)
    }

    @Test func `a card of large JPEGs is shown from their EXIF thumbnails first, then from their grid thumbnails`(
    ) async throws {
        let sandbox = try await ImportSandbox.make()
        defer { sandbox.remove() }
        let source = try CameraJPEG.card("JPEGS", in: sandbox, count: 6, width: 4500, height: 3000)
        let session = sandbox.session([source])
        var provisional: [String] = []
        var previewed: [String] = []
        var smallest: [String: Int] = [:]
        for await event in session.browse() {
            switch event {
            case let .provisional(ids):
                provisional += ids
                for id in ids {
                    smallest[id] = session.provisionalPreview(id, edge: 320).map { max($0.width, $0.height) }
                }
            case let .previewed(ids):
                #expect(ids.allSatisfy(provisional.contains), "shown from its EXIF thumbnail first")
                previewed += ids
            default:
                break
            }
        }
        #expect(Set(provisional).count == 6 && Set(previewed) == Set(provisional))
        #expect(smallest.values.allSatisfy { $0 == 160 }, "\(smallest)")
        for photo in session.photos {
            try #require(photo.primary.size > ImportSession.provisionalSize)
            #expect(photo.state == .previewed)
            #expect(session.provisionalPreview(photo.id, edge: 320) == nil, "let go once the grid thumbnail is made")
            let key = try #require(photo.primary.contentKey)
            let image = try #require(sandbox.store.data(for: key, tier: .grid).flatMap(StoreImageEncoder.decode))
            #expect(image.width == 384 && image.height == 256)
            // The head first, then all of it.
            #expect(sandbox.reads.bytesRead(photo.url) == PhotoMetadataReader.headLength + Int(photo.primary.size))
        }
    }

    @Test func `a JPEG with a large thumbnail gets its grid thumbnail from it, read alone`() async throws {
        let sandbox = try await ImportSandbox.make()
        defer { sandbox.remove() }
        let source = try CameraJPEG.card("MPF", in: sandbox, count: 3, width: 4500, height: 3000, large: true)
        let session = sandbox.session([source])
        let events = await session.browsed()
        #expect(!events.contains {
            if case .provisional = $0 {
                true
            } else {
                false
            }
        })
        for photo in session.photos {
            try #require(photo.primary.size > ImportSession.provisionalSize)
            #expect(photo.state == .previewed)
            let key = try #require(photo.primary.contentKey)
            let image = try #require(sandbox.store.data(for: key, tier: .grid).flatMap(StoreImageEncoder.decode))
            #expect(image.width == 384 && image.height == 256)
            let read = sandbox.reads.bytesRead(photo.url)
            #expect(read < Int(photo.primary.size) / 2, "\(read) of \(photo.primary.size) bytes read")
        }
    }

    @Test func `a small JPEG is read whole once, as before`() async throws {
        let sandbox = try await ImportSandbox.make()
        defer { sandbox.remove() }
        let source = try CameraJPEG.card("SMALL", in: sandbox, count: 2, width: 800, height: 600)
        let session = sandbox.session([source])
        let events = await session.browsed()
        #expect(!events.contains {
            if case .provisional = $0 {
                true
            } else {
                false
            }
        })
        for photo in session.photos {
            #expect(photo.primary.size < ImportSession.provisionalSize && photo.state == .previewed)
            #expect(sandbox.reads.bytesRead(photo.url) == Int(photo.primary.size))
        }
    }

    /// The first previews of a card of 2,000 camera JPEGs on screen, the card in a reader at UHS-I's speed:
    /// the first, a screenful of the newest (each decoded at a cell's size, as the import grid does), and the
    /// same screenful from grid thumbnails.
    @Test(.measuresSpeed)
    func `a card of 2,000 JPEGs shows its first screenful of previews as fast as a card of raws`() async throws {
        let sandbox = try await ImportSandbox.make(profile: .cardReader)
        defer { sandbox.remove() }
        let source = try CameraJPEG.card("EOS_DIGITAL", in: sandbox, count: 2000, width: 6000, height: 4000, side: 12)
        let session = sandbox.session([source])
        let screenful = 40
        let clock = ContinuousClock()
        let started = clock.now
        var screen: Set<String> = []
        var shown = Set<String>()
        var sharp = Set<String>()
        var first: Duration?
        var whole: Duration?
        var final: Duration?
        for await event in session.browse() {
            switch event {
            case let .listed(_, photos):
                let ids = Array(photos.prefix(screenful))
                session.prioritise(ids)
                screen = Set(ids)
            case let .provisional(ids):
                for id in ids where screen.contains(id) && session.provisionalPreview(id, edge: 320) != nil {
                    shown.insert(id)
                }
            case let .previewed(ids):
                for id in ids where screen.contains(id) {
                    if let key = session.photo(id)?.primary.contentKey,
                       sandbox.store.data(for: key, tier: .grid).flatMap(StoreImageEncoder.decode) != nil {
                        shown.insert(id)
                        sharp.insert(id)
                    }
                }
            default:
                break
            }
            if first == nil, !shown.isEmpty {
                first = clock.now - started
            }
            if whole == nil, !screen.isEmpty, shown.count == screen.count {
                whole = clock.now - started
            }
            if !screen.isEmpty, sharp.count == screen.count {
                final = clock.now - started
                break
            }
        }
        session.close()
        func milliseconds(_ duration: Duration?) -> Double {
            duration.map { Double($0.components.seconds) * 1000 + Double($0.components.attoseconds) / 1e15 } ?? -1
        }
        let size = Double(session.photos.first?.primary.size ?? 0) / 1e6
        print(String(
            format: "IMPORT-JPEG-PREVIEWS %.1f MB JPEGs: first %.0f ms, first %d on screen %.0f ms, all %d sharp %.0f ms",
            size, milliseconds(first), screenful, milliseconds(whole), screenful, milliseconds(final),
        ))
        let firstTime = try #require(first)
        let screenTime = try #require(whole)
        #expect(final != nil)
        #expect(firstTime < .milliseconds(200), "the first preview, against a card of raws' 200 ms")
        #expect(screenTime < .milliseconds(1000), "the first screenful")
    }
}

/// Camera JPEGs for the tests: a photo of random squares, so it's the size a camera's is, with its EXIF and,
/// as a camera writes it, the thumbnail in its EXIF.
enum CameraJPEG {
    /// `side` is the squares' side, in pixels: the smaller, the larger the file.
    static func make(width: Int, height: Int, seed: UInt64, side: Int = 24, thumbnail: Bool = true) throws -> Data {
        let image = try picture(width: width, height: height, seed: seed, side: side)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil,
        ))
        let properties: [CFString: Any] = [
            kCGImageDestinationEmbedThumbnail: thumbnail,
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:05 09:00:00"],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "Canon EOS R6",
            ],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func picture(width: Int, height: Int, seed: UInt64, side: Int) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ))
        var random = SeededRandom(seed: seed)
        for y in stride(from: 0, to: height, by: side) {
            for x in stride(from: 0, to: width, by: side) {
                let value = random.next()
                context.setFillColor(
                    red: CGFloat(value & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                    blue: CGFloat(value >> 16 & 0xFF) / 255, alpha: 1,
                )
                context.fill(CGRect(x: x, y: y, width: side, height: side))
            }
        }
        return try #require(context.makeImage())
    }

    /// A JPEG whose Multi-Picture Format index, an APP2 segment after its EXIF, lists a 1,536 by 1,024 large
    /// thumbnail stored after the photo's own image, as Sony's and Nikon's cameras write theirs; and where that is.
    static func withLargeThumbnail(width: Int, height: Int, seed: UInt64) throws -> (Data, EmbeddedJPEG) {
        let photo = try [UInt8](make(width: width, height: height, seed: seed))
        let large = try [UInt8](make(width: 1536, height: 1024, seed: seed + 1000, thumbnail: false))
        // After the APP0 and APP1 segments.
        var insert = 2
        while photo[insert] == 0xFF, photo[insert + 1] == 0xE0 || photo[insert + 1] == 0xE1 {
            insert += 2 + (Int(photo[insert + 2]) << 8 | Int(photo[insert + 3]))
        }
        func little(_ value: Int, _ bytes: Int) -> [UInt8] {
            (0 ..< bytes).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
        }
        let entries = 3
        let ifd = 8
        let list = ifd + 2 + entries * 12 + 4
        let segment = 4 + 4 + list + 32
        let header = insert + 4 + 4
        let largeStart = photo.count + segment
        var mpf: [UInt8] = Array("MPF\0".utf8) + [0x49, 0x49, 0x2A, 0x00] + little(ifd, 4) + little(entries, 2)
        mpf += little(0xB000, 2) + little(7, 2) + little(4, 4) + Array("0100".utf8)
        mpf += little(0xB001, 2) + little(4, 2) + little(1, 4) + little(2, 4)
        mpf += little(0xB002, 2) + little(7, 2) + little(32, 4) + little(list, 4)
        mpf += little(0, 4)
        mpf += little(0x2003_0000, 4) + little(photo.count + segment, 4) + little(0, 4) + little(0, 4)
        mpf += little(0x0001_0002, 4) + little(large.count, 4) + little(largeStart - header, 4) + little(0, 4)
        let app2: [UInt8] = [0xFF, 0xE2] + [UInt8((mpf.count + 2) >> 8), UInt8((mpf.count + 2) & 0xFF)] + mpf
        precondition(app2.count == segment)
        let file = Array(photo[..<insert]) + app2 + Array(photo[insert...]) + large
        return (Data(file), EmbeddedJPEG(offset: largeStart, length: large.count))
    }

    /// A card named `name` in `sandbox` holding `count` JPEGs below `DCIM/100CANON`, the newest first by their
    /// files' dates: clones of four photos, each longer than the one before by a byte after its end, so each has
    /// a content key of its own. On a volume of its own.
    static func card(
        _ name: String, in sandbox: ImportSandbox, count: Int, width: Int, height: Int, side: Int = 24,
        large: Bool = false,
    ) throws -> ImportSource {
        let root = sandbox.folder.url.appending(path: "Cards/" + name, directoryHint: .isDirectory)
        let folder = root.appending(path: "DCIM/100CANON", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let originals = try (0 ..< min(4, count)).map { number in
            let data = try large
                ? withLargeThumbnail(width: width, height: height, seed: UInt64(number)).0
                : make(width: width, height: height, seed: UInt64(number), side: side)
            let url = root.appending(path: "original-\(number).jpg")
            try data.write(to: url)
            return url
        }
        for number in 0 ..< count {
            let file = folder.appending(path: String(format: "IMG_%04d.JPG", number + 1))
            let original = originals[number % originals.count]
            if clonefile(original.path, file.path, 0) != 0 {
                try FileManager.default.copyItem(at: original, to: file)
            }
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(count: number + 1))
            try handle.close()
            try FileManager.default.setAttributes(
                [.modificationDate: cameraTime(Double(number))], ofItemAtPath: file.path,
            )
        }
        for original in originals {
            try FileManager.default.removeItem(at: original)
        }
        sandbox.fileSystem.mount(root, uuid: "CARD-" + name, name: name)
        return try ImportSource.at(root, fileSystem: sandbox.fileSystem, medium: .card(at: root))
    }
}
