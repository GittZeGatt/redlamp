import Foundation
import RedlampLibrary

extension LibraryCommand {
    /// `redlamp library import`: copies a card's or a folder's photos (LIB-27) to a destination, and to
    /// a backup when one is given, in folders and with names from naming templates, each photo verified
    /// at both before its card counts as safe to erase. Photos the index at `--index` has already, and
    /// those already in their folders at the destination, are left; the destination is added to the
    /// index. Without `--index` the import is journaled in the app's library folder and nothing is
    /// indexed. `--dry-run` prints the plan and copies nothing; an import a forced quit interrupted is
    /// finished first, and so is a rollback. Exits 1 when a photo wasn't copied and verified.
    ///
    /// `--list` prints the imports the journal keeps, newest first, with their IDs; `--roll-back <ID>` (or
    /// `last`) rolls one back: its copies to the Trash, its photos out of the index, the folders it made
    /// removed, exiting 1 when it left a photo where it was copied to.
    static func importing(_ arguments: [String]) async throws {
        let options = try Arguments(
            arguments, valued: ["--to", "--backup", "--folders", "--names", "--keywords", "--index", "--roll-back"],
        )
        if options.has("--list") || options.value("--roll-back") != nil {
            return try await importJournal(options)
        }
        guard options.positional.count == 1, let destination = options.value("--to") else {
            throw CLIError(description: "import needs a card or a folder and --to\n\n\(usage)")
        }
        let folder = URL(fileURLWithPath: options.positional[0], isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CLIError(description: "no card or folder at \(folder.path)")
        }
        let settings = try ImportSettings(
            destination: URL(fileURLWithPath: destination, isDirectory: true).standardizedFileURL,
            backup: options.value("--backup").map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL },
            folders: template(options.value("--folders"), or: ImportSettings.standardFolders),
            names: template(options.value("--names"), or: ImportSettings.standardNames),
            rawOnly: options.has("--raw-only"),
            metadata: ImportMetadata(keywords: options.values("--keywords").flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespaces) }),
        )
        let source = try ImportSource.at(folder)
        let index = try await openIndex(options)
        let library = index.map { ImportLibrary.around($0) } ?? ImportLibrary(paths: .standard)
        let result = await Result {
            let finished = options.has("--dry-run") ? [] : try await finishRollbacks(library)
            let (report, recovered) = try await ImportReport.importing(
                [source],
                settings: settings,
                library: library,
                dryRun: options.has("--dry-run"),
            )
            return (report, recovered, finished)
        }
        library.store?.close()
        await index?.close()
        let (report, recovered, finished) = try result.get()
        for rollback in finished {
            let line = "Finished rolling back an import a forced quit interrupted: \(rollback.rolledBack.count) of "
                + "\(rollback.photos) photos taken back\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        for outcome in recovered {
            FileHandle.standardError.write(Data(
                "Finished an import a forced quit interrupted: \(outcome.verified) of \(outcome.photos) photos verified\n"
                    .utf8,
            ))
        }
        if options.has("--json") {
            try print(String(decoding: report.json(), as: UTF8.self))
        } else {
            for line in report.lines() {
                print(line)
            }
        }
        if let outcome = report.outcome, !outcome.failures.isEmpty || outcome.state != ImportJournal.State.finished {
            throw ExitCode(1)
        }
    }

    /// Finishes the rollbacks a forced quit interrupted, which no import runs before.
    private static func finishRollbacks(_ library: ImportLibrary) async throws -> [ImportRollback] {
        let importer = Importer(library: library)
        var finished: [ImportRollback] = []
        for entry in try await importer.unfinishedEntries() where entry.state == .rollingBack {
            try await finished.append(importer.rollBack(entry.id))
        }
        return finished
    }

    /// `--list` and `--roll-back`.
    private static func importJournal(_ options: Arguments) async throws {
        let index = try await openIndex(options)
        let library = index.map { ImportLibrary.around($0) } ?? ImportLibrary(paths: .standard)
        let importer = Importer(library: library)
        let result = await Result { () async throws -> (lines: [String], json: Data, rollback: ImportRollback?) in
            let entries = try await importer.entries()
            guard let wanted = options.value("--roll-back") else {
                let listed = entries.reversed().map(ImportListing.init)
                return try (listed.map(\.line), ImportListing.encoder.encode(listed), nil)
            }
            let entry = wanted == "last" ? entries.last : entries.first { $0.id.uuidString == wanted.uppercased() }
            guard let entry else {
                throw CLIError(description: wanted == "last" ? "the journal keeps no import"
                    : "the journal keeps no import \(wanted): --list names those it keeps")
            }
            let rollback = try await importer.rollBack(entry.id)
            let report = ImportRollbackReport(entry: entry, rollback: rollback)
            return try (report.lines, ImportListing.encoder.encode(report), rollback)
        }
        library.store?.close()
        await index?.close()
        let (lines, json, rollback) = try result.get()
        if options.has("--json") {
            print(String(decoding: json, as: UTF8.self))
        } else {
            for line in lines {
                print(line)
            }
        }
        if let rollback, rollback.state != .rolledBack || !rollback.left.isEmpty {
            throw ExitCode(1)
        }
    }

    private static func openIndex(_ options: Arguments) async throws -> LibraryIndex? {
        guard let path = options.value("--index") else { return nil }
        return try await LibraryIndex.open(at: URL(fileURLWithPath: path))
    }

    /// The template `text` writes, or `standard` without one; an error points at what's wrong in it.
    private static func template(_ text: String?, or standard: NamingTemplate) throws -> NamingTemplate {
        guard let text else { return standard }
        do {
            return try NamingTemplate(parsing: text)
        } catch {
            let marks = String(repeating: " ", count: error.range.lowerBound)
                + String(repeating: "^", count: max(error.range.count, 1))
            throw CLIError(description: "\(text)\n\(marks)\n\(error.message)")
        }
    }
}

