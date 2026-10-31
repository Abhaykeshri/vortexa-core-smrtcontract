# M10 Mutation and Extended Property Testing Report

## Mutation campaign

Gambit 0.2.1 generated a deterministic, solc-validated fixed-seed sample across every required logic location. BuyTheDip and SellThePump contain no independent mutable expressions; their behavior is inherited from the mutated `StrategyBase`, while `NormalLPStrategy` was mutated separately.

| Target | Generated | Killed |
| --- | ---: | ---: |
| Vault | 8 | 8 |
| PriceGuard | 8 | 8 |
| SwapExecutor | 8 | 8 |
| StrategyBase | 8 | 8 |
| NormalLPStrategy | 8 | 8 |
| BuyTheDipStrategy | 0 | n/a (inherits StrategyBase) |
| SellThePumpStrategy | 0 | n/a (inherits StrategyBase) |
| **Total** | **40** | **40 (100.00%)** |

The initial run killed 39/40 (97.50%), already above the 85% acceptance floor. The survivor replaced `SwapExecutor.minOutFromReference` with the constant `1`. A regression test now compares both directions with the shared `SwapMath.minAmountOut` implementation; the isolated rerun killed the survivor, producing the final 100% score.

Evidence is under `test-reports/M10-Security-20261026/mutation-campaign/`: manifests, source diffs, full log, CSV outcomes, and summary. Mutants ran in an isolated clone via `script/security/Run-M10MutationCampaign.ps1`, and the script restores every mutated source in `finally`.

## Formal properties

`test/formal/M10Halmos.t.sol` contains targeted Halmos properties for:

- LiquidityMath budget round trips never creating token value.
- The quotient/remainder lemma behind floor-rounded share conversion: a floor quotient cannot exceed its numerator, across the full `uint96` quotient domain.
- The quotient/remainder lemma behind ceil-rounded mint/withdraw conversion: rounding up covers the numerator for both divisors in a nontrivial coprime 7:11 ratio. Direct protocol conversions and arbitrary ratios remain covered by Foundry fuzzing.
- ShapeLibrary output staying aligned, contiguous, bounded, zero-initialized, and weighted to 10,000 bps across all eight shape IDs.

The `halmos` Foundry profile disables dynamic test linking because Halmos cannot execute Foundry's `deployCode` helper cheatcode. This changes test compilation only.

Halmos 0.3.3 with Z3 completed all four properties: 4 passed, 0 failed in 4.18 seconds of symbolic execution. Direct division formulations were also attempted and retained as diagnostic JSON; Z3 timed out without a counterexample, so the final proof uses mathematically equivalent quotient/remainder lemmas rather than presenting a timeout as a pass. Final evidence is `test-reports/M10-Security-20261026/halmos-final.json`.

## Long-duration stateful campaign

The corrected Foundry stateful campaign completed at 1,000 runs and depth 128, but it is not mislabeled as the guide-required 72-hour Echidna/Medusa soak. That dedicated-machine campaign, retained seeds/counterexamples, and the organizational code-freeze review remain external release gates.
