import CoreGraphics
import Foundation
import RedlampColor
import RedlampEngineAPI
import simd

/// Finished looks scored against cameras' own JPEGs (TON-45): an imported LUT, a measured
/// look, a hand-designed one or none, each rendered as the app renders it and compared with
/// the camera's JPEG on the same points of each photo.
public extension LookProfiler {
    /// Errors over every sample: OKLab ΔE × 100, the profiler's own measure, and CIEDE2000.
    struct Score: Sendable, Codable {
        public var oklabMean: Double
        public var oklabP90: Double
        public var deltaE2000Mean: Double
        public var deltaE2000P95: Double
        public var samples: Int
    }

    struct Evaluation: Sendable, Codable {
        public var name: String
        /// As rendered.
        public var rendered: Score
        /// With each photo's exposure raised or lowered to match the camera's midtones, as a
        /// user would with the Exposure slider.
        public var exposureMatched: Score
        /// As rendered, by each pair's `group`.
        public var byGroup: [String: Score]
        /// The exposure each photo needed, in stops: the median over the photos.
        public var medianExposure: Double
    }

    /// Scores each look on `pairs`. A nil recipe is Redlamp Color.
    func evaluate(
        _ pairs: [Pair],
        looks: [(name: String, recipe: Recipe?)],
        log: (String) -> Void = { _ in },
    ) async throws -> [Evaluation] {
        var rendered = [[(Double, Double)]](repeating: [], count: looks.count)
        var matched = [[(Double, Double)]](repeating: [], count: looks.count)
        var grouped = [[String: [(Double, Double)]]](repeating: [:], count: looks.count)
        var exposures = [[Double]](repeating: [], count: looks.count)
        for pair in pairs {
            let points = try await points(for: pair)
            guard !points.isEmpty else { continue }
            for (index, look) in looks.enumerated() {
                let first = try await values(of: look.recipe, exposure: 0, on: pair.raw, at: points)
                let errors = zip(first, points).map { Self.errors($0, $1.target) }
                rendered[index] += errors
                grouped[index][pair.group, default: []] += errors
                let stops = Self.exposureOffset(first, points.map(\.target))
                exposures[index].append(stops)
                let second = abs(stops) < 0.02 ? first
                    : try await values(of: look.recipe, exposure: stops, on: pair.raw, at: points)
                matched[index] += zip(second, points).map { Self.errors($0, $1.target) }
            }
            log("  \(pair.raw.lastPathComponent): \(points.count) points")
        }
        return looks.indices.map { index in
            let sorted = exposures[index].sorted()
            return Evaluation(
                name: looks[index].name,
                rendered: Self.score(rendered[index]),
                exposureMatched: Self.score(matched[index]),
                byGroup: grouped[index].mapValues(Self.score),
                medianExposure: sorted.isEmpty ? 0 : sorted[sorted.count / 2],
            )
        }
    }

    /// Points of a photo where the neutral render and the camera's JPEG are both flat and
    /// unclipped, away from the corners, capped per colour cell as the fit's samples are.
    private func points(for pair: Pair) async throws -> [(x: Int, y: Int, target: SIMD3<Float>)] {
        let neutral = try await renderer.render(nil, image: pair.raw, maxLongEdge: Self.analysisSize, sixteenBit: true)
        let camera = try CameraJPEG.extract(from: pair.raw, maxLongEdge: Self.analysisSize)
        guard let ours = PixelImage(neutral),
              let theirs = PixelImage(camera) else { throw CameraJPEG.Failure.unreadable }
        let alignment = Self.align(ours, theirs)
        let a = Self.blur(ours), b = Self.blur(theirs)
        var bins: [Int: Int] = [:]
        var points: [(x: Int, y: Int, target: SIMD3<Float>)] = []
        for y in stride(from: Int(Float(a.height) * 0.12), to: Int(Float(a.height) * 0.88), by: 2) {
            for x in stride(from: Int(Float(a.width) * 0.12), to: Int(Float(a.width) * 0.88), by: 2) {
                let input = a[x, y]
                guard input.max() < 0.97, input.min() > 0.015 else { continue }
                let gradient = simd_length(a[min(x + 2, a.width - 1), y] - a[max(x - 2, 0), y])
                    + simd_length(a[x, min(y + 2, a.height - 1)] - a[x, max(y - 2, 0)])
                guard gradient < 0.06 else { continue }
                let u = (Float(x) + 0.5) / Float(a.width), v = (Float(y) + 0.5) / Float(a.height)
                let cu = (u - 0.5) * alignment.scale + 0.5 + alignment.offset.x
                let cv = (v - 0.5) * alignment.scale + 0.5 + alignment.offset.y
                guard (0.02 ... 0.98).contains(cu), (0.02 ... 0.98).contains(cv) else { continue }
                let target = Self.bilinear(b, cu * Float(b.width) - 0.5, cv * Float(b.height) - 0.5)
                guard target.max() < 0.97, target.min() > 0.015 else { continue }
                let cell = SIMD3<Int>(simd_clamp(input * 12, .zero, SIMD3(repeating: 11.99)))
                let key = (cell.x * 12 + cell.y) * 12 + cell.z
                guard bins[key, default: 0] < 24 else { continue }
                bins[key, default: 0] += 1
                points.append((x, y, Self.toWorking(target)))
            }
        }
        return points
    }

