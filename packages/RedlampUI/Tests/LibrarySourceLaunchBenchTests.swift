import Foundation
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// The first screen at launch (LIB-23) for a collection, a smart collection and a folder of the same photos, each shown
/// at quit with a photo in the middle active: from the library starting to open, as the app makes it, to the library
/// open, to the photos shown with the active photo selected, and to the store's thumbnails of the screen the grid goes
/// back to. Each is launched three times and its medians printed. Small enough for every run; at 20,000 photos with
/// `REDLAMP_LAUNCH_BENCH=1` (which xcodebuild hands to the tests from `TEST_RUNNER_REDLAMP_LAUNCH_BENCH=1`), at
/// `REDLAMP_LAUNCH_BENCH_PHOTOS` photos if it's set.
@MainActor
@Suite(.serialized)
struct LibrarySourceLaunchBenchTests {
    nonisolated static let collection = CollectionPath("Launch/Everything")!
    nonisolated static let smart = CollectionPath("Launch/Smart")!
    /// The photos on the screen the grid goes back to.
    static let screen = 40
    static let launches = 3

    static var photos: Int {
        let environment = ProcessInfo.processInfo.environment
        guard environment["REDLAMP_LAUNCH_BENCH"] == "1" else { return 1000 }
        return environment["REDLAMP_LAUNCH_BENCH_PHOTOS"].flatMap(Int.init) ?? 20000
    }

    /// One launch's times from the library starting to open.
    struct Times {
        var opened: Duration
        var shown: Duration
        var thumbnails: Duration
    }

    @Test(.measuresSpeed)
    func `a collection, a smart collection and a folder reach the first screen at launch within the library's second`(
    ) async throws {
        let launches = try LaunchSandbox()
        defer { launches.remove() }
        let count = Self.photos
        try Self.write(count, in: launches)
        var model = launches.launch()
        try await launches.indexed(seconds: Double(max(60, count / 50)))
        await Self.idle()
        let shoot = launches.sandbox.folder("Shoot")
        var report: [String] = []
        var medians: [String: Duration] = [:]
        for (name, source) in [
            ("collection", LibrarySource?.some(.collection(Self.collection))),
            ("smart collection", .collection(Self.smart)), ("folder", nil),
        ] {
            if let source {
                #expect(model.librarySources.show(source))
                try await launches.sandbox.eventually(seconds: 60) {
                    model.librarySources.shown == source && !model.librarySources.isListing && model.items
                        .count == count
                }
            } else {
                model.showFolder(shoot)
                try await launches.sandbox.eventually(seconds: 60) {
                    model.library.isShownFromLibrary && model.items.count == count
                }
            }
            try #require(model.items.count == count, "\(name): \(model.items.count) of \(count) photos shown")
            let active = model.items.allRows[count / 2].url
            let top = model.items.allRows[count / 2 - 10].url
            model.select(active)
            model.libraryViews.topPhoto = top
            var times: [Times] = []
            for _ in 0 ..< Self.launches {
                await launches.quit()
                await Self.idle()
                let started = ContinuousClock.now
                model = launches.launch()
                let launched = model
                let service = try #require(launches.service)
                try await launches.sandbox.eventually(seconds: 60) { service.isReady }
                let opened = ContinuousClock.now - started
                try await launches.sandbox.eventually(seconds: 60) {
                    launched.items.count == count && launched.selection == active
                        && (source == nil ? launched.folder == shoot : launched.librarySources.shown == source)
                }
                let shown = ContinuousClock.now - started
                try #require(launched.selection == active, "\(name): the photo active at quit is active again")
                let place = try #require(launched.library.index(of: launched.libraryViews.restoredTop ?? top))
                let screen = launched.items.allRows[place ..< min(place + Self.screen, count)]
                let loader = launched.thumbnailLoader
                await withTaskGroup(of: Void.self) { group in
                    for item in screen {
                        group.addTask { _ = await loader.image(for: item) }
                    }
                }
                let thumbnails = ContinuousClock.now - started
                #expect(screen.allSatisfy { loader.cached($0) != nil }, "\(name): its screen's thumbnails")
                times.append(Times(opened: opened, shown: shown, thumbnails: thumbnails))
            }
            func median(_ path: KeyPath<Times, Duration>) -> Duration {
                times.map { $0[keyPath: path] }.sorted()[times.count / 2]
            }
            medians[name] = median(\.shown)
            report.append("\(name): open \(Self.ms(median(\.opened))), photos shown with the active photo "
                + "\(Self.ms(median(\.shown))), the screen's thumbnails \(Self.ms(median(\.thumbnails))) "
                + "(each \(times.map { Self.ms($0.shown) }.joined(separator: ", ")))")
        }
        print("The first screen at launch, \(count) photos, medians of \(Self.launches) launches:\n  "
            + report.joined(separator: "\n  "))
        for (name, shown) in medians {
            #expect(shown < .seconds(1), "\(name): \(Self.ms(shown)) to the first screen")
        }
    }

    /// `count` small JPEGs in Shoot, written an hour ago, each its own (a comment of its number in its first bytes
    /// makes its content key its own), every one in the collection through its sidecar; and the smart collection,
    /// which finds them all.
    private static func write(_ count: Int, in launches: LaunchSandbox) throws {
        let shoot = launches.sandbox.folder("Shoot")
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        let jpeg = try SourcesSandbox.jpeg(number: 1)
        let written: [FileAttributeKey: Any] = [.modificationDate: Date(timeIntervalSinceNow: -3600)]
        let sidecar = Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(collections: [collection.text]))
        for number in 0 ..< count {
            let comment = Data("Redlamp launch \(number)".utf8)
            let length = UInt16(comment.count + 2)
            let data = jpeg.prefix(2) + Data([0xFF, 0xFE, UInt8(length >> 8), UInt8(length & 0xFF)]) + comment
                + jpeg.dropFirst(2)
            let url = shoot.appending(path: String(format: "IMG_%05d.JPG", number), directoryHint: .notDirectory)
            try #require(FileManager.default.createFile(atPath: url.path, contents: data, attributes: written))
            try SidecarStore().save(sidecar, for: url)
        }
        try CollectionDefinitions(collections: [smart: .smart("rating>=0")])
            .save(to: CollectionDefinitions.url(in: launches.paths))
    }

    /// Returns once the indexer and the views make no thumbnails, or after 60 s, so a launch measures itself.
    private static func idle() async {
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline, [LibraryIndexer.scheduler, WorkScheduler.shared].contains(where: {
            $0.load().running.values.contains { $0 > 0 }
        }) {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func ms(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        return String(format: "%.0f ms", Double(seconds) * 1000 + Double(attoseconds) / 1e15)
    }
}
