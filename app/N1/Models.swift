import Foundation
import N1Stats

enum DayKind: String, Codable {
    case control, intervention, washout

    var label: String {
        switch self {
        case .control: "Control"
        case .intervention: "Intervention"
        case .washout: "Washout"
        }
    }
}

/// Box–Muller (for demo-data generation only; the randomness used in statistical inference lives inside N1Stats).
func gaussian(mean: Double, sd: Double, using rng: inout SplitMix64) -> Double {
    let u1 = Double.random(in: Double.leastNonzeroMagnitude..<1, using: &rng)
    let u2 = Double.random(in: 0..<1, using: &rng)
    return mean + sd * sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
}
