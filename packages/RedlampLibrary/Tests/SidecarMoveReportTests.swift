import Foundation
import Testing
@testable import RedlampLibrary

/// What `redlamp library sidecars --move` says (LIB-11, DEC-63): a move with photos whose sidecar is in both places
/// goes through, settling them, and says how many it settled and the folder their other copies were set aside in, in
/// its lines and its JSON; a dry run says which it would settle, saved last where, moving nothing; and a photo it
/// couldn't settle is named and fails the command.
struct SidecarMoveReportTests {
    /// IMG_0002 saved later on this Mac than beside it, IMG_0003 earlier: a library of six photos, each with a sidecar
    /// beside it, two of them with another on this Mac.
    static func library() async throws -> (sandbox: KeywordSandbox, sidecars: LibrarySidecars, root: Int64) {
        let (sandbox, sidecars, root) = try await SidecarSettleTests.library()
        let (newer, older) = (SidecarSettleTests.names[1], SidecarSettleTests.names[2])
        try await SidecarSettleTests.save(rating: 5, age: 0, for: newer, in: .onThisMac, sandbox, sidecars, root: root)
        try await SidecarSettleTests.save(
            rating: 1,
            age: 7200,
            for: older,
            in: .onThisMac,
            sandbox,
            sidecars,
            root: root,
        )
        return (sandbox, sidecars, root)
    }

    /// The report's JSON, as a dictionary.
    static func json(_ report: SidecarMoveReport) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report.encoded)) as? [String: Any])
    }

    @Test func `a move settles the photos with a sidecar in both places and says how many and where the other copies are`(
    ) async throws {
        let (sandbox, sidecars, root) = try await Self.library()
        defer { sandbox.remove() }
        let plan = try await sidecars.planMove(ofRoot: root, to: .onThisMac)
        try #require(plan.conflicts.count == 2)
        let report = try await SidecarMoveReport(plan: plan, outcome: sidecars.move(plan))
        let folder = try #require(plan.setAside)

        #expect(!report.failed)
        #expect(report.lines() == [
            "Moved 5 sidecars to this Mac",
            "Settled 2 photos with a sidecar in both places: the copy saved last was kept on this Mac, and the other "
                + "set aside in \(folder.path)",
            "  IMG_0002.JPG (saved last on this Mac)",
            "  IMG_0003.JPG (saved last beside it)",
        ])
        let json = try Self.json(report)
        #expect(json["settled"] as? Int == 2 && json["setAside"] as? String == folder.path)
        #expect(json["moved"] as? Int == 5 && json["dryRun"] as? Bool == false && json["to"] as? String == "mac")
        let conflicts = try #require(json["conflicts"] as? [[String: Any]])
        #expect(conflicts.map { $0["kept"] as? String } == ["mac", "beside"])
        for name in ["IMG_0002.JPG", "IMG_0003.JPG"] {
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: name + ".redlamp").path))
        }
        #expect(try await sidecars.census(ofRoot: root).both == 0)
    }

    @Test func `a dry run says which photos it would settle, and where, and moves nothing`() async throws {
        let (sandbox, sidecars, root) = try await Self.library()
        defer { sandbox.remove() }
        let plan = try await sidecars.planMove(ofRoot: root, to: .onThisMac)
        let report = SidecarMoveReport(plan: plan)

        #expect(!report.failed)
        #expect(report.lines() == [
            "Would move 4 sidecars to this Mac",
            "Would settle 2 photos with a sidecar in both places: the copy saved last would be kept on this Mac, and "
                + "the other set aside in a folder of its own in \(sidecars.paths.setAsideEdits.path)",
            "  IMG_0002.JPG (saved last on this Mac)",
            "  IMG_0003.JPG (saved last beside it)",
        ])
        let json = try Self.json(report)
        #expect(json["dryRun"] as? Bool == true && json["planned"] as? Int == 4)
        #expect(json["settled"] == nil && json["setAside"] == nil)
        #expect((json["conflicts"] as? [[String: Any]])?.count == 2)
        #expect(!FileManager.default.fileExists(atPath: sidecars.paths.setAsideEdits.path))
        #expect(try await sidecars.census(ofRoot: root).both == 2)
    }

    @Test func `a photo whose other copy can't be set aside is named, both copies left, and fails the command`(
    ) async throws {
        let (sandbox, sidecars, root) = try await Self.library()
        defer { sandbox.remove() }
        let plan = try await sidecars.planMove(ofRoot: root, to: .onThisMac)
        let folder = try #require(plan.setAside)
        let blocked = folder.appending(path: "IMG_0002.JPG.redlamp", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("another".utf8).write(to: blocked)
        let report = try await SidecarMoveReport(plan: plan, outcome: sidecars.move(plan))

        #expect(report.failed)
        #expect(report.lines().contains(
            "  couldn't settle IMG_0002.JPG, both copies left where they were: a copy is already where it would be "
                + "set aside",
        ))
        #expect(report.lines().contains("  IMG_0003.JPG (saved last beside it)"))
        #expect(try Self.json(report)["settled"] as? Int == 1)
        #expect(try await sidecars.census(ofRoot: root).both == 1)
    }

    @Test func `finishing a move a quit interrupted says what it settled, and where`() {
        var outcome = SidecarMoveOutcome()
        outcome.moved = 1204
        #expect(SidecarMoveReport.resumed(outcome) == "Finished a move a forced quit interrupted: 1,204 moved")
        outcome.settled = ["IMG_0002.JPG"]
        outcome.setAside = URL(fileURLWithPath: "/Library/Set-Aside Edits/2026-10-11 09.05.07 DCIM", isDirectory: true)
        #expect(SidecarMoveReport.resumed(outcome) == "Finished a move a forced quit interrupted: 1,204 moved, 1 photo "
            + "with a sidecar in both places settled, the other copies set aside in /Library/Set-Aside Edits/"
            + "2026-10-11 09.05.07 DCIM")
    }
}
