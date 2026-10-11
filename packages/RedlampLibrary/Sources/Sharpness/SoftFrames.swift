import Foundation

/// What the soft-frame check makes of a library's bursts and moments (LIB-42), without a model: each frame measured
/// at the camera's focus point on its largest embedded preview (`PhotoSharpness`), judged only against the frames
/// shot with it.
///
/// - **Soft frames:** a burst's frames under `softBelow` of its sharpest frame's sharpness. A frame shot alone is
///   never soft: there's nothing to judge it against.
/// - **Proposed picks:** by `Mode`, the sharpest frame of each moment, the two sharpest, or the sharpest of each
///   burst alone; never a soft frame, and only where there's a choice, a group having more frames measured than it
///   proposes. A pick the user made counts towards the group's picks.
/// - **A frame the user decided** (rated, flagged or labelled) is never proposed against: it's neither proposed nor
///   soft. Where the decision goes against what would have been proposed, a pick or a rating for a soft frame, or a
///   reject for the frame that would have been proposed, it's **Changed by You**.
///
/// Frames are compared at their AF points when at least half of a group's measured frames have one, else in the
/// grid's cell where the group's sharpest frame is sharpest (`SharpnessMeasure.cells`): where the camera says nothing
/// of its focus, the part of the frame the burst is sharpest in is where it was most likely aimed. A frame measured
/// the other way is left out of that group's judgement. A raw and its JPEG are one frame, judged by the raw.
///
/// Nothing is written to sidecars: the verdicts are worked out again from the index's measurements and the frames'
/// decisions whenever either changes.
public struct SoftFrames: Sendable, Equatable {
    /// What's proposed.
    public enum Mode: String, Sendable, Hashable, CaseIterable, Codable {
        /// The sharpest frame of each moment.
        case onePerMoment = "moment"
        /// The two sharpest frames of each moment.
        case bestTwo = "two"
        /// The sharpest frame of each burst, and nothing for frames shot alone.
        case runsOnly = "runs"

        public var title: String {
            switch self {
            case .onePerMoment: "One per Moment"
            case .bestTwo: "Two per Moment"
            case .runsOnly: "Bursts Only"
            }
        }

        /// The picks proposed in each moment, or in each burst.
        var quota: Int {
            self == .bestTwo ? 2 : 1
        }
    }

    public enum Verdict: UInt8, Sendable, Hashable, CaseIterable {
        case none = 0
        /// Undecided, and proposed as a pick.
        case proposed
        /// Undecided, and soft against its burst's sharpest frame.
        case soft
        /// Decided against what would have been proposed.
        case changed
    }

    /// A frame is soft under three quarters of its burst's sharpest frame's sharpness: "about 25% softer". The one
    /// threshold, set on test bursts (`SoftFrameSamples`, whose sharp frames read 0.99 or more and whose soft ones 0.40
    /// or less) and to be tuned on shoots the owner has culled (DEC-61): it should keep his picks out of the soft
    /// frames
    /// and catch most of his rejects for focus.
    public static let softBelow: Float = 0.75

    /// A frame's verdict and its sharpness against its burst's sharpest, where it has one.
    public struct Entry: Sendable, Hashable {
        public var verdict: Verdict
        /// Its sharpness over its burst's sharpest frame's, 0 ... 1; nil for a frame not judged in a burst.
        public var relative: Float?

        public init(verdict: Verdict, relative: Float? = nil) {
            self.verdict = verdict
            self.relative = relative
        }
    }

    /// The entries of the photos with a verdict, by photo ID.
    let entries: [Int64: Entry]

    init(entries: [Int64: Entry] = [:]) {
        self.entries = entries
    }

    public static let empty = SoftFrames()

    public func verdict(of photo: Int64) -> Verdict {
        entries[photo]?.verdict ?? .none
    }

    public func entry(of photo: Int64) -> Entry? {
        entries[photo]
    }

    /// The photos with `verdict`, in no order.
    public func photos(_ verdict: Verdict) -> [Int64] {
        entries.compactMap { $0.value.verdict == verdict ? $0.key : nil }
    }

    public var isEmpty: Bool {
        entries.isEmpty
    }

    // MARK: - Judging

    /// A frame as the check judges it: its photos, the top one first (a raw, then its JPEG), how it measured, and
    /// what the user decided of it.
    struct Frame: Sendable {
        var photos: [Int64]
        var sharpness: PhotoSharpness?
        var decision = Decision()
    }

