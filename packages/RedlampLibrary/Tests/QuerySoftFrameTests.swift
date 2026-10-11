import Foundation
import Testing
@testable import RedlampLibrary

/// The soft-frame terms (LIB-42): `is:proposed`, `is:soft` and `is:changed-by-you` in the query language, found by the
/// engine from the store, the library's bursts and the index's measurements, in the mode it proposes in, and their
/// first page at a million photos within the query engine's budget (p95 16 ms).
struct QuerySoftFrameTests {
    /// A source of a store, its stacks and its measurements, all in memory.
    final class Source: QuerySource {
        struct Unsupported: Error {}

        let store: ColumnStore
        let stacks: Stacks
        let sharpness: [Int64: PhotoSharpness]

        init(store: ColumnStore, stacks: Stacks, sharpness: [Int64: PhotoSharpness]) {
            self.store = store
            self.stacks = stacks
            self.sharpness = sharpness
        }

        func columnStore() async throws -> ColumnStore {
            store
        }

        func names() async throws -> QueryNames {
            QueryNames()
        }

        func photoIDs(matching _: String) async throws -> [Int64] {
            []
        }

        func photoIDs(withKeywords _: [Int64]) async throws -> [Int64] {
            []
        }

        func photoIDs(inCollections _: [Int64]) async throws -> [Int64] {
            []
        }

        func applying(_: [Int64], to store: ColumnStore) async throws -> ColumnStore {
            store
        }

        func run(
            _: QuerySQL, pageSize _: Int, cancellation _: QueryCancellation,
            firstPage _: @escaping @Sendable (ContiguousArray<Int64>) -> Void,
        ) async throws -> ContiguousArray<Int64> {
            throw Unsupported()
        }

        func photoSharpness(of ids: [Int64]?) async throws -> [Int64: PhotoSharpness] {
            guard let ids else { return sharpness }
            return sharpness.filter { ids.contains($0.key) }
        }

        func softFrameStacks(store _: ColumnStore) async throws -> Stacks {
            stacks
        }
    }

