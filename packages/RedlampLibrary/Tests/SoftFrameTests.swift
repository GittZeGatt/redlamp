import Foundation
import Testing
@testable import RedlampLibrary

/// The soft-frame check's verdicts (LIB-42): soft frames judged only against their own burst, picks proposed per
/// moment, the best two or bursts only, a frame the user decided never proposed against, and Changed by You.
struct SoftFrameTests {
    private typealias Frame = SoftFrames.Frame

    private static func frame(
        _ id: Int64, _ score: Float?, picked: Bool = false, rejected: Bool = false, rated: Bool = false,
        labelled: Bool = false,
    ) -> Frame {
        Frame(
            photos: [id], sharpness: score.map { PhotoSharpness(focus: .afPoint, score: $0) },
            decision: SoftFrames.Decision(picked: picked, rejected: rejected, rated: rated, labelled: labelled),
        )
    }

    private static func verdicts(_ found: SoftFrames, _ ids: ClosedRange<Int64>) -> [SoftFrames.Verdict] {
        ids.map { found.verdict(of: $0) }
    }

    @Test func `a burst's frames under three quarters of its sharpest are soft, and its sharpest is proposed`() {
        let frames = [Self.frame(1, 10), Self.frame(2, 9), Self.frame(3, 5), Self.frame(4, 7.4)]
        let found = SoftFrames.judge(frames, bursts: [[0, 1, 2, 3]], moments: [[0, 1, 2, 3]], mode: .runsOnly)
        #expect(Self.verdicts(found, 1 ... 4) == [.proposed, .none, .soft, .soft])
        #expect(found.entry(of: 3)?.relative == 0.5)
        #expect(found.entry(of: 2)?.relative == 0.9, "a burst's frames keep their sharpness against its sharpest")
    }

    @Test func `a frame the user decided is never proposed against, and overruling a proposal is Changed by You`() {
        let frames = [
            Self.frame(1, 10, rejected: true), Self.frame(2, 9), Self.frame(3, 5, picked: true),
            Self.frame(4, 4, labelled: true), Self.frame(5, 3),
        ]
        let found = SoftFrames.judge(frames, bursts: [[0, 1, 2, 3, 4]], moments: [[0, 1, 2, 3, 4]], mode: .runsOnly)
        #expect(Self.verdicts(found, 1 ... 5) == [.changed, .none, .changed, .none, .soft])
        #expect(found.photos(.proposed).isEmpty, "the user's pick of a soft frame is the burst's pick")

        let rated = [Self.frame(1, 10), Self.frame(2, 4, rated: true), Self.frame(3, 9.5)]
        let again = SoftFrames.judge(rated, bursts: [[0, 1, 2]], moments: [[0, 1, 2]], mode: .runsOnly)
        #expect(Self.verdicts(again, 1 ... 3) == [.proposed, .changed, .none], "a rating keeps a soft frame")
    }

    @Test func `a rejected sharpest frame passes the proposal to the next one`() {
        let frames = [Self.frame(1, 10, rejected: true), Self.frame(2, 9), Self.frame(3, 8.8)]
        let found = SoftFrames.judge(frames, bursts: [[0, 1, 2]], moments: [[0, 1, 2]], mode: .runsOnly)
        #expect(Self.verdicts(found, 1 ... 3) == [.changed, .proposed, .none])
    }

    @Test func `one pick per moment and the best two are chosen across its bursts and single frames`() {
        // A moment of a burst (1 to 3) and two frames shot alone (4, 5); then a moment of one frame.
        let frames = [
            Self.frame(1, 8), Self.frame(2, 4), Self.frame(3, 7.9), Self.frame(4, 9), Self.frame(5, 2),
            Self.frame(6, 9),
        ]
        let bursts = [[0, 1, 2]]
        let moments = [[0, 1, 2, 3, 4], [5]]
        let one = SoftFrames.judge(frames, bursts: bursts, moments: moments, mode: .onePerMoment)
        #expect(Self.verdicts(one, 1 ... 6) == [.none, .soft, .none, .proposed, .none, .none])
        let two = SoftFrames.judge(frames, bursts: bursts, moments: moments, mode: .bestTwo)
        #expect(Self.verdicts(two, 1 ... 6) == [.proposed, .soft, .none, .proposed, .none, .none])
        let runs = SoftFrames.judge(frames, bursts: bursts, moments: moments, mode: .runsOnly)
        #expect(Self.verdicts(runs, 1 ... 6) == [.proposed, .soft, .none, .none, .none, .none])
        #expect(two.verdict(of: 5) == .none, "a frame shot alone is never soft")
    }

