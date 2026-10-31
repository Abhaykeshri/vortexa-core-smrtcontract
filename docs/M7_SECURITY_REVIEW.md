# M7 Security Review

> **Superseded in part by `docs/M7_AUDIT_REPORT.md` (2026-10-22).** That audit fixed a first-deposit accounting defect (M7-01) and the CI workflow (M7-03), and corrects these claims: no `.gas-snapshot` existed, initialization-time validation was untested, the fork matrix ran at the latest block rather than the pinned one (which predated the Universal Router deployment), and the `Vault` size is now 24,348 bytes.

## Result

No unresolved high-severity defect was found in the implemented and locally tested M7 scope. This is an internal engineering review, not an independent audit or deployment approval.

## Issues found and fixed

- Vault initialization now enters the same OpenZeppelin transient reentrancy guard as every other mutating entry point; a hostile ERC-20 approval-callback regression proves that `collectFees` cannot reenter initialization.
- Successful initialization now emits `VaultInitialized` after approvals complete, allowing indexers to observe the finalized clone state.
- First-deposit geometry previously bypassed the strategy: it now uses the selected strategy and a storage-mirrored independent validator.
- Strategy orientation could not be expressed by `depositMode()`: the mode is now configuration aware.
- Strategy config was not validated against the initialization market tick: initialization now delegates a live-tick validation before completion.
- Rebalance planning could use stale pool state after callback-capable burns/fee collection: sqrt price, tick and oracle trust are refreshed before planning.
- Rebalance events could report the keeper proposal rather than the realized range: events now report the target range center or execution tick for lock-idle.
- Zero weights were accepted in plan validation: all target weights must now be nonzero and sum exactly to the denominator.
- Initial hostile plans needed full deposit-path validation: state, count, bounds, alignment, ordering, contiguity, weights, side, lock and swap fields are checked before token movement.

## Control review

| Area | Result/evidence |
|---|---|
| Reentrancy and callback manipulation | Existing non-reentrancy, real-v4 callback attacks and atomic rollback tests pass |
| Token orientation/wrong-side liquidity | Config-aware modes plus live-tick side validation; 100k orientation fuzz passes |
| Tick overflow/negative rounding/extremes | `int256` arithmetic and mathematical floor/ceil; edge/fuzz tests pass |
| Manipulated/oracle-stale price | PriceGuard before deposits and refreshed during rebalance; attack suites pass |
| Malicious strategy/keeper plans | Vault validates all safety-critical fields independently; hostile-plan suites pass |
| Swap/slippage/loss | Holding bound, value cap, oracle floor, slippage and final-value brake preserved |
| Shares, fees and withdrawals | M5/M6 real-v4 lifecycle and invariants pass; lock-idle leaves withdrawals open |
| NFT custody/orphan positions | Ownership validation and rollback invariants pass |
| Allowances/fund custody | Strategies have no transfer/approval code; Vault allowance/custody invariants pass |
| Native ETH/FOT assumptions | Native lifecycle/attack tests pass; fee-on-transfer deposits reject measured shortfall |
| Gas/DoS | Five-band bound, build-size gate and high-intensity suites pass; Vault has 576-byte runtime margin |

## Storage layout

`forge inspect` confirmed identical layouts across Vault, VaultM5Module and VaultM6Module:

| Slot | Field(s) |
|---:|---|
| 0 | `name` |
| 1 | `symbol` |
| 2 | `totalSupply` |
| 3 | `lastRebalance`, `paused`, `filled`, `_initialized` (packed) |
| 4–9 | `_cfg` |
| 10 | `_poolId` |
| 11 | `_strategy` |
| 12 | `_bands` |
| 13 | `balanceOf` |
| 14 | `allowance` |

No storage slot was inserted or reordered and no proxy/upgradeability mechanism was added.

## Tooling

Foundry compilation, size checks, lint/source policy, unit, integration, attack, fuzz and invariants were executed. Aderyn 0.6.8 was run through WSL with all 88 detectors and reports 0 High / 0 Low; the fixes and scoped annotations are documented in `docs/ADERYN_TRIAGE.md`. Slither was not available for a fresh M7 run.
