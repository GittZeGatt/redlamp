import Foundation
import RedlampLibrary
import Synchronization

extension LibraryCommand {
    /// `redlamp library sidecars`: where a root keeps its sidecars and how many it has in each
    /// place (LIB-11, LIB-12), and moving them between beside the photos and this Mac, a photo with a
    /// sidecar in both places settled as the move runs (DEC-63). A move a forced quit interrupted is
    /// finished first.
    static func sidecars(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index", "--move"])
        guard options.positional.count == 1, let path = options.value("--index") else {
            throw CLIError(description: "sidecars needs a root and --index\n\n\(usage)")
        }
        let destination: RootRecord.Sidecars? = try options.value("--move").map { name in
            switch name {
            case "beside": .besidePhotos
            case "mac": .onThisMac
            default: throw CLIError(description: "--move takes beside or mac, not \(name)")
            }
        }
        let dryRun = options.has("--dry-run")
        if dryRun, destination == nil {
            throw CLIError(description: "--dry-run goes with --move")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError(description: "no index at \(url.path) (make one with redlamp library index)")
        }
        var rootPath = URL(fileURLWithPath: options.positional[0], isDirectory: true).standardizedFileURL.path
        if rootPath.count > 1, rootPath.hasSuffix("/") {
            rootPath.removeLast()
        }
        let index = try await LibraryIndex.open(at: url)
        let library = LibrarySidecars(index: index)
        let roots = try await index.read { try $0.roots() }
        guard let root = roots.first(where: { $0.path == rootPath }) else {
            await index.close()
            let known = roots.isEmpty ? "none" : roots.map(\.path).joined(separator: ", ")
            throw CLIError(description: "\(rootPath) isn't a root of the library at \(url.path) (roots: \(known))")
        }

        var lines: [String] = []
        var failed = false
        let resumed = try await library.resumeMove()
        if let resumed {
            lines.append(SidecarMoveReport.resumed(resumed))
            failed = !resumed.failed.isEmpty
        }
        var report: SidecarMoveReport?
        if let destination {
            let plan = try await library.planMove(ofRoot: root.id, to: destination)
            if dryRun {
                report = SidecarMoveReport(plan: plan)
            } else {
                let reported = Mutex(ContinuousClock.now)
                let moved = try await library.move(plan, progress: { progress in
                    let (done, total) = (progress.done, progress.total)
                    let due = reported.withLock { last in
                        guard ContinuousClock.now - last >= .seconds(1) || done == total else { return false }
                        last = .now
                        return true
                    }
                    if due {
                        FileHandle.standardError.write(Data("  \(count(done)) of \(count(total))\n".utf8))
                    }
                })
                report = SidecarMoveReport(plan: plan, outcome: moved)
            }
            failed = failed || report?.failed == true
            lines += report?.lines() ?? []
        }
        let census = try await library.census(ofRoot: root.id)
        await index.close()

        if options.has("--json") {
            struct Output: Encodable {
                let root: String
                let sidecars: String
                let beside: Int
                let onThisMac: Int
                let both: Int
                let otherApps: Int
                let resumedMoved: Int?
                let resumedSettled: Int?
                let resumedSetAside: String?
                let move: SidecarMoveReport.Encoded?
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let output = Output(
                root: census.root, sidecars: placementName(census.placement), beside: census.beside,
                onThisMac: census.onThisMac, both: census.both, otherApps: census.otherApps,
                resumedMoved: resumed?.moved, resumedSettled: resumed?.settled.count,
                resumedSetAside: resumed?.setAside?.path, move: report?.encoded,
            )
            try print(String(decoding: encoder.encode(output), as: UTF8.self))
        } else {
            lines.insert(contentsOf: [
                "\(census.root): sidecars \(placementDescription(census.placement))",
                "  \(count(census.beside)) beside the photos, \(count(census.onThisMac)) on this Mac, "
                    +
                    "\(count(census.both)) in both places; \(count(census.otherApps)) other apps' .xmp beside the photos",
            ], at: 0)
            print(lines.joined(separator: "\n"))
        }
        if failed {
            throw ExitCode(1)
        }
    }

    /// `20,000`, whatever the locale.
    private static func count(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }
}
