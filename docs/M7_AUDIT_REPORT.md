# M7 Audit Report: production strategies

Date: 2026-10-22. Branch `milestone/M7` at `dabca14` plus the working-tree fixes described here.

Scope:
- `src/strategies/{StrategyBase,NormalLPStrategy,BuyTheDipStrategy,SellThePumpStrategy}.sol` (new);
- the M7 changes to `src/Vault.sol`, `src/VaultM5Module.sol` (`depositPlan`, `validateStrategy`), `src/VaultM6Module.sol` and `src/interfaces/IStrategy.sol`;
- the annotation-only changes to `PriceGuard`, `ShapeLibrary`, `SqrtPriceMath` and `SwapExecutor` (checked to be comment-only apart from the always-reverting legacy `swap` losing a redundant `nonReentrant`);
- the M7 CI workflow;
- the production strategies end to end against the real Uniswap v4 `PoolManager`, `PositionManager` and `StateView` (in-process) and the mainnet fork.

The guide references are sections 5.1, 6.4, 8.3, 9.1 to 9.4 and 12.2.

## Verdict

One accounting defect (M7-01) let the cost of a first-deposit swap fall on existing holders. It is fixed and pinned by a real-v4 attack test that fails on the original code. The CI pipeline added in M7 could not pass as written (M7-03); it is fixed. The rest of the M7 code matched the guide, but the mutation round showed that 26 of 59 mutants of the new code survived the M7 test suite. The suite did not test, among other things, that initialization validates the configuration, nor any of the first-deposit plan guards in the module. Every survivor is now killed by a new test (M7-04).

The root-level M7 reports are superseded where they disagree with this one:
- `docs/M7_TEST_REPORT.md` and `docs/M7_IMPLEMENTATION_REPORT.md` say "gas snapshot generated" (no `.gas-snapshot` existed) and "Initialization-time validation … PASS" (no test checked it).
- They also report the fork matrix as passing, but that run was at the latest block, not at the block CI pins.
- They give the `Vault` size as 24,479 bytes; it is 24,348 after this audit.

## Findings