    /// What the user decided of a frame, any of its photos counting.
    struct Decision: Sendable, Hashable {
        var picked = false
        var rejected = false
        var rated = false
        var labelled = false

        var isDecided: Bool {
            picked || rejected || rated || labelled
        }

        /// Kept: picked, or rated.
        var keeps: Bool {
            picked || rated
        }
    }

    /// The verdicts of `frames`: `bursts` and `moments` are the frames of each, by their places in `frames`.
    static func judge(_ frames: [Frame], bursts: [[Int]], moments: [[Int]], mode: Mode) -> SoftFrames {
        var soft = [Bool](repeating: false, count: frames.count)
        var relative = [Float?](repeating: nil, count: frames.count)
        for burst in bursts where burst.count > 1 {
            let scores = Self.scores(of: burst, in: frames)
            guard let sharpest = scores.compactMap(\.self).max(), sharpest > 0,
                  scores.count(where: { $0 != nil }) > 1 else { continue }
            for (place, score) in zip(burst, scores) {
                guard let score else { continue }
                relative[place] = score / sharpest
                soft[place] = score / sharpest < softBelow
            }
        }
        var proposed = [Bool](repeating: false, count: frames.count)
        var changed = [Bool](repeating: false, count: frames.count)
        for place in frames.indices where soft[place] && frames[place].decision.keeps {
            changed[place] = true
        }
        for group in mode == .runsOnly ? bursts : moments where group.count > mode.quota {
            let scores = Self.scores(of: group, in: frames)
            guard scores.count(where: { $0 != nil }) > mode.quota else { continue }
            var ranked: [(place: Int, score: Float)] = []
            for (place, score) in zip(group, scores) {
                if let score, !soft[place] {
                    ranked.append((place, score))
                }
            }
            ranked.sort { lhs, rhs in lhs.score != rhs.score ? lhs.score > rhs.score : lhs.place < rhs.place }
            for entry in ranked.prefix(mode.quota) where frames[entry.place].decision.rejected {
                changed[entry.place] = true
            }
            let picks = group.count(where: { frames[$0].decision.picked })
            let open = ranked.filter { !frames[$0.place].decision.isDecided }
            for entry in open.prefix(max(0, mode.quota - picks)) {
                proposed[entry.place] = true
            }
        }
        var entries: [Int64: Entry] = [:]
        for (place, frame) in frames.enumerated() {
            let decided = frame.decision.isDecided
            let verdict: Verdict = if decided {
                changed[place] ? .changed : .none
            } else if proposed[place] {
                .proposed
            } else if soft[place] {
                .soft
            } else {
                .none
            }
            guard verdict != .none || relative[place] != nil else { continue }
            for photo in frame.photos {
                entries[photo] = Entry(verdict: verdict, relative: relative[place])
            }
        }
        return SoftFrames(entries: entries)
    }

    /// The scores of `group`'s frames against each other: at the AF point when at least half of those measured have
    /// one, else in the grid's cell where the group's sharpest frame is sharpest; nil for a frame measured the other
    /// way, or not at all.
    static func scores(of group: [Int], in frames: [Frame]) -> [Float?] {
        var focused = 0
        var gridded = 0
        for place in group {
            guard let focus = frames[place].sharpness?.focus else { continue }
            switch focus {
            case .afPoint: focused += 1
            case .grid: gridded += 1
            case .unmeasured: break
            }
        }
        guard focused + gridded > 0 else { return group.map { _ in nil } }
        if focused >= gridded {
            return group.map { place in
                frames[place].sharpness.flatMap { $0.focus == .afPoint ? $0.score : nil }
            }
        }
        var best: (cell: Int, score: Float)?
        for place in group {
            guard let sharpness = frames[place].sharpness, sharpness.focus == .grid else { continue }
            for (cell, score) in sharpness.cells.enumerated() where score > best?.score ?? -1 {
                best = (cell, score)
            }
        }
        guard let cell = best?.cell else { return group.map { _ in nil } }
        return group.map { place in
            frames[place].sharpness.flatMap { sharpness in
                sharpness.focus == .grid && sharpness.cells.indices.contains(cell) ? sharpness.cells[cell] : nil
            }
        }
    }
}
