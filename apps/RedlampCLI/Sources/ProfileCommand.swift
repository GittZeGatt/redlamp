import Foundation
import RedlampEngineAPI
import RedlampRecipes

/// `redlamp recipe profile`: fits film-slot Base Looks to cameras' own JPEGs.
///
/// Reads the pair manifests (research/profiler/fujifilm-pairs.json and review-pairs.json,
/// downloaded by the fetchers next to them; `--pairs a.json,b.json` picks others), fits
/// each slot, and writes the look as the slot's next version with a report and a comparison
/// sheet into build/profiler/out. `--install` also copies the look into the bundled resources.
///
/// `--evaluate a,b,…` fits nothing: it scores looks against the cameras' JPEGs instead, each
/// slot's against Redlamp Color and the bundled look (TON-45). Each item is a `.redrecipe`, a
/// recipe the library knows, a folder of them, or one of Fujifilm's LUTs, which is scored with
/// each output decoding and exposure offset the import could use.
enum ProfileCommand {
    struct Manifest: Decodable {
        struct Pair: Decodable {
            var slot: String
            var camera: String
            var file: String
        }

        /// Where the files are, relative to the checkout.
        var folder: String?
        var pairs: [Pair]
    }

    static let defaultManifests = [
        "research/profiler/fujifilm-pairs.json", "research/profiler/review-pairs.json",
        "research/profiler/manual-pairs.json",
    ]

    /// Slots need this many scenes before a fit is worth shipping.
    static let minimumScenes = 4