/// An import as `--list` prints it.
private struct ImportListing: Encodable {
    let id: String
    let title: String
    let created: Date
    let state: String
    let photos: Int
    let done: Int
    let failed: Int
    let rolledBack: Int

    init(_ entry: ImportJournal.Entry) {
        id = entry.id.uuidString
        title = entry.title
        created = entry.created
        state = Self.words(entry.state)
        photos = entry.photos
        done = entry.done
        failed = entry.failed
        rolledBack = entry.rolledBack
    }

    var line: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let date = formatter.string(from: created)
        var counts = "\(done) of \(photos) photos in place"
        if failed > 0 {
            counts += ", \(failed) not copied"
        }
        if rolledBack > 0 {
            counts += ", \(rolledBack) taken back"
        }
        return "\(id)  \(date)  \(title): \(state), \(counts)"
    }

    static func words(_ state: ImportJournal.State) -> String {
        switch state {
        case .planned: "interrupted before it copied anything"
        case .running: "interrupted"
        case .finished: "finished"
        case .stopped: "cancelled"
        case .rollingBack: "interrupted while it was rolled back"
        case .rolledBack: "rolled back"
        }
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

/// What `--roll-back` prints.
private struct ImportRollbackReport: Encodable {
    struct Left: Encodable {
        let path: String
        let message: String
    }

    let id: String
    let title: String
    let state: String
    let photos: Int
    let rolledBack: Int
    let trashed: [String]
    let removedFromIndex: Int
    let removedFolders: [String]
    let left: [Left]
    let seconds: Double

    init(entry: ImportJournal.Entry, rollback: ImportRollback) {
        id = entry.id.uuidString
        title = entry.title
        state = ImportListing.words(rollback.state)
        photos = rollback.photos
        rolledBack = rollback.rolledBack.count
        trashed = rollback.trashed.map(\.to)
        removedFromIndex = rollback.removed
        removedFolders = rollback.removedFolders
        left = rollback.left.map { Left(path: $0.path, message: $0.message) }
        seconds = Double(rollback.elapsed.components.seconds) + Double(rollback.elapsed.components.attoseconds) / 1e18
    }

    var lines: [String] {
        var lines = ["\(title): \(state). \(rolledBack) of \(photos) photos taken back: \(trashed.count) files moved "
            + "to the Trash, \(removedFromIndex) photos taken out of the index, \(removedFolders.count) empty folders "
            + "removed, in " + String(format: "%.1f s.", seconds)]
        for folder in removedFolders {
            lines.append("Removed \(folder)")
        }
        for photo in left {
            lines.append("\(photo.path): left where it was copied to: \(photo.message)")
        }
        return lines
    }
}

private extension Result where Failure == any Error {
    init(_ body: () async throws -> Success) async {
        do {
            self = try await .success(body())
        } catch {
            self = .failure(error)
        }
    }
}
