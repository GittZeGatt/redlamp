import Foundation

/// What `redlamp library sidecars --move` says of a move (LIB-11): the sidecars it moved, or would; the photos with a
/// copy in each place it settled (DEC-63), the copy saved last kept where the move takes them and the other set aside
/// in a folder of the library's Set-Aside Edits; and what it couldn't move or settle.
public struct SidecarMoveReport: Sendable {
    public let plan: SidecarMovePlan
    /// Nil for a dry run.
    public let outcome: SidecarMoveOutcome?

    public init(plan: SidecarMovePlan, outcome: SidecarMoveOutcome? = nil) {
        self.plan = plan
        self.outcome = outcome
    }

    /// Something wasn't moved or settled: a sidecar that couldn't be, or that turned up in both places as the move ran.
    public var failed: Bool {
        outcome.map { !$0.failed.isEmpty || !$0.conflicts.isEmpty } ?? false
    }

    /// The report a line at a time, each list of photos cut at `limit`.
    public func lines(limit: Int = 50) -> [String] {
        let destination = plan.destination
        let savedLast = Dictionary(plan.conflicts.map { ($0.photo, $0.kept) }) { first, _ in first }
        func listed(_ photos: [String], indent: String = "  ") -> [String] {
            var lines = photos.prefix(limit).map { photo in
                indent + photo + (savedLast[photo].map { " (saved last \(Self.photoPlace($0)))" } ?? "")
            }
            if photos.count > limit {
                lines.append("\(indent)and \(BenchResult.grouped(photos.count - limit)) more")
            }
            return lines
        }
        guard let outcome else {
            var lines = ["Would move \(Self.count(plan.items.count, "sidecar")) \(Self.destination(destination))"]
            if !plan.conflicts.isEmpty, let folder = plan.setAside?.deletingLastPathComponent() {
                lines.append("Would settle \(Self.count(plan.conflicts.count, "photo")) with a sidecar in both "
                    + "places: the copy saved last would be kept \(Self.place(destination)), and the other set aside "
                    + "in a folder of its own in \(folder.path)")
                lines += listed(plan.conflicts.map(\.photo))
            }
            return lines
        }
        var lines = ["Moved \(Self.count(outcome.moved, "sidecar")) \(Self.destination(destination))"]
        if outcome.gone > 0 {
            lines.append("  \(BenchResult.grouped(outcome.gone)) were gone before they could be moved")
        }
        if !outcome.settled.isEmpty, let folder = outcome.setAside {
            lines.append("Settled \(Self.count(outcome.settled.count, "photo")) with a sidecar in both places: the "
                + "copy saved last was kept \(Self.place(destination)), and the other set aside in \(folder.path)")
            lines += listed(outcome.settled)
        }
        if !outcome.conflicts.isEmpty {
            lines.append("  \(BenchResult.grouped(outcome.conflicts.count)) turned up in both places and were left as "
                + "they are:")
            lines += listed(outcome.conflicts, indent: "    ")
        }
        for (photo, message) in outcome.failed.sorted(by: { $0.key < $1.key }).prefix(limit) {
            lines.append(savedLast[photo] == nil
                ? "  couldn't move \(photo)'s sidecar: \(message)"
                : "  couldn't settle \(photo), both copies left where they were: \(message)")
        }
        return lines
    }

    /// The line saying what finishing a move a forced quit interrupted did.
    public static func resumed(_ outcome: SidecarMoveOutcome) -> String {
        var line = "Finished a move a forced quit interrupted: \(BenchResult.grouped(outcome.moved)) moved"
        if !outcome.settled.isEmpty, let folder = outcome.setAside {
            line += ", \(count(outcome.settled.count, "photo")) with a sidecar in both places settled, the other "
                + "copies set aside in \(folder.path)"
        }
        return line
    }

    /// The move as `--json` gives it.
    public struct Encoded: Encodable, Sendable {
        public struct Conflict: Encodable, Sendable {
            public let photo: String
            public let beside: String
            public let onThisMac: String
            /// Where the copy saved last is, the one the move keeps: `beside` or `mac`.
            public let kept: String
        }

        public let to: String
        public let dryRun: Bool
        public let planned: Int
        /// The photos with a sidecar in both places, which the move settles.
        public let conflicts: [Conflict]
        public let moved: Int?
        public let gone: Int?
        /// How many photos with a sidecar in both places the move settled.
        public let settled: Int?
        /// The folder the other copies of the photos it settled were set aside in.
        public let setAside: String?
        public let leftInBothPlaces: [String]?
        public let failed: [String: String]?
    }

    public var encoded: Encoded {
        Encoded(
            to: Self.name(plan.destination), dryRun: outcome == nil, planned: plan.items.count,
            conflicts: plan.conflicts.map { conflict in
                Encoded.Conflict(
                    photo: conflict.photo, beside: conflict.beside.path, onThisMac: conflict.onThisMac.path,
                    kept: Self.name(conflict.kept),
                )
            },
            moved: outcome?.moved, gone: outcome?.gone, settled: outcome?.settled.count,
            setAside: outcome?.setAside?.path, leftInBothPlaces: outcome?.conflicts, failed: outcome?.failed,
        )
    }

    // MARK: - Words

    /// Where a move takes sidecars, as the sentence saying so ends.
    static func destination(_ placement: RootRecord.Sidecars) -> String {
        switch placement {
        case .besidePhotos: "beside the photos"
        case .onThisMac: "to this Mac"
        }
    }

    /// Where photos' sidecars are kept.
    static func place(_ placement: RootRecord.Sidecars) -> String {
        switch placement {
        case .besidePhotos: "beside the photos"
        case .onThisMac: "on this Mac"
        }
    }

    /// Where one photo's sidecar is.
    static func photoPlace(_ placement: RootRecord.Sidecars) -> String {
        switch placement {
        case .besidePhotos: "beside it"
        case .onThisMac: "on this Mac"
        }
    }

    static func name(_ placement: RootRecord.Sidecars) -> String {
        switch placement {
        case .besidePhotos: "beside"
        case .onThisMac: "mac"
        }
    }

    static func count(_ value: Int, _ noun: String) -> String {
        "\(BenchResult.grouped(value)) \(noun)\(value == 1 ? "" : "s")"
    }
}
