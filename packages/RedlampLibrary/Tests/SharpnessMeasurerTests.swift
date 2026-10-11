import Foundation
import RedlampDocument
import Synchronization
import Testing
@testable import RedlampLibrary

/// The soft-frame measurer (LIB-42): a source's bursts measured in the background, written to the index by content
/// key and handed to the engine, so the terms find the soft frames; nothing measured while the app says not to, and
/// a file that's away left for later rather than taken for one without a preview.
struct SharpnessMeasurerTests {
    private static let scheduler = WorkScheduler(
        widths: WorkScheduler.Widths(onScreen: 2, lookAhead: 2, background: 2), canRunBackground: { true },
    )

    /// An index of two bursts written to a folder of their own: four frames whose third is out of focus, then, ten
    /// minutes later, three frames whose last moved.
    private static func shoot() async throws -> (sandbox: IndexSandbox, folder: URL, ids: [Int64]) {
        let sandbox = try await IndexSandbox.make()
        let folder = sandbox.directory.appending(path: "Shoot", directoryHint: .isDirectory)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try SoftFrameSamples.writeBurst(
            [.sharp(shift: 0), .sharp(shift: 1), .blurred(sigma: 2), .sharp(shift: 2)], to: folder, name: "A_",
            start: start,
        )
        let second = try SoftFrameSamples.writeBurst(
            [.sharp(shift: 0), .brighter, .motion(length: 9)], to: folder, name: "B_",
            start: start.addingTimeInterval(600), seed: 2,
        )
        let root = sandbox.root
        let ids = try await sandbox.index.write { writer in
            let folderID = try writer.upsertFolder(FolderRecord(root: root, parent: nil, path: folder.path))
            try writer.database.execute(
                "INSERT INTO cameras (id, make, model, name) VALUES (1, 'Redlamp', 'Test Body', 'Redlamp Test Body')",
            )
            let photos = (first + second).enumerated().map { place, url in
                let captured = start.addingTimeInterval(place < 4 ? Double(place) / 10 : 600 + Double(place - 4) / 10)
                return PhotoRecord(
                    folder: folderID, name: url.lastPathComponent, size: 1000, modified: captured,
                    contentKey: Data(repeating: UInt8(place + 1), count: 16), captured: captured, camera: 1,
                    shutter: 1.0 / 500, width: SoftFrameSamples.width, height: SoftFrameSamples.height, indexed: 1,
                )
            }
            return try writer.upsertPhotos(photos)
        }
        return (sandbox, folder, ids)
    }

    @Test func `a source's bursts are measured in the background, and the terms find their soft frames`() async throws {
        let (sandbox, _, ids) = try await Self.shoot()
        defer { sandbox.remove() }
        let engine = QueryEngine(index: sandbox.index, timeZone: .gmt)
        try await engine.load()
        let heard = Mutex<[Int64]>([])
        let measurer = SharpnessMeasurer(
            index: sandbox.index, engine: engine, scheduler: Self.scheduler,
            measured: { photos in heard.withLock { $0 += photos } },
        )
        let candidates = try await engine.softFrameCandidates(of: .allPhotographs)
        #expect(Set(candidates) == Set(ids), "every frame of both bursts")
        measurer.measure(candidates)
        await measurer.finish()
        #expect(measurer.count == 7 && heard.withLock { $0.count } == 7)
        #expect(try await sandbox.index.read { try $0.photoSharpnessCount() } == 7)

        engine.setProposalMode(.runsOnly)
        #expect(try await Set(engine.ids("is:soft")) == [ids[2], ids[6]])
        #expect(try await Set(engine.ids("is:proposed")).count == 2)

        measurer.measure(candidates)
        await measurer.finish()
        #expect(measurer.count == 7, "a photo asked for again isn't measured again")
    }

    @Test func `nothing is measured while the app says not to, and a file that's away is left for later`() async throws {
        let (sandbox, folder, ids) = try await Self.shoot()
        defer { sandbox.remove() }
        let engine = QueryEngine(index: sandbox.index, timeZone: .gmt)
        try await engine.load()
        let allowed = Mutex(false)
        let measurer = SharpnessMeasurer(
            index: sandbox.index, engine: engine, scheduler: Self.scheduler, mayRun: { allowed.withLock { $0 } },
        )
        try FileManager.default.removeItem(at: folder.appending(path: "A_0001.JPG"))
        measurer.measure(ids)
        try await Task.sleep(for: .milliseconds(300))
        #expect(measurer.count == 0 && measurer.isBusy, "waiting while the index is updated")
        allowed.withLock { $0 = true }
        await measurer.finish()
        #expect(measurer.count == 6)
        let left = try await sandbox.index.read { try $0.sharpnessCandidates(ids) }
        #expect(left.map(\.photo) == [ids[0]], "the frame whose file went is measured once it's back")
    }
}
