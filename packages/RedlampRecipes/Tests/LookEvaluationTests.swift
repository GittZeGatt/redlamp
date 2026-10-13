import RedlampEngineAPI
import simd
import Testing
@testable import RedlampRecipes

/// The evaluation's arithmetic (TON-45); its renders are the profiler's.
struct LookEvaluationTests {
    @Test func `the exposure offset is the stops between the midtones`() {
        let ours = (0 ..< 40).map { index in SIMD3(repeating: ColorMath.srgbEncode(0.05 + Float(index) * 0.005)) }
        let theirs = ours.map { SIMD3(repeating: ColorMath.srgbEncode(ColorMath.srgbDecode($0.x) * 2)) }
        #expect(abs(LookProfiler.exposureOffset(ours, theirs) - 1) < 1e-3)
        #expect(LookProfiler.exposureOffset(Array(ours.prefix(10)), Array(theirs.prefix(10))) == 0)
    }

    @Test func `the same colour scores nothing, and errors average and rank`() {
        let grey = SIMD3<Float>(repeating: 0.5)
        let same = LookProfiler.errors(grey, grey)
        #expect(same.0 == 0 && same.1 == 0)
        let score = LookProfiler.score([(1, 2), (3, 4), (5, 6)])
        #expect(score.oklabMean == 3 && score.deltaE2000Mean == 4 && score.samples == 3)
        #expect(score.oklabP90 == 5 && score.deltaE2000P95 == 6)
    }
}