| ID | Severity | Finding | Fix | Proof (fails before the fix) |
| --- | --- | --- | --- | --- |
| M7-01 | Medium | **The first-band deposit swap was paid by existing holders.** A Normal LP vault can have holders but no bands: ERC-4626 `deposit` and `mint` hold token1 idle until the first pair deposit. That first `depositPair` runs the strategy's swap from the depositor's tokens through the executor, which costs the pool fee, price impact and up to the 1% oracle floor on up to 60% of the deposit. Shares were minted for the depositor's tokens valued at the pre-swap price, `V(amounts) - V(refunds)`, so the swap cost was socialized over every holder. Measured: alice's 100,000 USDC first pair deposit cost bob (50,000 USDC idle) about 125 USDC. A depositor who also sandwiches the vault's swap within the oracle tolerance extracts that cost from the idle holders. | The deposit credits `min(valueUsed, added)`. `added` is the vault's value after the deposit (refunds excluded) minus its value before, both at the same pre-deposit price and net of fees, so swap costs stay with the depositor. The exact-floor property test now checks the new rule. | `test_first_band_deposit_swap_cost_is_not_charged_to_existing_holders`, `testFuzz_pair_deposit_shares_are_exactly_the_floor` |
| M7-02 | Low | **Empty one-sided deposits passed the deposit-mode check.** `_checkDepositMode` rejected `(0, 0)` only for `BothTokens`, so a one-sided vault accepted it there and failed later with `ZeroLiquidity`. | `(0, 0)` is refused with `InvalidDepositMode` in every mode (the check is now one condition; `Vault` shrank by 76 bytes). | the empty-deposit assertions in the four one-sided lifecycle tests |
| M7-03 | Low | **The M7 CI could not pass, and its fork job was vacuous.** (a) `forge snapshot --check` ran without a committed `.gas-snapshot`, and fuzz and invariant gas depends on the random seed, so it could never match. (b) The fork job pins mainnet block 23,000,000, but the Universal Router v2.2.0 the configuration points at (`0xab863E…3BbB`) was created at block 26,006,366 (creation tx `0x205624ca…6a06`), so the executor and vault fork suites had no router at the pinned block. (c) The fork job never ran a fork test at all: the workflow-wide `FOUNDRY_PROFILE: ci` carries `no_match_path = "test/fork/*"`, so `--match-path "test/fork/*.t.sol"` selected nothing and forge exited 0 ("No tests found"). The job would have stayed green whatever the fork suites did. (d) The license step `! grep -RniE 'BUSL\|Business Source License' src` matched the comment in `SqrtPriceMath.sol` explaining that no BUSL code is used, so the step always exited 1. (e) The coverage gate read the wrong column (`$2` is the label "Total", which `awk` evaluates as 0), so it always failed. Its total also included test handlers, which put it at 94.43% for code that is 99.87% covered. (f) Slither with `fail-on: high` reported 15 High results (14 reviewed false positives in `src/`, one in OpenZeppelin), so the static-analysis job always failed. | <ul><li>(a) The snapshot step checks deterministic tests only, with a 1% tolerance for the pinned forge version, and `.gas-snapshot` is committed.</li><li>(b) `script/config/mainnet.json` pins block 26,246,332, after the router deployment, and the fork suite passes at exactly that block.</li><li>(c) The fork job runs under the `fork` profile and fails unless the suites actually ran and passed.</li><li>(d) The license step checks SPDX headers.</li><li>(e) The coverage gate parses the percentage column and measures `src/` only (`--no-match-coverage "^(test\|script)/"`).</li><li>(f) `slither.config.json` filters `lib/`, `test/` and `script/`. The 14 reviewed `src/` results carry line-scoped `slither-disable-next-line` comments with the reason (storage mirrors written through delegatecall, ETH sent only to immutable dependencies, the documented nonReentrant windows); comments only, the bytecode is unchanged.</li></ul> | Every step dry-run locally with the workflow's own commands. The license and coverage parsers were also checked against negative controls (a BUSL SPDX header fails; 94.43% fails). See Verification. |
| M7-04 | Info | **Test gaps found by mutation:** 26 of 59 mutants of the M7 code survived the full suite. Uncovered areas: <ul><li>initialization-time `validateConfig` (removing the call from `initialize` or from the module survived);</li><li>the one-sided shape whitelist, drift and wrong-side width checks;</li><li>a `FILLED` plan without lock-on-fill;</li><li>the anchor domain check;</li><li>Normal LP swap sizing: fee gross-up, buy-side rounding, holding caps, direction;</li><li>every first-deposit plan guard: lock-idle, one-sided swap, swap above the supplied input, inconsistent swap flags, six bands, zero weights, the exact one-sided boundary;</li><li>the fee term of the deposit swap's oracle floor, the allowance revoke, and the swap output entering the deposit budget;</li><li>the `filled` gate on asset deposits.</li></ul>Coverage also showed that M7's new PriceGuard re-check after the rebalance burn (`VaultM6Module` line 220) had never run. | Tests added. The second round killed 25 of the 26. The last one (Normal LP token1 holding cap) binds only when the planned range lies entirely on one side of the price, so the swap-sizing fuzz now also moves the keeper center. The re-check test fails when the re-check is deleted. | `test/unit/Strategies.t.sol` (7 new tests), `test/unit/Vault.t.sol` (9), `test/unit/VaultM6.t.sol` (`test_trust_is_rechecked_after_the_burn_and_fee_callbacks`), `test/attack/VaultM7RealV4Attacks.t.sol` |
| M7-05 | Info | **No invariant ran a production strategy.** The full-lifecycle invariant used the test planner, and one-sided TRAIL/FILLED rebalances, lock-idle and the deposit window were never exercised on real v4 under random sequences. | The full-lifecycle invariant now runs the production `NormalLPStrategy` (DRIFT triggers included). A new one-sided invariant runs production Buy the Dip in both orientations (native and ERC-20). | `test/invariant/VaultFullLifecycleInvariant.t.sol`, `test/invariant/VaultM7OneSidedInvariant.t.sol` |

