import CoreGraphics
import Foundation
import ImageIO
import RedlampEngineAPI
import simd

/// What a slot's pairs say about the fit itself (TON-45): where the camera's colour for the
/// same input colour changes from scene to scene, which a single table can't follow, and
/// whether processor generation, the light or ISO changes the look.
public extension LookProfiler {
    /// Facts about a pair beyond its samples.
    struct PairFacts: Sendable {
        public var generation: String
        public var iso: Int?
        /// Warmer light than daylight: an as-shot white balance below 4,200 K, as Redlamp reads
        /// it; nil until the photo is opened.
        public var warmLight: Bool?

        public init(generation: String, iso: Int?, warmLight: Bool?) {
            self.generation = generation
            self.iso = iso
            self.warmLight = warmLight
        }
    }

    struct Diagnosis: Sendable, Codable {
        public struct Cell: Sendable, Codable {
            /// The cell's mean input colour, as OKLab lightness, chroma and hue in degrees.
            public var lightness: Double
            public var chroma: Double
            public var hue: Double
            /// How far each scene's mean camera colour sits from the cell's, OKLab × 100 (RMS).
            public var spread: Double
            public var scenes: Int
            public var samples: Int
        }

        public struct Split: Sendable, Codable {
            public var name: String
            /// Samples in each group.
            public var groups: [String: Int]
            /// Mean OKLab ΔE × 100 between tables fitted to each group alone, over every sample's colour.
            public var difference: Double
        }

        public var samples: Int
        /// Mean OKLab ΔE × 100 of the table fitted to every sample, on those samples.
        public var fitError: Double
        /// The share of that error's square in lightness rather than colour: near 1, what's
        /// left is tone, which a scene-referred fit (TON-46) could take on.
        public var lightnessShare: Double
        public var medianCellSpread: Double
        /// The share of samples, in cells seen in two or more scenes, whose cell spreads more
        /// than the fit's error.
        public var adaptiveShare: Double
        /// The cells that spread most.
        public var adaptiveCells: [Cell]
        public var splits: [Split]
    }