    @Test func `a pick the user made counts towards the moment's`() {
        let frames = [Self.frame(1, 10), Self.frame(2, 2, picked: true), Self.frame(3, 9), Self.frame(4, 8)]
        let one = SoftFrames.judge(frames, bursts: [], moments: [[0, 1, 2, 3]], mode: .onePerMoment)
        #expect(one.photos(.proposed).isEmpty)
        let two = SoftFrames.judge(frames, bursts: [], moments: [[0, 1, 2, 3]], mode: .bestTwo)
        #expect(two.photos(.proposed) == [1])
    }

    @Test func `nothing is proposed where there's no choice`() {
        let frames = [Self.frame(1, 10), Self.frame(2, nil), Self.frame(3, 9), Self.frame(4, 7)]
        let found = SoftFrames.judge(frames, bursts: [[0, 1]], moments: [[0, 1], [2, 3]], mode: .bestTwo)
        #expect(found.isEmpty, "a burst with one frame measured, and moments of two for the best two")
    }

    @Test func `without an AF point, frames are compared in the cell where the burst's sharpest frame is sharpest`() {
        func gridded(_ id: Int64, _ cells: [Float]) -> Frame {
            Frame(photos: [id], sharpness: PhotoSharpness(focus: .grid, cells: cells))
        }
        var sharp = [Float](repeating: 1, count: 24)
        sharp[9] = 10
        var missed = [Float](repeating: 1, count: 24)
        missed[9] = 4
        missed[20] = 9
        let frames = [gridded(1, sharp), gridded(2, missed), Self.frame(3, 50)]
        let found = SoftFrames.judge(frames, bursts: [[0, 1, 2]], moments: [[0, 1, 2]], mode: .runsOnly)
        #expect(Self.verdicts(found, 1 ... 3) == [.proposed, .soft, .none])
        #expect(found.entry(of: 2)?.relative == 0.4)
        #expect(found.entry(of: 3)?.relative == nil, "the frame measured at its AF point is left out")
    }

    // MARK: - From the column store

    /// A shoot: a burst of five frames (photos 1 to 6, its third frame a raw and its JPEG, 3 and 4), a frame shot alone
    /// a few seconds later (7), then, ten minutes later, a burst of three (8 to 10) in a moment of its own.
    private static func shoot() -> StackLibrary {
        var library = StackLibrary()
        let start = 1_700_000_000.0
        library.add("A_0001.CR3", at: start)
        library.add("A_0002.CR3", at: start + 0.1)
        library.addPair("A_0003", at: start + 0.2)
        library.add("A_0004.CR3", at: start + 0.3)
        library.add("A_0005.CR3", at: start + 0.4)
        library.add("A_0006.CR3", at: start + 5)
        library.add("B_0001.CR3", at: start + 600)
        library.add("B_0002.CR3", at: start + 600.1)
        library.add("B_0003.CR3", at: start + 600.2)
        return library
    }

    /// Photo 6 isn't measured, and the pair is by its JPEG.
    private static let scores: [Int64: Float] = [1: 6, 2: 10, 4: 3, 5: 9, 7: 12, 8: 12, 9: 5, 10: 9]

    private static var sharpness: [Int64: PhotoSharpness] {
        scores.mapValues { PhotoSharpness(focus: .afPoint, score: $0) }
    }