## Behaviour reviewed and kept (documented in `docs/known-issues.md`)

- **A filled lock-on-fill vault is terminal**, as the guide designs it. It holds idle tokens, refuses every deposit (`maxDeposit` is 0), and never triggers again; withdrawals keep working (tested in all four orientations).
- **The Normal LP first deposit is planned around `config.centerTick`**, not the live tick (guide 6.4). If the price has left that range before the first deposit, the first ladder is minted out of range. The depositor must then supply mostly the token that range holds, or the planned swap exceeds the 60% cap (`SwapTooLarge`). The keeper's `OUT_OF_RANGE` rebalance re-centres afterwards.
- **Out-of-range Normal LP rebalances need about a 50% swap.** It fits the 60% cap, but must clear the oracle floor (1% plus the pool fee) after price impact, so a vault that is large against pool depth cannot re-centre in one step. Measured against the in-process pools in `test_production_normal_lp_rebalances_after_out_of_range_moves`.
- **Normal LP cannot plan at raw prices below 2^-96** (tick below about -665,000): `priceX96` rounds to zero and the plan reverts `InvalidPrice`. No real pool trades there.
- **Fees a one-sided ladder earns in the other currency stay idle.** A token1-only ladder cannot hold token0. They are counted in `totalAssets` and paid out pro rata.
- **`_depositAsset`'s `filled` and window check is reachable only with a zero amount.** `deposit` and `mint` gate on `maxDeposit`/`maxMint` first. It is kept as defence in depth and pinned by a test.

## Verification

| Check | Result |
| --- | --- |
| `forge fmt --check`, SPDX/license step, `forge build --sizes` (ci profile) | pass |
| `forge test` (default profile) | 505 passed, 0 failed, 5 skipped (the RPC-gated fork suites) |
| `forge test --profile ci` (10,000 fuzz runs; invariants per inline config) | 505 passed, 0 failed (47 suites, 103 s) |
| New invariant `VaultM7OneSidedInvariant` | 128 runs × depth 64 per orientation: single-sided rule at every mint, no one-sided rebalance swaps, filled implies no bands and closed deposits, exact protocol fee, every holder can exit, exits ≤ `totalAssets`, NFT custody, share supply. Over 128 runs it rebalanced about 100 times and filled 10 to 12 times per orientation. |
| Full-lifecycle invariant on production Normal LP | 256 runs × depth 64; sanity test reaches DRIFT and rebalances |
| Mutation round 1 (59 mutants on the strategies, `depositPlan` and its validators, the Vault deposit valuation and gates, initialization) | 33 killed, 26 survived (test gaps, M7-04) |
| Mutation round 2 (the 26 survivors against the new tests) | 25 killed; the last one killed after widening the swap-sizing fuzz. All 59 killed. |
| Extra mutant: delete the PriceGuard re-check after the rebalance burn | killed by `test_trust_is_rechecked_after_the_burn_and_fee_callbacks` |
| Multi-seed fuzz (seeds 11, 222, 3333, 44444, full non-fork suite) | 505/505 per seed |
| Storage layout `Vault` vs `VaultM5Module` vs `VaultM6Module` | identical, slot and offset (13 entries) |
| Slither 0.11.4 (`slither . --fail-high`, as the CI action runs it, with the new `slither.config.json`) | exit 0, no High results. Before the suppressions: 14 High in `src/`, all reviewed false positives: `uninitialized-state` ×9 (module storage mirrors and `Vault.filled`, written through delegatecall), `reentrancy-eth` ×3 (documented nonReentrant windows), `arbitrary-send-eth` ×2 (ETH to the immutable executor and PositionManager). The M7 Medium results are intended: floor alignment flagged as `divide-before-multiply`, a zero-initialized accumulator, and validation-by-revert calls whose return values are unused. |
| Aderyn 0.6.8 (all detectors, as CI runs it) | 0 High, 0 Low; the CI `grep` on `report.md` passes |
| Coverage (`FOUNDRY_PROFILE=ci forge coverage --no-match-coverage "^(test\|script)/"`, the CI command) | `src/` total 99.87% lines, 98.67% statements, 94.07% branches, 100% functions (gate: 95% lines). Per file: strategies 98 to 100% lines and 93.75 to 100% branches; `Vault` 99.79% lines / 90.51% branches; `VaultM5Module` 100% / 94.29%; `VaultM6Module` 100% / 90.41%. The remaining uncovered branches are defensive guards that real pool keys cannot reach (zero tick spacing, fee of 100% or more, a missing executor, uint128/uint160 bounds) and the odd-sum rounding in `_currentCenter`, which only affects the `Rebalanced` event. |
| Mainnet fork at the pinned block (`FOUNDRY_PROFILE=fork`, `--fork-block-number 26246332`) | 32 passed, 0 failed, 0 skipped (5 suites). Under the old workflow profile the same command ran 0 tests and exited 0. |
| Gas snapshot | `.gas-snapshot` generated with the CI filter (428 deterministic tests); `forge snapshot --check --tolerance 1` passes |
| `forge build --sizes` | `Vault` 24,348 bytes (228 below EIP-170; it was 24,424 after the M7-01 fix and before M7-02). `VaultM5Module` 20,585; `VaultM6Module` 15,013; `NormalLPStrategy` 6,436; `BuyTheDipStrategy` and `SellThePumpStrategy` 4,524 each. |

