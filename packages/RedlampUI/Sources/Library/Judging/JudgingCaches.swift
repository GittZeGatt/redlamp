import CoreGraphics
import Foundation
import RedlampDocument
import RedlampLibrary

/// A photo as the loupe or Compare shows it: its embedded preview or the photo itself when `edit` is nil, else the
/// render of that edit. What focus peaking reads, and what sensor clipping renders, differ between the two.
struct ShownPhoto: Hashable {
    let url: URL
    let edit: EditDigest?
}

/// The AF points read from photos' files (LIB-38), kept for the photos culled lately: a read maps the file and
/// touches only its first directories, a few milliseconds on the scheduler's on-screen lane.
@MainActor
final class AFPointCache {
    static let kept = 256

    private var known: [URL: AFPoints?] = [:]
    private var order: [URL] = []
    private var reading: [URL: [(AFPoints?) -> Void]] = [:]

    /// What's known of `url`'s AF point: nil while it hasn't been read, `.some(nil)` when the file records none.
    func cached(_ url: URL) -> AFPoints?? {
        known[url]
    }

    /// Reads `url`'s AF point unless it's known, and hands it over on the main actor.
    func request(
        _ url: URL, imageSize: CGSize?, scheduler: WorkScheduler, then done: @escaping (AFPoints?) -> Void,
    ) {
        if let points = known[url] {
            return done(points)
        }
        if reading[url] != nil {
            reading[url]?.append(done)
            return
        }
        reading[url] = [done]
        Task { [weak self] in
            let points = try? await scheduler.run(.onScreen) { AFPointReader.read(url, imageSize: imageSize) }
            guard let self else { return }
            let found = points ?? nil
            remember(url, found)
            for done in reading.removeValue(forKey: url) ?? [] {
                done(found)
            }
        }
    }

    private func remember(_ url: URL, _ points: AFPoints?) {
        if known.updateValue(points, forKey: url) == nil {
            order.append(url)
        }
        if order.count > Self.kept {
            known.removeValue(forKey: order.removeFirst())
        }
    }
}

/// Focus peaking's masks (LIB-38), kept for the few photos last shown: at the largest size read, for 1:1 and the
/// following loupe, as the alpha its layer shows.
@MainActor
final class PeakingCache {
    /// A photo's peaking: the mask at the size read, and its alpha image for the zoomed views. Made off the main
    /// thread, then read and pooled again only on it.
    final class Entry: @unchecked Sendable {
        let mask: PeakingMask
        let image: CGImage?
        /// The mask pooled to the size the photo was last shown at fit, and that size's long edge.
        var shown: (longEdge: Int, image: CGImage?)?

        init(mask: PeakingMask, shownLongEdge: Int) {
            self.mask = mask
            image = mask.image()
            if shownLongEdge < max(mask.width, mask.height) {
                shown = (shownLongEdge, mask.pooled(toLongEdge: shownLongEdge).image())
            }
        }

        /// The alpha image to show the photo `longEdge` pixels long at, pooled from the mask when it's larger.
        func image(forLongEdge longEdge: Int) -> CGImage? {
            guard longEdge < max(mask.width, mask.height) else { return image }
            if let shown, shown.longEdge == longEdge {
                return shown.image
            }
            let image = mask.pooled(toLongEdge: longEdge).image()
            shown = (longEdge, image)
            return image
        }
    }

    static let kept = 3

    private var entries: [ShownPhoto: Entry] = [:]
    private var order: [ShownPhoto] = []
    private var reading: [ShownPhoto: [(Entry?) -> Void]] = [:]
    /// Time spent reading masks, for the tests: the photos read and the total.
    private(set) var read = (count: 0, time: Duration.zero)

    func cached(_ key: ShownPhoto) -> Entry? {
        entries[key]
    }

    /// Reads the mask of the image `source` gives, off the main thread, pooled for a photo shown `shownLongEdge`
    /// pixels long at fit, unless it's kept.
    func request(
        _ key: ShownPhoto, scheduler: WorkScheduler, shownLongEdge: Int, source: @escaping @Sendable () -> CGImage?,
        then done: @escaping (Entry?) -> Void,
    ) {
        if let entry = entries[key] {
            return done(entry)
        }
        if reading[key] != nil {
            reading[key]?.append(done)
            return
        }
        reading[key] = [done]
        let started = ContinuousClock.now
        Task { [weak self] in
            let made = try? await scheduler.run(.onScreen) {
                source().flatMap { FocusPeaking.mask(of: $0) }.map { Entry(mask: $0, shownLongEdge: shownLongEdge) }
            }
            guard let self else { return }
            let entry = made ?? nil
            if let entry {
                read = (read.count + 1, read.time + (.now - started))
                entries[key] = entry
                order.removeAll { $0 == key }
                order.append(key)
                if order.count > Self.kept {
                    entries.removeValue(forKey: order.removeFirst())
                }
            }
            for done in reading.removeValue(forKey: key) ?? [] {
                done(entry)
            }
        }
    }
}
