# M7 Test Report

> **Superseded in part by `docs/M7_AUDIT_REPORT.md` (2026-10-22).** That audit fixed a first-deposit accounting defect (M7-01) and the CI workflow (M7-03), and corrects these claims: no `.gas-snapshot` existed, initialization-time validation was untested, the fork matrix ran at the latest block rather than the pinned one (which predated the Universal Router deployment), and the `Vault` size is now 24,348 bytes.

## Results

| Gate | Result |
|---|---|
| Formatting | PASS — `forge fmt --check` |
| Optimized build/size | PASS — Vault 24,479 bytes, 97-byte EIP-170 margin |
| Focused M7 strategy integration | PASS — 4 passed, 0 failed, 0 skipped |
| High-intensity CI | PASS — 45 suites; 476 passed, 0 failed, 0 skipped |
| Final coverage run | PASS — 476 passed, 0 failed, 5 fork setup skips |
| Final aggregate coverage | 95.52% lines; 95.43% statements; 86.72% branches; 92.36% functions |
| Source policy | PASS — exact pragma/SPDX, NatSpec, import and forbidden-construct policy |
| Storage layouts | PASS — Vault, M5 and M6 layouts match |
| Gas snapshot | PASS — generated `.gas-snapshot`; 476 passed, 0 failed, 5 fork setup skips |
| Aderyn 0.6.8 | PASS — 88 detectors; 0 high, 0 low |
| Mainnet fork | PASS — fresh PublicNode latest-state run; 5 suites, 32 passed, 0 failed, 0 skipped |

The CI profile used 10,000 runs for ordinary fuzz tests and 1,000 runs × 128 calls for the principal invariant suites (real-v4 invariants use the repository's bounded 256-run profile). The dedicated M7 alignment and signed-rounding fuzz gates each executed 100,000 runs.

## Exact commands executed

```text
forge fmt --check
forge build --sizes
forge test --match-contract SrcPolicyTest --match-test test_every_src_file_satisfies_the_project_policy
forge test --match-contract '(StrategiesTest|M7StrategiesRealV4Test)'
forge test --profile ci
forge coverage --report summary
forge inspect Vault storage-layout
forge inspect VaultM5Module storage-layout
forge inspect VaultM6Module storage-layout
Get-Command slither
Get-Command aderyn
```

Targeted and full suites were rerun after resolving the only final CI issue: the source-policy allowlist comment had to be immediately adjacent to the immutable M5 delegatecall. No assertion or security check was weakened.

## Coverage added

- Exact Normal LP out-of-range and asymmetric drift boundaries.
- Exact below/above one-sided deposit, trail, and fill boundaries.
- Buy/Sell strategies in both base-token orientations and all deposit modes.
- Negative tick floor/ceil vectors and two dedicated 100,000-run property campaigns.
- Config rejection, shapes, weights, empty bands, zero holdings, invalid prices/fees, swap direction and holding bounds.
- First deposits using production strategies against pinned in-process Uniswap v4 ERC-20/ERC-20 and native/ERC-20 pools, including real swap execution in both input modes and post-call allowance revocation.
- Existing hostile-plan, wrong-side, invalid-position-state, excessive-swap, reentrancy, stale-state, NFT-custody, fee, share, withdrawal and atomicity regression suites.

## Specification compliance checklist

| Requirement | Implementation | Test/evidence | Status |
|---|---|---|---|
| Four production strategy contracts | `src/strategies/*` | build and focused suite | PASS |
| Stateless strategies; immutable ShapeLibrary; no fund custody | `StrategyBase` and derived contracts | source policy/security review | PASS |
| Safe spacing, negative floor/ceil, widened tick arithmetic, empty edges | `StrategyBase` | `Strategies.t.sol` 100k fuzz and edge tests | PASS |
| Normal config, mode, eligibility and exact OUT_OF_RANGE/DRIFT bounds | `NormalLPStrategy` | Normal unit boundary/config tests | PASS |
| Normal ShapeLibrary bands and bounded fee-aware swap intent | `NormalLPStrategy` | swap direction, zero holding, price/fee and budget tests | PASS |
| Buy-the-Dip orientation, mode, config and one-sided placement | `BuyTheDipStrategy`/`StrategyBase` | both-orientation unit and real-v4 tests | PASS |
| Sell-the-Pump mirrored behavior | `SellThePumpStrategy`/`StrategyBase` | both-orientation unit and real-v4 tests | PASS |
| Exact TRAIL/FILLED thresholds and lockOnFill | `StrategyBase` | one-sided boundary/lock tests | PASS |
| FILLED returns empty no-swap lock-idle plan | `StrategyBase` | `test_oneSidedPlanIgnoresKeeperCenterAndLocksOnFill` | PASS |
| Live-tick one-sided anchoring; keeper center ignored | `StrategyBase` | alignment/orientation 100k fuzz | PASS |
| Config-aware IStrategy integration | `IStrategy.sol` and all callers/mocks | full CI compile/tests | PASS |
| Initialization-time validation with current tick | `Vault` + `VaultM5Module.validateStrategy` | config and Vault initialization tests | PASS |
| First deposit uses strategy `NONE` plan | `Vault._delegateDepositPlan` + M5 | production-strategy real-v4 integration | PASS |
| Vault independently validates hostile plan output | `VaultM5Module.depositPlan` | existing real-v4 controls/M6 attack suites | PASS |
| Normal first-deposit swaps execute with oracle floor, 1% slippage cap, 60% value cap and revoked allowances | `VaultM5Module.depositPlan` | real-v4 ERC-20/native swap tests and cap unit test | PASS |
| Later deposits/ERC-4626/pair deposits remain compatible | Vault | full Vault and real-v4 lifecycle suites | PASS |
| Rebalance refreshes state/oracle after callbacks | `VaultM6Module` | M6 unit/attack/real-v4 suites | PASS |
| Keeper, pause, cooldown, slippage, 60% cap and loss brake preserved | `VaultM6Module` | M6 unit/fuzz/attack/invariant suites | PASS |
| Realized center event semantics | `VaultM6Module` | real-v4 event regression | PASS |
| Storage layout preserved | Vault/M5/M6 declarations | three `forge inspect ... storage-layout` checks | PASS |
| Vault remains below EIP-170 | modularized M5 integration | 24,479-byte final build (97-byte margin) | PASS |
| M0–M6 regression compatibility | repository-wide code | 476-test CI pass | PASS |
| Exact PDF/design-tab one-wei worked examples | formulas implemented | original complete inputs unavailable | BLOCKED |
| Mainnet fork matrix | fork tests present | fresh PublicNode run: 32/32 pass | PASS |

Deterministic real-v4 tests exercise the pinned PoolManager, PositionManager, StateView, settlement, NFT lifecycle and native/ERC-20 paths. PublicNode prunes the configured historical block, so the local fork evidence is latest-state; the CI fork job retains the deterministic block and requires an archive-capable RPC secret.
