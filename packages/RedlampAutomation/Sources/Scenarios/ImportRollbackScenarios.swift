#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import CoreGraphics
    import ImageIO
    import RedlampLibrary
    @_spi(Harness) import RedlampUI
    import UniformTypeIdentifiers

    /// The import window's Roll Back and Resume (LIB-27), and a folder of large JPEGs browsed from their EXIF
    /// thumbnails, all from folders of the run's own: never a card, and never this Mac's volumes. What a rollback
    /// moves to the Trash, the scenario takes out of it.
    enum ImportRollbackScenarios {
        static let all: [Scenario] = [afterCancel, interrupted, resumed, jpegPreviews]

        static let afterCancel = Scenario(
            "import.roll-back",
            "Import Photos… cancelled partway is taken back with Roll Back: the copies it made go to the Trash, "
                + "Library no longer shows them, and the backup folder it made goes",
            claims: [.feature("library.import")],
        ) { app in
            try app.openWorking()
            let scratch = try ImportScratch(app, photos: 200)
            let imported = scratch.destination.appending(path: "Imported", directoryHint: .isDirectory)
            let trash = TrashedFiles()
            defer {
                trash.empty()
                try? app.main { model in ImportWindowController.forget(imported, in: model) }
                try? app.showRunPhotos()
                scratch.remove(app)
            }
            try app.openImportWindow(on: scratch)
            try app.clickInImportWindow("import.import")
            try app.wait("the copying", timeout: 120) { _ in ImportWindowController.current?.isCopying == true }
            try app.clickInImportWindow("import.cancel")
            try app.wait("the import to stop", timeout: 300) { _ in ImportWindowController.current?.isFinished == true }
            let stopped = try app.inImportWindow { $0.result?.verified ?? 0 }
            try app.expect(stopped > 0 && stopped < 200, "\(stopped) of 200 photos copied before Cancel")
            try app.wait("Library showing the photos copied", timeout: 60) { model in
                model.folder?.standardizedFileURL.path == imported.standardizedFileURL.path
                    && model.items.count == stopped
            }
            try app.expect(
                try app.inImportWindow { $0.canRollBack },
                "Roll Back is offered once the import is cancelled",
            )

            try app.clickInImportWindow("import.roll-back")
            try app.wait("the rollback", timeout: 120) { _ in
                ImportWindowController.current?.rollbackResult?.isOver == true
            }
            let result = try app.inImportWindow { $0.rollbackResult }
            trash.add(result?.trashed ?? [])
            try app.expect(result?.rolledBack == stopped, "\(result?.rolledBack ?? 0) of \(stopped) photos taken back")
            try app.expect(
                trash.files.count >= 2 * stopped && trash.files
                    .allSatisfy { FileManager.default.fileExists(atPath: $0) },
                "\(trash.files.count) files in the Trash",
            )
            let left = (try? FileManager.default.contentsOfDirectory(atPath: imported.path))?
                .filter { !$0.hasPrefix(".") } ?? []
            try app.expect(left.isEmpty, "the destination's folder holds \(left)")
            try app.expect(
                !FileManager.default.fileExists(atPath: scratch.backup.path),
                "the backup the import made went",
            )
            try app.wait("Library no longer showing them", timeout: 60) { model in model.items.isEmpty }
            let summary = try app.inImportWindow { $0.summary }
            try app.expect(summary.hasPrefix("Rolled back"), summary)
            app.covered(.feature("library.import"), via: .mouse)
        }

        static let interrupted = Scenario(
            "import.roll-back-interrupted",
            "An import a forced quit cut short is offered when Import Photos… opens again, and Roll Back takes it back: "
                + "its copies to the Trash and the folders it made gone",
            claims: [.feature("library.import")],
        ) { app in
            try app.openWorking()
            let scratch = try ImportScratch(app, photos: 6)
            let trash = TrashedFiles()
            defer {
                trash.empty()
                try? app.showRunPhotos()
                scratch.remove(app)
            }
            try app.cutShortImport(of: scratch)
            try app.clickInImportWindow("import.roll-back")
            try app.wait("the rollback, and nothing waiting to be resumed", timeout: 120) { _ in
                ImportWindowController.current.map { $0.rollbackResult?.isOver == true && !$0.isInterrupted } == true
            }
            let result = try app.inImportWindow { $0.rollbackResult }
            trash.add(result?.trashed ?? [])
            try app.expect((result?.rolledBack ?? 0) >= 2, "\(result?.rolledBack ?? 0) photos taken back")
            for folder in [scratch.destination, scratch.backup] {
                try app.expect(!FileManager.default.fileExists(atPath: folder.path), "\(folder.path) is still there")
            }
            app.covered(.feature("library.import"), via: .mouse)
        }

        static let resumed = Scenario(
            "import.resume",
            "An import a forced quit cut short is offered when Import Photos… opens again, and Resume finishes it and "
                + "shows its photos in Library, selected",
            claims: [.feature("library.import")],
        ) { app in
            try app.openWorking()
            let scratch = try ImportScratch(app, photos: 6)
            let imported = scratch.destination.appending(path: "Imported", directoryHint: .isDirectory)
            defer {
                try? app.main { model in ImportWindowController.forget(imported, in: model) }
                try? app.showRunPhotos()
                scratch.remove(app)
            }
            try app.cutShortImport(of: scratch)
            try app.clickInImportWindow("import.resume")
            try app.wait("the import finished", timeout: 120) { _ in
                ImportWindowController.current.map { $0.isFinished && !$0.isInterrupted } == true
            }
            let result = try app.inImportWindow { $0.result.map { "\($0.verified) \($0.safeToErase)" } }
            try app.expect(result == "6 true", "Resumed: \(result ?? "nothing")")
            try app.wait("Library showing the photos imported, selected", timeout: 60) { model in
                model.folder?.standardizedFileURL.path == imported.standardizedFileURL.path
                    && model.selectedPhotos.count == 6 && model.module == .library
            }
            app.covered(.feature("library.import"), via: .mouse)
        }

        static let jpegPreviews = Scenario(
            "import.jpeg-previews",
            "A folder of large camera JPEGs fills the import grid, from their EXIF thumbnails until their previews are "
                + "made, and every preview is made",
            claims: [.feature("library.import")],
        ) { app in
            try app.openWorking()
            let scratch = try ImportScratch(app, jpegs: 48)
            defer {
                try? app.showRunPhotos()
                scratch.remove(app)
            }
            try app.main { _ in ImportWindowController.ignoresVolumes = true }
            try app.choose(.importPhotos)
            try app.waitForImportWindow()
            try app.inImportWindow { window in
                window.prepare(
                    destination: scratch.destination, backup: nil, folders: "Imported", names: "{name}",
                )
            }
            let started = Date()
            app.post { _ in Task { try? await ImportWindowController.current?.add(folder: scratch.card) } }
            try app.wait("the first preview", timeout: 30) { _ in
                (ImportWindowController.current?.imagesShown ?? 0) > 0
            }
            let first = Date().timeIntervalSince(started) * 1000
            try app.wait("the folder browsed", timeout: 120) { _ in ImportWindowController.current?.isBrowsed == true }
            let (made, provisional) = try app.inImportWindow { $0.previewed }
            try app.expect(made == 48 && provisional == 0, "\(made) previews made, \(provisional) still provisional")
            // From a disk this fast a preview can be made before its EXIF thumbnail reaches the screen.
            let shown = try app.inImportWindow { ($0.imagesShown, $0.provisionalShown) }
            try? String(
                format: "import JPEGs: first preview %.0f ms; %d images on screen, %d of them EXIF thumbnails\n",
                first, shown.0, shown.1,
            ).write(to: app.runDirectory.appending(path: "import-jpeg-previews.txt"), atomically: true, encoding: .utf8)
            app.covered(.feature("library.import"), via: .model)
        }
    }

    /// Files a scenario moved to the Trash, which it takes out again.
    final class TrashedFiles: @unchecked Sendable {
        private(set) var files: [String] = []

        func add(_ paths: [String]) {
            files += paths
        }

        func empty() {
            for file in files {
                try? FileManager.default.removeItem(atPath: file)
            }
        }
    }

    extension ImportScratch {
        /// A folder of `jpegs` camera JPEGs of 4,500 by 3,000, about 3 MB each with the thumbnail in their EXIF,
        /// clones of two, each a byte longer than the one before so each has a content key of its own, and a
        /// destination below the run's folder.
        init(_ app: RunningApp, jpegs count: Int) throws {
            let base = app.runDirectory.appending(path: "import-\(UUID().uuidString)", directoryHint: .isDirectory)
            let folder = base.appending(path: "Card", directoryHint: .isDirectory)
            root = base
            card = folder
            destination = base.appending(path: "Pictures", directoryHint: .isDirectory)
            backup = base.appending(path: "Backup", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var originals: [URL] = []
            for number in 0 ..< 2 {
                let url = base.appending(path: "original-\(number).jpg")
                try Self.cameraJPEG(seed: number).write(to: url)
                originals.append(url)
            }
            var names: [String] = []
            for number in 0 ..< count {
                let name = String(format: "IMG_%04d.JPG", number)
                let file = folder.appending(path: name)
                try FileManager.default.copyItem(at: originals[number % 2], to: file)
                let handle = try FileHandle(forWritingTo: file)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(count: number + 1))
                try handle.close()
                names.append(name)
            }
            self.names = names
        }

        private static func cameraJPEG(seed: Int) throws -> Data {
            let (width, height, side) = (4500, 3000, 12)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
            ) else { throw ScenarioFailure("A JPEG couldn't be drawn") }
            var random = SeededRandom(seed: UInt64(seed))
            for y in stride(from: 0, to: height, by: side) {
                for x in stride(from: 0, to: width, by: side) {
                    let value = random.next()
                    context.setFillColor(
                        red: CGFloat(value & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                        blue: CGFloat(value >> 16 & 0xFF) / 255, alpha: 1,
                    )
                    context.fill(CGRect(x: x, y: y, width: side, height: side))
                }
            }
            let data = NSMutableData()
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
            else { throw ScenarioFailure("A JPEG couldn't be made") }
            let properties: [CFString: Any] = [
                kCGImageDestinationEmbedThumbnail: true, kCGImageDestinationLossyCompressionQuality: 0.9,
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:05 09:00:00"],
            ]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ScenarioFailure("A JPEG couldn't be written") }
            return data as Data
        }
    }

    extension RunningApp {
        /// Shows the run's photos in Develop again, as the run had them.
        func showRunPhotos() throws {
            let folder = photos
            try main { model in
                model.showFolder(folder)
                model.showModule(.develop)
            }
            try wait("the photos folder again", timeout: 30) { $0.folder == folder && !$0.library.isListing }
        }

        /// Opens the import window from the File menu, leaving this Mac's volumes alone, with `scratch`'s destination
        /// and backup, and its folder added and browsed.
        func openImportWindow(on scratch: ImportScratch) throws {
            try main { _ in ImportWindowController.ignoresVolumes = true }
            try choose(.importPhotos)
            try waitForImportWindow()
            try inImportWindow { window in
                window.prepare(
                    destination: scratch.destination, backup: scratch.backup, folders: "Imported", names: "{name}",
                )
            }
            try run("adding the folder") { _ in try? await ImportWindowController.current?.add(folder: scratch.card) }
            try wait("the folder browsed", timeout: 300) { _ in
                ImportWindowController.current.map { $0.isBrowsed && $0.photoCount == scratch.names.count } == true
            }
        }

        /// Imports `scratch`'s folder until a forced quit stops it after two photos, closes the window, and opens it
        /// again from the File menu, as the next launch would find it, offering the import.
        func cutShortImport(of scratch: ImportScratch) throws {
            try openImportWindow(on: scratch)
            try inImportWindow { $0.simulateForcedQuit(afterPhotos: 2) }
            try clickInImportWindow("import.import")
            try wait("the import cut short", timeout: 120) { _ in ImportWindowController.current?.isFinished == true }
            try main { _ in ImportWindowController.current?.window?.performClose(nil) }
            try wait("the window closed") { _ in ImportWindowController.current == nil }
            try choose(.importPhotos)
            try waitForImportWindow()
            try wait("the interrupted import offered") { _ in ImportWindowController.current?.isInterrupted == true }
        }
    }
#endif