New and changed tests:
- `test/attack/VaultM7RealV4Attacks.t.sol` (7 real-v4 tests);
- `test/invariant/VaultM7OneSidedInvariant.t.sol` (one invariant plus a sanity test);
- 17 unit tests across `Strategies.t.sol`, `Vault.t.sol` and `VaultM6.t.sol`.

`MockSwapExecutor` can now record the floor it receives and pull less than it was approved. The full-lifecycle invariant runs the production Normal LP strategy.

## Recheck (2026-10-23)

A further pass over M0 to M7 together: the full suite, the mainnet fork suite, every invariant suite under five new seeds, and new attacks on angles no earlier audit covered. Covered: dust first deposits, full exits, sandwiched first-deposit swaps, ERC-4626 inflation on one-sided vaults, and zero-tolerance rebalances.

| ID | Severity | Finding | Fix | Proof (fails before the fix) |
| --- | --- | --- | --- | --- |
| R-01 | Medium | **Small band liquidity blocked deposits and compounding.** A later pair deposit (and `compound`) sized its liquidity from the token amounts of the bands' stored liquidity. When that liquidity is small, those amounts are a few hundred raw USDC units per band and round down by up to one unit each. The overstated scale made the PositionManager pull more than the deposit's budget, so Permit2 reverted with `InsufficientAllowance`. It was reachable three ways: <ul><li>A first deposit of about $0.02 to $0.04 blocked every later pair deposit and every compound of a new vault, one-sided or Normal LP, until a rebalance re-minted the bands. Anyone can front-run a new vault's first deposit.</li><li>The same after every holder exits and only the dead shares remain.</li><li>Any deposit thousands of times larger than the vault's current value.</li></ul>No funds were at risk (the deposit reverts). The sizing dates from M4 and was copied into the M5 module for `compound`. | Size against a copy of the stored proportions scaled so the first band holds the first-deposit probe (`LIQUIDITY_PROBE * 10,000`). Rounding becomes negligible, the same as on the first-deposit path. There is now one implementation: `VaultM5Module.depositLiquidity` serves deposits through delegatecall and `compound` directly. `Vault` shrank from 24,348 to 24,209 bytes. | `test_a_dust_first_deposit_cannot_block_later_deposits` (one-sided, both pools), `test_a_dust_first_deposit_cannot_block_a_normal_lp_vault`, `test_compound_of_large_idle_funds_into_dust_bands`, `test_one_sided_vault_reopens_after_everyone_leaves_following_a_trail`, `testFuzz_any_later_deposit_size_settles_inside_its_budget`, and both production-strategy invariants (below). All fail with the old sizing. |
| R-02 | Info | **The invariant handlers swallowed deposit and compound failures** (`catch {}`), which is why the invariants never found R-01: a deposit failing inside Uniswap settlement looked like any other refused deposit. | The one-sided and full-lifecycle handlers fail on any deposit or compound error outside the expected set: pause, untrusted or reverting oracle, closed window or filled vault, unset or ETH-rejecting collector, sizes too small. The one-sided handler also deposits dust now. | Both invariants fail on the old sizing ("a deposit failed with an unexpected error") and pass on the fix |
| R-03 | Info (documented) | **A sandwiched first-deposit swap shifts a small amount from idle holders.** Deposits are priced at the trusted spot price (guide 6.4). A first deposit whose swap is front-run inside the oracle tolerance mints LP valued at the pushed price while earlier ERC-4626 holders keep idle token1; when the price returns they absorb their share of that revaluation. | None (design). Measured about 0.06% of the deposit with a 40-bp push, inside the documented in-tolerance sandwich bound (`deposit * m / (1 - m)`, about 1.01%). | `test_sandwiched_first_deposit_swap_stays_inside_the_documented_bound` |
| R-04 | Info | **ERC-4626 inflation on an empty one-sided vault** (smallest first deposit, then a donation). It loses money for every donation size. The victim loses at most one share's value to rounding (the documented M4 behaviour), and a deposit worth less than one share is refused. | None needed. | `testFuzz_erc4626_first_deposit_inflation_on_a_one_sided_vault_never_profits` |
| R-05 | Info (known behaviour) | **A swap-free re-anchor needs at least 1 bp.** Uniswap rounds each mint up by a wei or two per band, so a pure TRAIL re-anchor ends a few wei below its starting value, and the loss brake (no dust allowance) refuses it at `maxSlippageBps = 0`. | Keepers must pass at least 1 bp; documented. | `test_known_behaviour_a_swap_free_reanchor_needs_at_least_one_bp` |