    func diagnose(
        _ pairs: [(pair: Pair, facts: PairFacts)],
        smoothness: Float = 10,
        log: (String) -> Void = { _ in },
    ) async throws -> Diagnosis {
        var byScene: [String: [ProfileSample]] = [:]
        var factsByScene: [String: PairFacts] = [:]
        for (pair, known) in pairs {
            var facts = known
            if facts.warmLight == nil, let white = try await renderer.open(pair.raw).asShotWhiteBalance {
                facts.warmLight = white.temperature < 4200
            }
            let (samples, _) = try await samples(for: pair)
            // Each photo is its own scene here, so a body's photos can differ.
            let scene = "\(pair.scene) \(pair.raw.lastPathComponent)"
            byScene[scene] = samples
            factsByScene[scene] = facts
            log("  \(pair.raw.lastPathComponent): \(samples.count) samples")
        }
        normalizeExposure(&byScene) { _ in }
        let all = byScene.values.flatMap(\.self)
        let table = LatticeFit.fit(all, size: 25, smoothness: smoothness)
        let fitError = LatticeFit.error(table, all).mean

        /// Residuals by cell and scene.
        func oklab(_ c: SIMD3<Float>) -> SIMD3<Float> {
            ColorMath.rec2020ToOKLab(ColorMath.srgbDecode(simd_max(c, .zero)))
        }
        var cells: [Int: [String: [(input: SIMD3<Float>, residual: SIMD3<Float>)]]] = [:]
        for (scene, samples) in byScene {
            for sample in samples {
                let cell = SIMD3<Int>(simd_clamp(sample.input * 12, .zero, SIMD3(repeating: 11.99)))
                let key = (cell.x * 12 + cell.y) * 12 + cell.z
                let residual = oklab(sample.target) - oklab(table.sample(sample.input))
                cells[key, default: [:]][scene, default: []].append((oklab(sample.input), residual))
            }
        }
        var lightness: Float = 0, total: Float = 0
        for scenes in cells.values {
            for residual in scenes.values.flatMap(\.self).map(\.residual) {
                lightness += residual.x * residual.x
                total += simd_length_squared(residual)
            }
        }
        var measured: [Diagnosis.Cell] = []
        var adaptive = 0, counted = 0
        for scenes in cells.values where scenes.count >= 2 {
            let samples = scenes.values.flatMap(\.self)
            guard samples.count >= 12 else { continue }
            let means = scenes.values.map { list in list.map(\.residual).reduce(.zero, +) / Float(list.count) }
            let centre = means.reduce(.zero, +) / Float(means.count)
            let spread = Double((means.map { simd_length_squared($0 - centre) }.reduce(0, +) / Float(means.count))
                .squareRoot()) * 100
            let input = samples.map(\.input).reduce(.zero, +) / Float(samples.count)
            measured.append(Diagnosis.Cell(
                lightness: Double(input.x),
                chroma: Double(simd_length(SIMD2(input.y, input.z))),
                hue: (Double(atan2(input.z, input.y)) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360),
                spread: spread,
                scenes: scenes.count,
                samples: samples.count,
            ))
            counted += samples.count
            if spread > fitError {
                adaptive += samples.count
            }
        }
        let spreads = measured.map(\.spread).sorted()

        /// Tables fitted to each group alone.
        func split(_ name: String, _ group: (PairFacts) -> String?) -> Diagnosis.Split? {
            var groups: [String: [ProfileSample]] = [:]
            for (scene, samples) in byScene {
                if let facts = factsByScene[scene], let key = group(facts) {
                    groups[key, default: []] += samples
                }
            }
            let sizable = groups.filter { $0.value.count >= 300 }
            guard sizable.count == 2 else { return nil }
            let keys = sizable.keys.sorted()
            let a = LatticeFit.fit(sizable[keys[0]]!, size: 25, smoothness: smoothness)
            let b = LatticeFit.fit(sizable[keys[1]]!, size: 25, smoothness: smoothness)
            let difference = all.map { sample in
                Double(simd_distance(oklab(a.sample(sample.input)), oklab(b.sample(sample.input)))) * 100
            }.reduce(0, +) / Double(max(all.count, 1))
            return Diagnosis.Split(name: name, groups: sizable.mapValues(\.count), difference: difference)
        }
        let splits = [
            split("Processor generation") { $0.generation == "older" ? nil : $0.generation },
            split("Light") { $0.warmLight.map { $0 ? "warm" : "daylight" } },
            split("ISO") { $0.iso.map { $0 <= 800 ? "800 and below" : "above 800" } },
        ].compactMap(\.self)

        return Diagnosis(
            samples: all.count,
            fitError: fitError,
            lightnessShare: total > 0 ? Double(lightness / total) : 0,
            medianCellSpread: spreads.isEmpty ? 0 : spreads[spreads.count / 2],
            adaptiveShare: counted == 0 ? 0 : Double(adaptive) / Double(counted),
            adaptiveCells: Array(measured.sorted { $0.spread > $1.spread }.prefix(8)),
            splits: splits,
        )
    }

    /// ISO from the camera JPEG's EXIF; the light is read when the photo is opened.
    static func facts(of url: URL, generation: String) -> PairFacts {
        var iso: Int?
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let header = try? handle.read(upToCount: 100), header.count >= 92,
               header.prefix(15) == Data("FUJIFILMCCD-RAW".utf8) {
                func word(_ offset: Int) -> UInt64 {
                    header[offset ..< offset + 4].reduce(0) { $0 << 8 | UInt64($1) }
                }
                try? handle.seek(toOffset: word(84))
                if let jpeg = try? handle.read(upToCount: Int(word(88))),
                   let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                   let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                   let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
                   let ratings = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int] {
                    iso = ratings.first
                }
            }
        }
        return PairFacts(generation: generation, iso: iso, warmLight: nil)
    }
}
