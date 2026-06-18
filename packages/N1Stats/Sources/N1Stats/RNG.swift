import Foundation

/// Reproducible random number generator (SplitMix64).
/// All randomness in the statistics core flows through an explicitly passed generator,
/// guaranteeing the same seed yields the same result — a prerequisite for auditability.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { self.state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Uniform distribution on the open interval (0, 1).
@inline(__always)
func uniform(_ rng: inout SplitMix64) -> Double {
    Double(rng.next() >> 11) * (1.0 / 9_007_199_254_740_992.0) + .leastNonzeroMagnitude
}

/// Box–Muller normal sampling.
func normal(mean: Double = 0, sd: Double = 1, _ rng: inout SplitMix64) -> Double {
    let u1 = uniform(&rng)
    let u2 = uniform(&rng)
    return mean + sd * (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * .pi * u2)
}

/// Gamma(shape, rate) sampling via the Marsaglia–Tsang method; uses a boost transform when shape < 1.
func gamma(shape: Double, rate: Double, _ rng: inout SplitMix64) -> Double {
    precondition(shape > 0 && rate > 0)
    if shape < 1 {
        let g = gamma(shape: shape + 1, rate: rate, &rng)
        return g * Foundation.pow(uniform(&rng), 1.0 / shape)
    }
    let d = shape - 1.0 / 3.0
    let c = 1.0 / (9 * d).squareRoot()
    while true {
        var x: Double
        var v: Double
        repeat {
            x = normal(&rng)
            v = 1 + c * x
        } while v <= 0
        v = v * v * v
        let u = uniform(&rng)
        if u < 1 - 0.0331 * x * x * x * x { return d * v / rate }
        if Foundation.log(u) < 0.5 * x * x + d * (1 - v + Foundation.log(v)) { return d * v / rate }
    }
}

/// InvGamma(shape, scale) sampling: X = 1 / Gamma(shape, rate: scale).
func inverseGamma(shape: Double, scale: Double, _ rng: inout SplitMix64) -> Double {
    1.0 / gamma(shape: shape, rate: scale, &rng)
}