    /// A look's render of a photo at the points, in Redlamp's table space, with `exposure`
    /// stops added to its Exposure.
    private func values(
        of recipe: Recipe?,
        exposure: Double,
        on image: URL,
        at points: [(x: Int, y: Int, target: SIMD3<Float>)],
    ) async throws -> [SIMD3<Float>] {
        var look = recipe ?? Recipe(
            id: "local/evaluation-neutral",
            name: "Redlamp Color",
            group: "",
            includes: [],
            settings: RecipeSettings(),
        )
        if exposure != 0 {
            look.includes.insert(.tone)
            look.settings.values[.exposure] = (look.settings.values[.exposure] ?? 0) + exposure
        }
        let render = try await renderer.render(look, image: image, maxLongEdge: Self.analysisSize, sixteenBit: true)
        guard let pixels = PixelImage(render) else { throw CameraJPEG.Failure.unreadable }
        let blurred = Self.blur(pixels)
        return points.map { Self.toWorking(blurred[min($0.x, blurred.width - 1), min($0.y, blurred.height - 1)]) }
    }

    /// The stops that bring a render's midtones to the camera's: the median luminance ratio
    /// over points between about a quarter and three quarters of white.
    static func exposureOffset(_ ours: [SIMD3<Float>], _ theirs: [SIMD3<Float>]) -> Double {
        var ratios: [Float] = []
        for (a, b) in zip(ours, theirs) {
            let la = simd_dot(ColorMath.srgbDecode(simd_max(a, .zero)), ColorMath.rec2020Luma)
            let lb = simd_dot(ColorMath.srgbDecode(simd_max(b, .zero)), ColorMath.rec2020Luma)
            if (0.05 ... 0.5).contains(lb), la > 0.01 {
                ratios.append(lb / la)
            }
        }
        guard ratios.count > 20 else { return 0 }
        ratios.sort()
        return Double(log2(ratios[ratios.count / 2]))
    }

    /// OKLab ΔE × 100 and CIEDE2000 between two colours in Redlamp's table space.
    static func errors(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> (Double, Double) {
        let la = ColorMath.srgbDecode(simd_max(a, .zero)), lb = ColorMath.srgbDecode(simd_max(b, .zero))
        let oklab = Double(simd_distance(ColorMath.rec2020ToOKLab(la), ColorMath.rec2020ToOKLab(lb))) * 100
        let labA = CIELab.fromLinearSRGB(SIMD3<Double>(ColorMath.rec2020ToRec709 * la))
        let labB = CIELab.fromLinearSRGB(SIMD3<Double>(ColorMath.rec2020ToRec709 * lb))
        return (oklab, CIELab.deltaE2000(labA, labB))
    }

    static func score(_ errors: [(Double, Double)]) -> Score {
        guard !errors.isEmpty else { return Score(
            oklabMean: 0,
            oklabP90: 0,
            deltaE2000Mean: 0,
            deltaE2000P95: 0,
            samples: 0,
        ) }
        let ok = errors.map(\.0).sorted(), de = errors.map(\.1).sorted()
        return Score(
            oklabMean: ok.reduce(0, +) / Double(ok.count),
            oklabP90: ok[min(ok.count - 1, ok.count * 9 / 10)],
            deltaE2000Mean: de.reduce(0, +) / Double(de.count),
            deltaE2000P95: de[min(de.count - 1, de.count * 19 / 20)],
            samples: errors.count,
        )
    }
}