    /// `folders` folders of a thousand photos in 40 moments a quarter of an hour apart: in each of the first `bursts`
    /// moments a burst of ten frames a tenth of a second apart, then 15 frames shot alone ten seconds apart; every
    /// frame of a burst measured and a fifth of them soft; one frame in 16 rated, one in 25 rejected, one in 200
    /// picked.
    static func library(folders: Int, bursts: Int = 40)
        -> (store: ColumnStore, stacks: Stacks, sharpness: [Int64: PhotoSharpness]) {
        var builder = ColumnStore.Builder(capacity: folders * 1000)
        var members = ContiguousArray<Int64>()
        var starts = ContiguousArray<Int32>([0])
        var sharpness: [Int64: PhotoSharpness] = [:]
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(truncatingIfNeeded: state >> 33)
        }
        var id: Int64 = 0
        for folder in 0 ..< folders {
            let day = 1.5e9 + Double(folder) * 86400
            for place in 0 ..< 1000 {
                id += 1
                let (moment, within) = place.quotientAndRemainder(dividingBy: 25)
                let inBurst = moment < bursts && within < 10
                let offset = inBurst ? Double(within) / 10 : 5 + Double(within) * 10
                if inBurst {
                    members.append(id)
                    if within == 9 {
                        starts.append(Int32(members.count))
                    }
                    let score = random() % 5 == 0 ? 2 + random() % 4 : 9 + random() % 3
                    sharpness[id] = PhotoSharpness(focus: .afPoint, score: Float(score))
                }
                let roll = random() % 200
                builder.add(ColumnStore.Row(HotColumns(
                    id: id, folder: Int64(folder + 1), captured: day + Double(moment) * 900 + offset, camera: nil,
                    lens: nil, rating: roll < 12 ? 3 : 0, flag: roll == 199 ? 1 : (12 ..< 20).contains(roll) ? 2 : 0,
                    label: 0, marked: false, edited: false, iso: 400, aperture: 2.8, focal: 50,
                    kind: PhotoRecord.Kind.raw.rawValue, name: "IMG_\(id).CR3",
                ), shutter: 1.0 / 500))
            }
        }
        let count = starts.count - 1
        let stacks = Stacks(
            members: members, starts: starts, kinds: ContiguousArray(repeating: .burst, count: count), ids: [:],
            pairs: 0, groups: count, photos: Int(id) + 1,
        )
        return (builder.finish(), stacks, sharpness)
    }

    @Test func `the terms parse, describe themselves and complete`() throws {
        for (text, trait) in [
            ("is:proposed", LibraryQuery.Trait.proposed), ("is:soft", .soft), ("is:changed-by-you", .changedByYou),
        ] {
            let query = try LibraryQuery(parsing: text)
            #expect(query == .filter(LibraryQuery.Filter(.trait, .equal, [.trait(trait)])))
            #expect(query.findsSoftFrames && query.needsStore && query.findsMoments)
            #expect(try LibraryQuery(parsing: query.description) == query, "\(query.description)")
        }
        #expect(LibraryQuery.Trait.changedByYou.title == "Changed by You")
    }

    @Test func `the engine finds each term's photos, in the mode it proposes in`() async throws {
        let library = Self.library(folders: 2, bursts: 5)
        let engine = QueryEngine(
            source: Source(store: library.store, stacks: library.stacks, sharpness: library.sharpness),
            timeZone: .gmt,
        )
        try await engine.load()
        let all = RowBits(rows: library.store.rowCount, filled: true)
        for mode in SoftFrames.Mode.allCases {
            engine.setProposalMode(mode)
            let expected = library.store.softFrames(
                of: all, stacks: library.stacks, sharpness: library.sharpness, mode: mode, setting: MomentSetting(),
            )
            for (term, verdict) in [
                ("is:proposed", SoftFrames.Verdict.proposed),
                ("is:soft", .soft),
                ("is:changed-by-you", .changed),
            ] {
                let found = try await engine.ids(term)
                #expect(Set(found) == Set(expected.photos(verdict)), "\(term) in \(mode)")
            }
            #expect(try await engine.softFrames(of: .allPhotographs).photos(.proposed).count
                == expected.photos(.proposed).count)
        }
        #expect(try await !engine.ids("is:soft").isEmpty)
    }

    @Test func `new measurements are judged as the measurer records them`() async throws {
        let library = Self.library(folders: 1, bursts: 2)
        let engine = QueryEngine(
            source: Source(store: library.store, stacks: library.stacks, sharpness: [:]),
            timeZone: .gmt,
        )
        try await engine.load()
        #expect(try await engine.ids("is:proposed").isEmpty)
        engine.addSharpness(library.sharpness)
        let proposed = try await engine.ids("is:proposed")
        #expect(!proposed.isEmpty && engine.measuredCount == library.sharpness.count)
    }

    @Test(.measuresSpeed) func `a million photos: the terms' first page and count as each character is typed`(
    ) async throws {
        let clock = ContinuousClock()
        let building = clock.now
        let library = Self.library(folders: 1000)
        print(String(
            format: "SOFT-QUERY-BENCH store of %ld photos with %ld measured in %.0f ms", library.store.count,
            library.sharpness.count, (clock.now - building) / .milliseconds(1),
        ))
        let engine = QueryEngine(
            source: Source(store: library.store, stacks: library.stacks, sharpness: library.sharpness),
            timeZone: .gmt,
        )
        try await engine.load()
        let judging = clock.now
        let verdicts = try await engine.softFrames(of: .allPhotographs)
        print(String(
            format: "SOFT-QUERY-BENCH all photographs judged in %.0f ms: %ld proposed, %ld soft, %ld changed by you",
            (clock.now - judging) / .milliseconds(1), verdicts.photos(.proposed).count, verdicts.photos(.soft).count,
            verdicts.photos(.changed).count,
        ))
        let queries = ["is:proposed", "is:soft", "is:changed-by-you", "is:proposed,soft", "is:soft -flag:reject"]
        var firsts: [Duration] = []
        for query in queries {
            for typed in QueryMillionTests.typed(query) {
                let started = clock.now
                var first: Duration?
                for try await _ in try engine.search(LibraryQuery(parsing: typed, asYouType: true)) {
                    first = first ?? clock.now - started
                }
                firsts.append(first ?? clock.now - started)
            }
        }
        let sorted = firsts.sorted()
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] / .milliseconds(1)
        try print(String(
            format: "SOFT-QUERY-BENCH %ld keystrokes: first page and count p50 %.2f ms, p95 %.2f ms, slowest %.2f ms",
            firsts.count, sorted[sorted.count / 2] / .milliseconds(1), p95,
            #require(sorted.last) / .milliseconds(1),
        ))
        #expect(p95 < 16)
        #expect(try await engine.ids("is:soft").count == verdicts.photos(.soft).count)
    }
}
