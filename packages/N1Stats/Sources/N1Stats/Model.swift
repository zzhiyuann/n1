import Foundation

/// Block condition: intervention or control. Washout days are excluded in the
/// data-prep layer and never enter this package.
public enum Condition: String, Codable, Sendable {
    case intervention
    case control
}

/// The daily observations of one block (the primary endpoint, e.g. mean nightly HRV).
public struct BlockData: Sendable {
    public let condition: Condition
    public let values: [Double]

    public init(condition: Condition, values: [Double]) {
        self.condition = condition
        self.values = values
    }
}

/// Prior specification. Estimated automatically from ≥14 days of history before the
/// experiment starts (whitepaper §3.3).
///
/// v0 implementation notes (two deviations from the whitepaper draft, both written back
/// into the whitepaper appendix):
/// 1. The variance prior uses InvGamma (conjugate) rather than Half-Normal.
/// 2. The scale of τ² is taken as (s₀/3)² rather than s₀² — with very few blocks
///    (typically J=4) the data can't identify τ², and an overly large τ prior lets the
///    block effects absorb the intervention effect, causing a systematic shrinkage of δ
///    toward zero (recovery test measured bias ≈ +2.0). "Block-level drift ≤ 1/3 of the
///    daily noise" is a weakly-informative default; the δ prior SD is correspondingly
///    set to 1.5·s₀, accommodating effects up to 1.5 baseline SDs.
public struct Priors: Sendable {
    /// Prior mean of μ (the historical baseline mean).
    public var baselineMean: Double
    /// Historical baseline standard deviation s₀.
    public var baselineSD: Double
    /// InvGamma shape for σ², τ² (default 2, weakly informative).
    public var varianceShape: Double

    public init(baselineMean: Double, baselineSD: Double, varianceShape: Double = 2) {
        precondition(baselineSD > 0)
        self.baselineMean = baselineMean
        self.baselineSD = baselineSD
        self.varianceShape = varianceShape
    }

    /// Prior variance of δ: (1.5·s₀)².
    var deltaPriorVariance: Double { 2.25 * baselineSD * baselineSD }
    /// InvGamma scale of the σ² prior: s₀² (prior mean ≈ historical variance).
    var sigmaScale: Double { baselineSD * baselineSD }
    /// InvGamma scale of the τ² prior: (s₀/3)².
    var tauScale: Double { baselineSD * baselineSD / 9 }
}

/// Sampler configuration.
public struct GibbsConfig: Sendable {
    public var chains: Int
    public var warmup: Int
    public var draws: Int
    public var seed: UInt64

    public init(chains: Int = 4, warmup: Int = 500, draws: Int = 1500, seed: UInt64 = 42) {
        self.chains = chains
        self.warmup = warmup
        self.draws = draws
        self.seed = seed
    }
}
