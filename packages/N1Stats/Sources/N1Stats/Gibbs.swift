import Foundation

/// Gibbs sampler for the block-level normal model (whitepaper §3.2–3.5).
///
///     y_tj = μ + δ·I(j is intervention) + b_j + ε_tj
///     b_j  ~ Normal(0, τ²)
///     ε_tj ~ Normal(0, σ²)
///
/// All full conditionals are conjugate (μ, δ, b_j normal; σ², τ² inverse-gamma).
/// Pure Swift, zero dependencies.
public enum BlockModel {

    public static func fit(
        blocks: [BlockData],
        priors: Priors,
        config: GibbsConfig = GibbsConfig()
    ) -> PosteriorResult {
        precondition(blocks.count >= 2, "at least one block pair is required")
        precondition(blocks.contains { $0.condition == .intervention } &&
                     blocks.contains { $0.condition == .control },
                     "both intervention and control blocks must be present")

        let j = blocks.count
        let isTreat = blocks.map { $0.condition == .intervention }
        let n = blocks.map { $0.values.count }
        let nTotal = n.reduce(0, +)
        let allValues = blocks.flatMap { $0.values }
        let grandMean = allValues.reduce(0, +) / Double(nTotal)
        let grandVar = max(
            allValues.reduce(0) { $0 + ($1 - grandMean) * ($1 - grandMean) } / Double(max(nTotal - 1, 1)),
            1e-9
        )

        let s0sq = priors.baselineSD * priors.baselineSD
        let varShape = priors.varianceShape

        var chainsDelta: [[Double]] = []
        chainsDelta.reserveCapacity(config.chains)

        for chain in 0..<config.chains {
            var rng = SplitMix64(seed: config.seed &+ UInt64(chain) &* 0x9E37)

            // Initialization
            var mu = grandMean
            var delta = 0.0
            var b = [Double](repeating: 0, count: j)
            var sigma2 = grandVar
            var tau2 = grandVar / 2

            var deltaDraws: [Double] = []
            deltaDraws.reserveCapacity(config.draws)

            for iter in 0..<(config.warmup + config.draws) {
                // —— b_j | rest ——
                for idx in 0..<j {
                    let x = isTreat[idx] ? delta : 0
                    let resSum = blocks[idx].values.reduce(0) { $0 + ($1 - mu - x) }
                    let prec = Double(n[idx]) / sigma2 + 1 / tau2
                    let mean = (resSum / sigma2) / prec
                    b[idx] = normal(mean: mean, sd: (1 / prec).squareRoot(), &rng)
                }

                // —— μ | rest ——
                var resSumAll = 0.0
                for idx in 0..<j {
                    let x = isTreat[idx] ? delta : 0
                    for y in blocks[idx].values { resSumAll += y - x - b[idx] }
                }
                let muPrec = Double(nTotal) / sigma2 + 1 / s0sq
                let muMean = (resSumAll / sigma2 + priors.baselineMean / s0sq) / muPrec
                mu = normal(mean: muMean, sd: (1 / muPrec).squareRoot(), &rng)

                // —— δ | rest (intervention blocks only) ——
                var resSumTreat = 0.0
                var nTreat = 0
                for idx in 0..<j where isTreat[idx] {
                    for y in blocks[idx].values { resSumTreat += y - mu - b[idx] }
                    nTreat += n[idx]
                }
                let dPrec = Double(nTreat) / sigma2 + 1 / priors.deltaPriorVariance
                let dMean = (resSumTreat / sigma2) / dPrec
                delta = normal(mean: dMean, sd: (1 / dPrec).squareRoot(), &rng)

                // —— σ² | rest ——
                var sse = 0.0
                for idx in 0..<j {
                    let x = isTreat[idx] ? delta : 0
                    for y in blocks[idx].values {
                        let r = y - mu - x - b[idx]
                        sse += r * r
                    }
                }
                sigma2 = inverseGamma(shape: varShape + Double(nTotal) / 2,
                                      scale: priors.sigmaScale + sse / 2, &rng)

                // —— τ² | rest ——
                let ssb = b.reduce(0) { $0 + $1 * $1 }
                tau2 = inverseGamma(shape: varShape + Double(j) / 2,
                                    scale: priors.tauScale + ssb / 2, &rng)

                if iter >= config.warmup { deltaDraws.append(delta) }
            }
            chainsDelta.append(deltaDraws)
        }

        return PosteriorResult(chains: chainsDelta)
    }
}
