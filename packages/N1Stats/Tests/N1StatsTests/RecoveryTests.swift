import XCTest
@testable import N1Stats

/// The three validation red lines of whitepaper §3.6:
/// 1. Recovery: a known δ can be estimated without bias, with normal 90% interval coverage.
/// 2. Zero-effect calibration: when δ=0, the "strong evidence" false-positive rate is controlled.
/// 3. Degenerate case: as τ→0 with a large sample, the posterior mean approaches the mean
///    difference (analytic reference).
final class RecoveryTests: XCTestCase {

    /// Generate one simulated experiment: K block pairs, with A/B randomly ordered within each pair.
    private func simulate(
        delta: Double, mu: Double = 50, sigma: Double = 3, tau: Double = 1,
        pairs: Int = 2, daysPerBlock: Int = 6, rng: inout SplitMix64
    ) -> [BlockData] {
        var blocks: [BlockData] = []
        for _ in 0..<pairs {
            let treatFirst = uniform(&rng) < 0.5
            for slot in 0..<2 {
                let isTreat = (slot == 0) == treatFirst
                let blockEffect = normal(mean: 0, sd: tau, &rng)
                let values = (0..<daysPerBlock).map { _ in
                    normal(mean: mu + (isTreat ? delta : 0) + blockEffect, sd: sigma, &rng)
                }
                blocks.append(BlockData(condition: isTreat ? .intervention : .control, values: values))
            }
        }
        return blocks
    }

    private let priors = Priors(baselineMean: 50, baselineSD: 3)
    private let config = GibbsConfig(chains: 4, warmup: 400, draws: 1000, seed: 7)

    /// Red line 1: recovery of δ = −5 — unbiased estimate, normal coverage, converged chains.
    func testRecoveryOfKnownEffect() {
        let trueDelta = -5.0
        var rng = SplitMix64(seed: 2026)
        let reps = 30

        var meanErrors: [Double] = []
        var covered = 0
        var rHats: [Double] = []

        for rep in 0..<reps {
            let blocks = simulate(delta: trueDelta, rng: &rng)
            var cfg = config
            cfg.seed = UInt64(100 + rep)
            let post = BlockModel.fit(blocks: blocks, priors: priors, config: cfg)
            meanErrors.append(post.mean - trueDelta)
            if post.credibleInterval90.contains(trueDelta) { covered += 1 }
            rHats.append(post.rHat)
        }

        let bias = meanErrors.reduce(0, +) / Double(reps)
        XCTAssertLessThan(abs(bias), 0.8, "the posterior mean should be approximately unbiased, measured bias = \(bias)")
        XCTAssertGreaterThanOrEqual(covered, 24, "the 90% interval should cover ≥ 24 of 30 repetitions, measured \(covered)")
        XCTAssertLessThan(rHats.sorted()[reps / 2], 1.05, "the median R̂ should indicate convergence")
    }

    /// Red line 2: when δ = 0, the "strong evidence" false-positive rate is controlled (≤ 4 of 30).
    func testZeroEffectCalibration() {
        var rng = SplitMix64(seed: 9182)
        let reps = 30
        var falseStrong = 0

        for rep in 0..<reps {
            let blocks = simulate(delta: 0, rng: &rng)
            var cfg = config
            cfg.seed = UInt64(500 + rep)
            let post = BlockModel.fit(blocks: blocks, priors: priors, config: cfg)
            let evidenceNeg = Evidence.decide(post, hypothesizedPositive: false, ropeHalfWidth: 0.6)
            let evidencePos = Evidence.decide(post, hypothesizedPositive: true, ropeHalfWidth: 0.6)
            if evidenceNeg == .strong || evidencePos == .strong { falseStrong += 1 }
        }

        XCTAssertLessThanOrEqual(falseStrong, 4, "under zero effect, strong-evidence false positives should be ≤ 4 of 30, measured \(falseStrong)")
    }

    /// Red line 3: in the τ→0 + large-sample degenerate case, the posterior mean approaches
    /// the simple mean difference.
    func testDegenerateCaseMatchesMeanDifference() {
        var rng = SplitMix64(seed: 333)
        let blocks = simulate(delta: -4, tau: 0.01, pairs: 2, daysPerBlock: 60, rng: &rng)

        let treatMean = blocks.filter { $0.condition == .intervention }
            .flatMap(\.values).reduce(0, +) /
            Double(blocks.filter { $0.condition == .intervention }.flatMap(\.values).count)
        let ctrlMean = blocks.filter { $0.condition == .control }
            .flatMap(\.values).reduce(0, +) /
            Double(blocks.filter { $0.condition == .control }.flatMap(\.values).count)
        let observedDiff = treatMean - ctrlMean

        let post = BlockModel.fit(blocks: blocks, priors: priors,
                                  config: GibbsConfig(chains: 4, warmup: 500, draws: 1500, seed: 11))
        XCTAssertEqual(post.mean, observedDiff, accuracy: 0.5,
                       "in the large-sample degenerate case the posterior mean should approach the mean difference \(observedDiff), measured \(post.mean)")
    }

    /// Smoke test of the decision rules' boundary behavior.
    func testEvidenceRules() {
        // Synthetic posterior: all draws near -5 → strong evidence (negative direction).
        let strongNeg = PosteriorResult(chains: [[-5.1, -4.9, -5.0], [-5.2, -4.8, -5.0]])
        XCTAssertEqual(Evidence.decide(strongNeg, hypothesizedPositive: false, ropeHalfWidth: 0.5), .strong)
        // All draws near 0 → inside the ROPE, effect is negligible.
        let nearZero = PosteriorResult(chains: [[0.01, -0.02, 0.03], [0.0, 0.02, -0.01]])
        XCTAssertEqual(Evidence.decide(nearZero, hypothesizedPositive: true, ropeHalfWidth: 0.5), .negligible)
    }
}
