import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RedlampLibrary
@_spi(Harness) @testable import RedlampUI

/// The import grid's thumbnails of a card of JPEGs (LIB-27).
@MainActor
struct ImportThumbnailsTests {
    /// A 3,000 by 2,000 JPEG of random squares, about 2.5 MB, with the thumbnail in its EXIF a camera writes.
    static func largeJPEG() throws -> Data {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 3000, height: 2000, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ))
        var random = SeededRandom(seed: 9)
        for y in stride(from: 0, to: 2000, by: 12) {
            for x in stride(from: 0, to: 3000, by: 12) {
                let value = random.next()
                context.setFillColor(
                    red: CGFloat(value & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                    blue: CGFloat(value >> 16 & 0xFF) / 255, alpha: 1,
                )
                context.fill(CGRect(x: x, y: y, width: 12, height: 12))
            }
        }
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil,
        ))
        let properties: [CFString: Any] = [
            kCGImageDestinationEmbedThumbnail: true, kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:05 09:00:00"],
        ]
        try CGImageDestinationAddImage(destination, #require(context.makeImage()), properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func `a large JPEG is shown from its EXIF thumbnail until its preview is made, then from the preview`(
    ) async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        let folder = fixture.base.appending(path: "JPEGs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let jpeg = try Self.largeJPEG()
        try #require(jpeg.count > ImportSession.provisionalSize)
        try jpeg.write(to: folder.appending(path: "IMG_0001.JPG"))
        // A slow card: the photo's head arrives at once, the rest of it over a second.
        let slow = SimulatedFileSystem(profile: VolumeProfile(
            name: "slow card", latency: .milliseconds(5), bandwidth: 2_000_000, maxInFlight: 1, isLocal: true,
            isInternal: false,
        ))
        let model = fixture.model(fileSystem: slow)
        try await model.addFolder(folder)
        let thumbnails = ImportThumbnails(store: fixture.store)
        try await waitUntil("the provisional preview") { model.photo(at: 0)?.state == .provisional }
        let photo = try #require(model.photo(at: 0))
        var shown: [Int] = []
        thumbnails.load(photo, session: model.shownSession) { _, image in shown.append(image.width) }
        try await waitUntil("the EXIF thumbnail on screen") { !shown.isEmpty }
        #expect(shown == [160] && thumbnails.image(for: photo)?.width == 160)

        try await waitUntil("the preview made", seconds: 30) { model.photo(at: 0)?.state == .previewed }
        let previewed = try #require(model.photo(at: 0))
        #expect(thumbnails.image(for: previewed)?.width == 160, "the EXIF thumbnail until the preview is decoded")
        thumbnails.load(previewed, session: model.shownSession) { _, image in shown.append(image.width) }
        try await waitUntil("the preview on screen") { shown.count == 2 }
        #expect(shown == [160, 320] && thumbnails.image(for: previewed)?.width == 320)
        #expect(model.shownSession?.provisionalPreview(previewed.id, edge: 320) == nil)
        await model.browsed()
        model.close()
    }
}
