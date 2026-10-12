import CoreGraphics
import Foundation
import Metal
import simd

/// Golden renders: every bundled recipe on the lint chart, recorded once per process
/// version and never regenerated, so no engine change can silently alter a shipped look.
///
/// Each GPU that runs the tests has a set recorded on it. Another GPU computes some values a hair
/// differently, so a value near a rounding boundary lands on the next level (on the M4 Max, in 2 to
/// 12% of a render's pixels), and near black one level is more than the max allows.
public enum GoldenRender {
    /// Renders are this wide (the chart's aspect), small enough to commit.
    public static let width = 256

    /// The GPU whose set sits in each process version's folder itself; any other's is in a folder
    /// named for it.
    public static let referenceGPU = "Apple M1 Ultra"

    /// The GPU renders run on, as Metal names it ("Apple M4 Max").
    public static let gpu = MTLCreateSystemDefaultDevice()?.name ?? "no GPU"

    public struct Comparison: Sendable {
        public var meanDeltaE: Double
        public var maxDeltaE: Double

        /// Mean under 0.6 and max under 4 (OKLab ΔE × 100).
        public var passes: Bool {
            meanDeltaE < 0.6 && maxDeltaE < 4
        }
    }

    /// `gpu`'s golden renders for a process version: `process-15` for the M1 Ultra's,
    /// `process-15/apple-m4-max` for the M4 Max's.
    public static func directory(root: URL, processVersion: Int, gpu: String) -> URL {
        let folder = root.appendingPathComponent("tests/golden/recipes/process-\(processVersion)", isDirectory: true)
        guard gpu != referenceGPU else { return folder }
        return folder.appendingPathComponent(
            gpu.lowercased().replacingOccurrences(of: " ", with: "-"),
            isDirectory: true,
        )
    }

    public static func fileName(for recipe: Recipe) -> String {
        recipe.id.replacingOccurrences(of: "/", with: "~") + "@\(recipe.version).png"
    }

    public static func render(_ recipe: Recipe, with renderer: RecipeRenderer) async throws -> CGImage {
        renderer.prepare(recipe)
        return try await renderer.render(
            edit: recipe.edit(),
            image: RecipeChart.fileURL(),
            maxLongEdge: width,
            sixteenBit: false,
        )
    }

    public static func compare(_ a: CGImage, _ b: CGImage) -> Comparison? {
        guard a.width == b.width, a.height == b.height,
              let pa = PixelImage(a), let pb = PixelImage(b) else { return nil }
        var sum = 0.0, worst = 0.0
        for (x, y) in zip(pa.pixels, pb.pixels) {
            let d = Double(simd_distance(ColorMath.encodedSRGBToOKLab(x), ColorMath.encodedSRGBToOKLab(y))) * 100
            sum += d
            worst = max(worst, d)
        }
        return Comparison(meanDeltaE: sum / Double(pa.pixels.count), maxDeltaE: worst)
    }
}