Also restored: `docs/M2_AUDIT_REPORT.md`, `docs/M3_AUDIT_REPORT.md`, `docs/REAUDIT_M2_M3.md`, `docs/M4_AUDIT_REPORT.md` and `docs/M6_AUDIT_REPORT.md` were referenced by `docs/known-issues.md` but never committed. They were recovered unchanged from the sessions that wrote them.

Angles re-examined without a new defect:
- dust-vault rebalances (a vault holding only dust re-centres normally);
- deposits, compound and exits in filled and partially filled one-sided ladders;
- ERC-4626 conversions, rounding and gating in every state;
- the first-deposit valuation fix under a price push.

### Recheck verification

| Check | Result |
| --- | --- |
| `forge fmt --check`, SPDX/license step, `SrcPolicy` (NatSpec, no `///`) | pass |
| `forge test` (default profile) | 513 passed, 0 failed, 5 skipped (RPC-gated fork suites) |
| `forge test --profile ci` | 513 passed, 0 failed (47 suites) |
| Multi-seed (11, 222, 3333, 44444, full non-fork suite) | 513/513 per seed |
| Invariant suites under five new seeds (101, 2024, 31337, 777777, 9), before the fix | 29/29 per seed: none of them reached R-01, which led to R-02 |
| Mainnet fork (`FOUNDRY_PROFILE=fork`, latest block via PublicNode) | 32 passed, 0 failed |
| Mutants for R-01 (size against the raw stored liquidity again) | killed by the four R-01 tests, the fuzz property and both production-strategy invariants |
| Storage layout `Vault` / `VaultM5Module` / `VaultM6Module` | identical and unchanged (13 entries) |
| Slither 0.11.4 `--fail-high` | exit 0, no High results |
| Aderyn 0.6.8 | 0 High, 0 Low; the CI `grep` passes |
| Coverage (CI command, `src/` only) | 99.87% lines, 98.66% statements, 94.06% branches, 100% functions; every `src/` file at or above 90% branches |
| Gas snapshot | regenerated with the CI filter (434 deterministic tests); `--check --tolerance 1` passes |
| `forge build --sizes` | `Vault` 24,209 bytes (367 below EIP-170), `VaultM5Module` 20,988, `VaultM6Module` 15,013 |
