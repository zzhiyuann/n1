import Foundation

/// Posterior result and decision rules for δ (the within-subject intervention effect),
/// whitepaper §3.4.
public struct PosteriorResult: Sendable {
    /// The δ posterior draws from each chain.
    public let chains: [[Double]]
    /// All draws merged together (sorted, for quantile queries).
    private let sorted: [Double]

    public init(chains: [[Double]]) {
        self.chains = chains
        self.sorted = chains.flatMap { $0 }.sorted()
    }

    public var draws: [Double] { chains.flatMap { $0 } }

    public var mean: Double {
        sorted.reduce(0, +) / Double(sorted.count)
    }

    /// Empirical quantile (linear interpolation).
    public func quantile(_ p: Double) -> Double {
        precondition(p >= 0 && p <= 1)
        let pos = p * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        if lo == hi { return sorted[lo] }
        let w = pos - Double(lo)
        return sorted[lo] * (1 - w) + sorted[hi] * w
    }

    /// 90% credible interval.
    public var credibleInterval90: ClosedRange<Double> {
        quantile(0.05)...quantile(0.95)
    }

    /// P(δ > 0) or P(δ < 0).
    public func probDirection(positive: Bool) -> Double {
        let count = sorted.reduce(0) { $0 + ((positive ? $1 > 0 : $1 < 0) ? 1 : 0) }
        return Double(count) / Double(sorted.count)
    }

    /// Posterior probability that δ falls inside the ROPE (±halfWidth).
    public func probInROPE(halfWidth: Double) -> Double {
        precondition(halfWidth > 0)
        let count = sorted.reduce(0) { $0 + (abs($1) <= halfWidth ? 1 : 0) }
        return Double(count) / Double(sorted.count)
    }

    /// Multi-chain Gelman–Rubin R̂ (convergence diagnostic; < 1.01 considered converged,
    /// whitepaper §3.5).
    public var rHat: Double {
        let m = chains.count
        guard m >= 2, let n = chains.first?.count, n >= 2 else { return .nan }
        let chainMeans = chains.map { $0.reduce(0, +) / Double(n) }
        let grand = chainMeans.reduce(0, +) / Double(m)
        let bVar = chainMeans.reduce(0) { $0 + ($1 - grand) * ($1 - grand) }
            * Double(n) / Double(m - 1)
        let wVar = chains.enumerated().reduce(0.0) { acc, pair in
            let (idx, chain) = pair
            let cm = chainMeans[idx]
            return acc + chain.reduce(0) { $0 + ($1 - cm) * ($1 - cm) } / Double(n - 1)
        } / Double(m)
        let varPlus = Double(n - 1) / Double(n) * wVar + bVar / Double(n)
        return (varPlus / wVar).squareRoot()
    }
}

/// Evidence tier (whitepaper §3.4 decision rules). The text templates are rendered by the
/// app layer; this enum is a deterministic verdict — the LLM never participates here.
public enum Evidence: String, Sendable {
    case strong          // P(correct direction) ≥ 0.95
    case preliminary     // 0.80 ≤ P < 0.95: suggest extending the experiment
    case negligible      // P(δ ∈ ROPE) ≥ 0.90: effect is negligible
    case insufficient    // otherwise: no conclusion

    public static func decide(
        _ posterior: PosteriorResult,
        hypothesizedPositive: Bool,
        ropeHalfWidth: Double
    ) -> Evidence {
        let pDir = posterior.probDirection(positive: hypothesizedPositive)
        let pROPE = posterior.probInROPE(halfWidth: ropeHalfWidth)
        if pDir >= 0.95 { return .strong }
        if pROPE >= 0.90 { return .negligible }
        if pDir >= 0.80 { return .preliminary }
        return .insufficient
    }
}
