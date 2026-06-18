# N1Stats

N1's open-source statistical core: within-person Bayesian analysis of single-subject block
crossover experiments (N-of-1 trials). Pure Swift, zero dependencies, fully reproducible
(explicit seed).

## Model

```
y_tj = μ + δ·I(j is intervention) + b_j + ε_tj
b_j  ~ Normal(0, τ²)    # block random effect
ε_tj ~ Normal(0, σ²)    # within-day noise
```

Gibbs sampling (fully conjugate conditionals) yields the posterior of δ: mean, 90% credible
interval, P(direction), ROPE probability, and multi-chain R̂. The decision rule (strong /
preliminary / negligible / insufficient evidence) is deterministic code — the LLM never takes
part in producing a number.

The full methodology is in [`../../whitepaper/methods-v0.md`](../../whitepaper/methods-v0.md).

## Usage

```swift
import N1Stats

let blocks = [
    BlockData(condition: .control,      values: [52.1, 49.8, 51.3, 50.2, 53.0, 51.7]),
    BlockData(condition: .intervention, values: [46.0, 47.2, 45.1, 48.3, 46.9, 44.8]),
    BlockData(condition: .intervention, values: [47.5, 45.9, 46.2, 48.0, 45.5, 47.1]),
    BlockData(condition: .control,      values: [51.0, 52.4, 50.6, 49.9, 52.8, 51.2]),
]
let priors = Priors(baselineMean: 51, baselineSD: 3) // estimated from ≥14 days of historical baseline
let posterior = BlockModel.fit(blocks: blocks, priors: priors)

posterior.mean                      // posterior mean of δ
posterior.credibleInterval90       // 90% credible interval
posterior.probDirection(positive: false)
posterior.rHat                     // convergence diagnostic; < 1.01 indicates convergence
Evidence.decide(posterior, hypothesizedPositive: false, ropeHalfWidth: 0.6)
```

## Validation

`swift test` runs the three release gates from whitepaper §3.6: known-effect recovery (unbiased
+ coverage), null-effect calibration (controlled false positives), and degenerate-case comparison
against the closed-form solution.