    static func run(_ context: RecipeCommands.Context) async throws {
        let arguments = context.arguments
        let paths = arguments.value("--pairs").map { $0.split(separator: ",").map(String.init) } ?? defaultManifests
        let available = try paths.flatMap { path -> [(Manifest.Pair, URL)] in
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : Repository.root.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
            let folder = Repository.root.appendingPathComponent(manifest.folder ?? "build/profiler/fujifilm")
            return manifest.pairs.map { ($0, folder.appendingPathComponent($0.file)) }
                .filter { FileManager.default.fileExists(atPath: $0.1.path) }
        }
        let output = Repository.root.appendingPathComponent("build/profiler/out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let wanted = arguments.value("--slots").map { Set($0.split(separator: ",").map(String.init)) }
        let profiler = try LookProfiler(renderer: context.renderer())
        if let items = arguments.value("--evaluate") {
            try await evaluate(
                items,
                available: available,
                wanted: wanted,
                profiler: profiler,
                context: context,
                output: output,
            )
            return
        }

        for slot in FilmSlot.allCases where wanted?.contains(slot.rawValue) ?? true {
            // Scenes are grouped by camera: cross-validation leaves out whole bodies, and each
            // body's exposure offset is removed as a unit. With one body, each photo is its own
            // group, so the reported error is still on photos the fit never saw.
            let matching = available.filter { $0.0.slot == slot.rawValue }
            let oneCamera = Set(matching.map(\.0.camera)).count == 1
            let pairs = matching.map { pair, url in
                LookProfiler.Pair(raw: url, scene: oneCamera ? "\(pair.camera) \(pair.file)" : pair.camera)
            }
            guard !pairs.isEmpty else { continue }
            print("\(slot.name) (\(slot.rawValue)): \(pairs.count) pairs")
            guard pairs.count >= minimumScenes else {
                print("  skipped: needs at least \(minimumScenes) scenes")
                continue
            }
            let previous = BuiltInBaseLooks.package(slot: slot.rawValue)
            let tools = try context.renderer()
            let report = try await profiler.profile(pairs, previous: previous?.definition().table, accept: { table in
                // Shipped looks must not band or invert tones.
                let candidate = LookTableImport.recipe(for: table, name: "candidate")
                let results = await (try? tools.lint(candidate)) ?? []
                return results.allSatisfy { result in
                    ![.banding, .monotonicLuminance].contains(result.check) || result.status == .pass
                }
            }, log: { print($0) })
            let version = (previous?.version ?? StarterPackLooks.version) + 1
            let package = BaseLookPackage(
                id: StarterPackLooks.id(for: slot), version: version, name: slot.name,
                summary: "\(slot.summary) Measured from \(report.scenes) cameras' own renderings.",
                slot: slot.rawValue, parameters: previous?.parameters ?? .identity, table: report.table,
            )
            let neutral = String(format: "%.2f", report.neutral.mean)
            let before = report.previous.map { String(format: "%.2f", $0.mean) } ?? "–"
            let fitted = String(format: "%.2f (p90 %.2f)", report.fitted.mean, report.fitted.p90)
            print(
                "  ΔE to the camera: Redlamp Color \(neutral), version \(version - 1) \(before), fitted \(fitted) held out",
            )

            let file = output.appendingPathComponent("base-\(slot.rawValue)@\(version).json")
            try RecipeFile.encoder.encode(package).write(to: file, options: .atomic)
            var recipe = LookTableImport.recipe(for: report.table, name: "\(slot.name) v\(version)")
            recipe.embeddedBaseLooks = [package]
            recipe.baseLook = package.reference
            let sheet = try await profiler.comparisonSheet(Array(pairs.prefix(6)), look: recipe)
            try ImageFile.write(sheet, to: output.appendingPathComponent("\(slot.rawValue)-sheet.jpg"))
            print("  wrote \(file.lastPathComponent) and \(slot.rawValue)-sheet.jpg")
            if arguments.has("--install") {
                let resources = Repository.root.appendingPathComponent("packages/RedlampRecipes/Resources/BaseLooks")
                try BuiltInBaseLooks.install(package, as: "base-\(slot.rawValue)@\(version)", in: resources)
                print("  installed into Resources/BaseLooks (regenerate the workspace to bundle it)")
            }
        }
    }

    // MARK: - Evaluating

    /// The processor generation a camera's film simulations come from.
    static func generation(_ camera: String) -> String {
        let model = camera.replacingOccurrences(of: "Fujifilm ", with: "").replacingOccurrences(of: " ", with: "")
            .uppercased()
        let five = [
            "X-T5", "X-H2", "X-H2S", "X-S20", "X100VI", "X-T50", "X-M5", "X-E5", "X-T30III", "GFX100II", "GFX100RF",
            "GFX100SII", "GFXETERNA55",
        ]
        let four = [
            "X-T3",
            "X-T4",
            "X-T30",
            "X-T30II",
            "X-PRO3",
            "X100V",
            "X-S10",
            "X-E4",
            "GFX100",
            "GFX100S",
            "GFX50SII",
        ]
        if five.contains(model) {
            return "X-Processor 5"
        }
        if four.contains(model) {
            return "X-Processor 4"
        }
        return "older"
    }

    /// Looks to score: each with the slot it's for, or nil for every slot.
    static func candidates(_ items: String, context: RecipeCommands.Context) throws -> [(
        slot: FilmSlot?,
        recipe: Recipe,
    )] {
        var candidates: [(slot: FilmSlot?, recipe: Recipe)] = []
        for item in items.split(separator: ",").map(String.init) {
            let url = URL(fileURLWithPath: item)
            var isFolder: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
            let files = isFolder.boolValue
                ? ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .filter { ["redrecipe", "cube"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.path < $1.path }
                : exists ? [url] : []
            if !exists {
                let recipe = try context.library.resolve(item)
                candidates.append((slot(of: recipe), recipe))
            }
            for file in files {
                guard let lut = FujifilmLUT.recognise(contentsOf: file) else {
                    let (recipe, _) = try RecipeFile.read(file)
                    candidates.append((slot(of: recipe), recipe))
                    continue
                }
                let text = try String(contentsOf: file, encoding: .utf8)
                for output in LookTableOutput.allCases {
                    for exposure: Float in [0, 0.5, 0.9, 1.3] {
                        let space = ImportedTableSpace.cameraLog(lut.curve, output: output, exposure: exposure)
                        let table = try LookTableImport.parseCube(text, space: space).table
                        let name = "\(FujifilmLUT.name(of: file)) \(output.rawValue) \(String(format: "%+.1f", exposure))"
                        candidates.append((lut.simulation?.slot, lut.recipe(for: table, name: name)))
                    }
                }
            }
        }
        return candidates
    }

    static func evaluate(
        _ items: String,
        available: [(Manifest.Pair, URL)],
        wanted: Set<String>?,
        profiler: LookProfiler,
        context: RecipeCommands.Context,
        output: URL,
    ) async throws {
        let candidates = try candidates(items, context: context)
        for candidate in candidates {
            profiler.renderer.prepare(candidate.recipe)
        }
        for slot in FilmSlot.allCases where wanted?.contains(slot.rawValue) ?? true {
            let matching = available.filter { $0.0.slot == slot.rawValue }
            let mine = candidates.filter { $0.slot == nil || $0.slot == slot }
            guard !matching.isEmpty, !mine.isEmpty else { continue }
            let pairs = matching.map { pair, url in
                LookProfiler.Pair(raw: url, scene: pair.camera, group: generation(pair.camera))
            }
            let bundled = Recipe(
                id: "local/evaluation-bundled", name: "Bundled \(slot.rawValue)", group: "", includes: [.baseLook],
                settings: RecipeSettings(), baseLook: slot.baseLook,
            )
            let looks: [(name: String, recipe: Recipe?)] = [("Redlamp Color", nil), (bundled.name, bundled)]
                + mine.map { ($0.recipe.name, $0.recipe) }
            print("\(slot.name) (\(slot.rawValue)): \(pairs.count) photos, \(looks.count) looks")
            let results = try await profiler.evaluate(pairs, looks: looks)
            for result in results.sorted(by: { $0.exposureMatched.oklabMean < $1.exposureMatched.oklabMean }) {
                let groups = result.byGroup.sorted { $0.key < $1.key }
                    .map { "\($0.key) \(String(format: "%.2f", $0.value.oklabMean))" }.joined(separator: ", ")
                let rendered = String(
                    format: "OKLab %.2f (p90 %.2f), ΔE2000 %.2f (p95 %.2f)",
                    result.rendered.oklabMean, result.rendered.oklabP90,
                    result.rendered.deltaE2000Mean, result.rendered.deltaE2000P95,
                )
                let matched = String(
                    format: "exposure matched %.2f / %.2f, median %+.2f EV",
                    result.exposureMatched.oklabMean, result.exposureMatched.deltaE2000Mean, result.medianExposure,
                )
                print("  \(result.name): \(rendered); \(matched); \(groups)")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let file = output.appendingPathComponent("evaluate-\(slot.rawValue).json")
            try encoder.encode(results).write(to: file, options: .atomic)
            print("  wrote \(file.lastPathComponent)")
        }
    }

    /// The slot a recipe's look fills, if it names one.
    static func slot(of recipe: Recipe) -> FilmSlot? {
        let look = recipe.embeddedBaseLooks.first { package in recipe.baseLook.map(package.matches) ?? false }
        return look?.slot.flatMap(FilmSlot.init(rawValue:))
    }
}