    private static func store(_ library: StackLibrary, flags: [Int64: Int] = [:]) -> ColumnStore {
        ColumnStore(rows: library.photos.map { photo in
            ColumnStore.Row(HotColumns(
                id: photo.id, folder: photo.folder, captured: photo.captured, camera: photo.camera, lens: photo.lens,
                rating: 0, flag: flags[photo.id] ?? 0, label: 0, marked: false, edited: false, iso: photo.iso,
                aperture: photo.aperture, focal: photo.focal,
                kind: PhotoRecord.Kind(pathExtension: (photo.name as NSString).pathExtension).rawValue,
                name: photo.name,
            ), shutter: photo.shutter)
        })
    }

    @Test func `a library's bursts and moments are judged from the column store, a raw and its JPEG as one frame`() {
        let library = Self.shoot()
        let stacks = library.find()
        #expect(stacks.photos(.burst) == [[1, 2, 3, 5, 6], [8, 9, 10]])
        let store = Self.store(library)
        let all = RowBits(rows: store.rowCount, filled: true)

        let runs = store.softFrames(
            of: all,
            stacks: stacks,
            sharpness: Self.sharpness,
            mode: .runsOnly,
            setting: .init(),
        )
        #expect(runs.photos(.proposed).sorted() == [2, 8])
        #expect(runs.photos(.soft).sorted() == [1, 3, 4, 9], "the pair is soft by its JPEG, and frame 10 at 0.75 isn't")
        #expect(runs.verdict(of: 6) == .none && runs.verdict(of: 7) == .none, "6 isn't measured; 7 is shot alone")

        let moments = store.softFrames(
            of: all, stacks: stacks, sharpness: Self.sharpness, mode: .onePerMoment, setting: .init(),
        )
        #expect(moments.photos(.proposed).sorted() == [7, 8], "the frame shot alone is the first moment's sharpest")

        let decided = Self.store(library, flags: [2: 2, 4: 1])
        let overruled = decided.softFrames(
            of: all, stacks: stacks, sharpness: Self.sharpness, mode: .runsOnly, setting: .init(),
        )
        #expect(overruled.photos(.changed).sorted() == [2, 3, 4], "the JPEG's pick is its raw's")
        #expect(overruled.photos(.proposed) == [8], "the pair's pick is its burst's")
    }

    @Test func `a source's photos are judged among themselves`() throws {
        let library = Self.shoot()
        let store = Self.store(library)
        func judged(_ ids: [Int64]) throws -> SoftFrames {
            var rows = RowBits(rows: store.rowCount)
            for id in ids {
                try rows.insert(#require(store.row(of: id)))
            }
            return store.softFrames(
                of: rows, stacks: library.find(), sharpness: Self.sharpness, mode: .runsOnly, setting: .init(),
            )
        }
        let first = try judged([8, 9])
        #expect(first.photos(.proposed) == [8] && first.photos(.soft) == [9] && first.verdict(of: 10) == .none)
        let last = try judged([9, 10])
        #expect(last.photos(.proposed) == [10] && last.photos(.soft) == [9], "9 is soft against 10 alone too")
    }

    @Test(.measuresSpeed) func `a burst of twenty is judged in well under a millisecond`() {
        var library = StackLibrary()
        for frame in 0 ..< 20 {
            library.add(String(format: "C_%04d.CR3", frame), at: 1_700_000_000 + Double(frame) * 0.1)
        }
        let store = Self.store(library)
        let stacks = library.find()
        let sharpness = Dictionary(uniqueKeysWithValues: (1 ... 20).map { id in
            (Int64(id), PhotoSharpness(focus: .afPoint, score: Float(10 + id % 7)))
        })
        let all = RowBits(rows: store.rowCount, filled: true)
        let clock = ContinuousClock()
        var times: [Duration] = []
        for _ in 0 ..< 200 {
            let started = clock.now
            _ = store.softFrames(of: all, stacks: stacks, sharpness: sharpness, mode: .bestTwo, setting: .init())
            times.append(clock.now - started)
        }
        let median = times.sorted()[times.count / 2]
        print("SOFT-FRAMES-BENCH a burst of 20 judged: median \(median), slowest \(times.max()!)")
        #expect(median < .milliseconds(1))
    }
}
