# M5 Audit Report: withdraw, fees and views

Date: 2026-10-14. Branch `milestone/M5` at `951e8f5` plus the working-tree fixes described here.

Scope: `src/VaultM5Module.sol` (new), the M5 changes to `src/Vault.sol`, `src/interfaces/{IVault,IVaultFactory,IFeeCollector,IStrategy}.sol`, and the M5 behaviour end to end against the real Uniswap v4 `PoolManager`, `PositionManager` and `StateView` (in-process), checked against guide sections 7.1 to 7.4, 10.1 to 10.3, 12.2 (invariants) and 13.3 (parameters).

## Verdict

All findings below are fixed and pinned by tests that fail on the original M5 code. The full suite, the guide's M5 invariant (256 runs, depth 64), the mutation round, Slither and the coverage gates are reported at the end. `Vault` is under EIP-170 (see the size note).

The root-level `M5_SECURITY_AUDIT_REPORT.md` listed "withdrawal safety: `withdrawPair` does not depend on pause, oracle trust or keeper availability" and "fee/principal separation" as verified. Neither held in all cases: the withdrawal depended on the factory and the fee collector (M5-01), and the protocol fee was skipped on two of the four fee-collecting paths (M5-03, M5-04). That report is superseded by this one.

## Findings

| ID | Severity | Finding | Fix | Proof (fails before the fix) |
| --- | --- | --- | --- | --- |
| M5-01 | High | **Withdrawals depended on the factory and the fee collector** (guide 7.2 rule 1, 7.4 "no function that holds user funds may depend on..."). `withdrawPair` sent the protocol fee with a reverting transfer and reverted on a zero collector, so a collector that rejects ETH, a collector blacklisted by USDC (USDC can freeze any address), an unset collector, a gas-burning collector, or a reverting factory read froze every withdrawal from every vault with pending fees. | The payout always uses the owed fee `floor(F * bps / 10_000)` (guide formula). Delivery is best-effort: native ETH with a 100,000-gas stipend and no return-data copy, ERC-20 through a raw `transfer` that accepts `true` or no return data. Factory reads are raw `staticcall`s that read as zero on revert or malformed data. Undeliverable fees stay in the vault for the remaining holders and `ProtocolFeeForfeited` is emitted. | `test_withdraw_survives_a_fee_collector_that_rejects_eth`, `..._blacklisted_by_the_token`, `..._an_unset_fee_collector`, `..._a_gas_burning_fee_collector`, `..._a_reverting_factory`; invariant `invariant_every_holder_can_exit_and_exits_never_exceed_total_assets` with the `setCollector` action |
| M5-02 | Medium | **No-band withdrawal made external calls** other than token transfers (guide 7.2 edge cases): the factory's fee was read even with nothing to charge. | The factory is read only when pending fees are non-zero. | `test_no_band_withdraw_makes_no_call_except_token_transfers` |
| M5-03 | Medium | **Deposits cancelled the protocol fee.** Adding liquidity credits each band's accrued fees into the deposit's settlement; the vault kept them without the protocol cut (guide invariant 7: the collector's balance change must equal `feeBps` of collected fees exactly). Any deposit, even a dust one, wiped the protocol's share of all pending fees. | The deposit computes the credited fees before the call (it already did, for its cost measurement) and pays their protocol cut through the module (`payDepositProtocolFee`). | `test_deposit_pays_the_protocol_fee_on_the_fees_it_sweeps`, `invariant_protocol_fee_is_exactly_fee_bps_of_collected_fees` |
| M5-04 | Medium | **Compound cancelled the protocol fee** the same way, on every keeper run. | Compound measures the credited fees before the call and pays their cut afterwards. | `test_compound_pays_the_protocol_fee_on_the_fees_it_sweeps` |
| M5-05 | Medium | **Compound reverted (arithmetic underflow)** when the fees credited by INCREASE_LIQUIDITY exceeded what it spent in a currency: CLOSE_CURRENCY paid the surplus to the vault and `used = budget - balanceAfter` underflowed. The keeper could not compound in that state. | `used = clamp(idle + creditedFees - balanceAfter, 0, idle)`, as for deposits. | `test_compound_does_not_revert_when_swept_fees_exceed_what_it_spends` (exact balance identity) |
| M5-06 | Medium | **No protocol-fee bound in the vault.** The vault trusted any factory value; with a value above 100% `collectFees` sent the collector more than the fees (principal) or reverted, and `withdrawPair` underflowed (lock-up). A malformed collector word would also have been truncated to an arbitrary address. | Clamp at 100% of collected fees on every path, in valuation and in the preview (the business cap is mutable factory state by team decision, so the vault does not impose the guide's 2,500); treat malformed or missing factory answers as zero fee / unset collector. | `test_a_protocol_fee_above_100_percent_is_clamped`, `test_a_malformed_fee_collector_reads_as_unset`, `test_a_factory_returning_no_fee_data_reads_as_zero_fee` |
| M5-07 | Medium | **Pending fees were valued gross but paid out net.** `totalAssets` (and deposits, previews and ERC-4626 exits priced from it) counted the protocol's cut as holder value. A pair withdrawal paid less than the reported share value, and an ERC-4626 `redeem` paid the gross value, letting a holder dodge the protocol fee on their share of pending fees at the remaining holders' expense. | `totalAssets` counts `F - floor(F * bps / 10_000)`, summed across bands first, with the same clamped, non-reverting fee read as the module. | `test_pair_payout_equals_the_reported_share_value`, `test_erc4626_redeem_cannot_dodge_the_protocol_fee`, `test_two_users_entering_at_different_times_exit_pro_rata`, `invariant_withdrawals_pay_the_reported_share_value` |
| M5-08 | Low | **Read-only reentrancy through the native leg.** `withdrawPair` and the deposit refund sent ETH first; a contract receiver saw `totalAssets` with the ERC-20 leg still in the vault (an inflated share price) and could mislead an integrator reading it. | Pay the currency1 (ERC-20) leg first and the native leg last. | `test_native_withdraw_receiver_sees_the_final_share_price`, `test_native_deposit_refund_receiver_sees_the_final_share_price` |
| M5-09 | Low | **`checkRebalance` had no cooldown gate** (guide 7.4: "adds cooldown and PriceGuard checks"). | Reports `COOLDOWN` within 30 minutes of `lastRebalance` (guide 13.3), before the PriceGuard and strategy checks. | `test_checkRebalance_reports_cooldown_pause_and_auto_off` |
| M5-10 | Low | **Empty bands would make withdraw and collect revert.** Both issued DECREASE_LIQUIDITY on every band; Uniswap reverts (`CannotUpdateEmptyPosition`) on modifying a position with zero liquidity. Not reachable in M5 (locked shares keep every band non-empty), but milestone 6 burns and re-mints bands. | Encode only bands with stored liquidity; skip the call when no band qualifies. | `test_collectFees_without_bands_is_a_no_op`, mutant M24 |
| M5-11 | Low | **No in-kind withdrawal preview** (guide 7.4 previews "to the wei", 10.3 lens `userPosition`). | `VaultM5Module.previewWithdrawPair(vault, shares)` with the same arithmetic as `withdrawPair` from StateView reads only; `Vault.m5Module()` exposes the module address. | `test_previewWithdrawPair_matches_the_real_withdrawal_to_the_wei`, `test_previewWithdrawPair_is_exact_on_the_native_pool_and_with_a_broken_collector`, `testFuzz_previewWithdrawPair_matches_the_real_withdrawal` |
| M5-12 | Info | The delegatecall module accepted direct calls (they ran against its own empty storage, so nothing was at risk). | `onlyDelegated` on every state-changing entry point. | `test_the_m5_module_refuses_direct_calls` |
| M5-13 | Info | 266 `///` NatSpec lines were reintroduced in `src/` (project rule: `/** */` only). `PermitAmountTooLarge` (raised by the module) was missing from the `Vault` ABI. | Converted; error declared on `Vault`. | `SrcPolicy` |
| M5-14 | Info | ERC-4626 `withdraw`/`redeem` by a spender (owner != caller) had no test, so removing the allowance check survived mutation. Not a code defect. | Test added. | `test_erc4626_exits_by_a_spender_require_and_spend_allowance` |

### Found while fixing

My first version of the non-reverting factory read was `if and(staticcall(...), gt(returndatasize(), 0x1f))`. Yul evaluates arguments right to left, so `returndatasize()` was read before the call and reflected the previous call in the frame. It worked by accident wherever an earlier call returned 32 bytes, and silently returned a zero fee at the start of a fresh delegatecall frame (the deposit fee path). `test_deposit_pays_the_protocol_fee_on_the_fees_it_sweeps` caught it; the call and the size check are now separate statements, and mutants M14 and V05 pin both copies.

## Design of the fee paths after the fix

| Path | Fee basis | Collector failure |
| --- | --- | --- |
| `withdrawPair` | all pending fees `F` it collects | best-effort; fee stays with holders, `ProtocolFeeForfeited` |
| `collectFees` | measured collected fees | reverts (fees stay in the positions) |
| `compound` | fees its INCREASE credits | reverts |
| `depositPair` | fees its INCREASE credits | reverts |
| valuation (`totalAssets`) | pending `F`, net of the cut | n/a |

Effective fee everywhere: `min(factory.protocolFeeBps(), 10,000)`, zero if the factory reverts or returns malformed data. The guide's 2,500 cap is replaced by mutable factory state by team decision (`IVaultFactory`); the vault enforces only the 100 percent safety bound.

## Verification

| Check | Result |
| --- | --- |
| `forge fmt --check` | pass |
| `forge test` (default profile) | 361 passed, 0 failed, 2 skipped (RPC-gated fork tests) |
| `FOUNDRY_PROFILE=ci forge test` (10,000 fuzz runs) | 352 passed, 0 failed |
| M5 invariant `test/invariant/VaultM5RealV4Invariant.t.sol` | 256 runs x depth 64 (16,384 calls), 5 invariants hold; against the original M5 code it fails fee exactness, no lock-up, and withdrawal pricing |
| Multi-seed fuzz (seeds 11, 222, 3333, 44444) over all vault attack, integration, invariant and fuzz suites | 76/76 per seed |
| Preview fuzz at 3,000 runs | pass (wei-exact) |
| Mutation round 1 (32 mutants on the module and the Vault M5 changes) | 29 killed; 3 survivors (malformed collector word, Yul order in the Vault fee read, ERC-4626 spender allowance) were test gaps, now closed |
| Mutation round 2 (14 mutants: the 3 survivors, the 100% clamp, the preview, the refactored entry points) | 14 killed |
| Storage layout `Vault` vs `VaultM5Module` (`forge inspect ... storage-layout`) | identical, slot and offset |
| Slither (`--filter-paths "lib|test|script"`) | no new true positive. High: `uninitialized-state` x3 (the module's storage mirrors, written by the vault; by design) and `reentrancy-eth` in `_depositPair` (the documented M4 read-only window; every state-changing function is `nonReentrant`). Medium: default-zero locals and partially used tuples. No `controlled-delegatecall` or `arbitrary-send-eth`. |
| Coverage (`forge coverage`, fork tests excluded) | `Vault` 100% lines / 91.47% branches; `VaultM5Module` 100% / 97.33%; total 96.21% / 92.96%. Remaining uncovered `Vault` branches are defensive guards behind earlier checks (uint160 Permit2 bound behind the uint128 casts, `_used` cap, `_mint` to zero, `mint` slippage) |
| `forge build --sizes` | `Vault` 24,138 bytes (EIP-170 limit 24,576); `VaultM5Module` 16,720 bytes |

New tests: `test/attack/VaultM5RealV4Attacks.t.sol` (23), `test/integration/VaultM5LifecycleRealV4.t.sol` (17), `test/invariant/VaultM5RealV4Invariant.t.sol` (5 invariants plus a sanity test), and 10 unit tests in `test/unit/Vault.t.sol`. The real-v4 fixture (`test/integration/utils/VaultRealV4Base.sol`) now also plays the factory's fee and keeper roles (`protocolFeeBps`, `feeCollector`, `isKeeper`, and a switch that makes the reads revert); before this audit no real-v4 test exercised `withdrawPair`, `collectFees` or `compound` at all.

## Size

`Vault` runtime 24,138 of 24,576 bytes (438 bytes of headroom, up from 15 before the audit); `VaultM5Module` 16,720 bytes. The headroom comes from forwarding `msg.data` to module functions of identical signature (the module reads the vault's immutables back through its getters instead of receiving them encoded), passing only `(this, strategy)` to `checkRebalance`, deduplicating the ERC-4626 exit tail, and a raw `staticcall` for the fee read. Milestone 6 must place the rebalance in a module.
