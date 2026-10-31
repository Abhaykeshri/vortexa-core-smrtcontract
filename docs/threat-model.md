# Threat Model

## M0-M10 scope

M0-M7 include the shared libraries, oracle guard, band generator, vault lifecycle, swap/rebalance modules, and the three approved production strategies. M8 adds the factory, fee collector, lens, governance deployment support, immutable deployment graph, and mainnet network configuration; M9 adds the Zap. M10 adds the security validation program and no new production protocol component. Final M11 deployment configuration, frontend/backend, monitoring, and operational controls remain outside this repository.

## Assets and trust boundaries

- Tick, sqrt-price, amount, and range inputs are untrusted.
- `CurrencyLib` may call an ERC-20 or send native ETH; the caller must enforce checks-effects-interactions and reentrancy protection.
- `PriceGuard` reads untrusted v4 pool state, Chainlink feed data, v3 TWAP observations, token metadata, and optional sequencer uptime data.
- The `PriceGuard` owner is trusted to configure correct feeds, bounds, TWAP pools, and deviation limits.
- Tick constants and liquidity results are validated against pinned Uniswap v4 test implementations.
- Production source must not import Uniswap source or test-only package aliases.
- Strategy outputs are untrusted even though the production strategies are immutable and stateless. Vault modules revalidate every safety-relevant plan field before fund movement.
- Keepers are trusted for liveness only. Their Normal LP center is bounded; one-sided strategies ignore it entirely.

## Controls

- Solidity compiler version is pinned to 0.8.26 and EVM target to Cancun.
- Full-precision multiplication/division and checked narrowing are used for liquidity math.
- Tick range and liquidity price-range errors revert; amount calculations round down.
- Oracle answers are checked for staleness, invalid sign/zero, configured min/max bounds, sequencer downtime/grace period, and max deviation.
- v3 fallback references require token-pair compatibility and a minimum TWAP window.
- CI scans all `src/**/*.sol` for exact compiler pragmas, allowed SPDX identifiers, and forbidden Uniswap imports.
- Git submodules are pinned to exact commits.

## Out of scope

Deployment keys and Safe signing policy, off-chain keeper infrastructure, private transaction relays, monitoring/alerting, frontend/backend behavior, third-party RPC availability, and an independent external audit remain out of scope. Production addresses intentionally left as `address(0)` in `NetworkConfigs.s.sol` must be populated from verified sources before deployment; they must never be sourced from environment variables.

## Attack catalogue coverage (oracle layer)

Scenario tests live in `test/attack/PriceGuardAttacks.t.sol`; stateful properties in `test/invariant/`.

| Attack (guide 12.4) | Result | Test |
| --- | --- | --- |
| Price manipulation beyond tolerance, then deposit | `isPriceTrusted` is false for every magnitude and direction | `test_flash_manipulation_beyond_tolerance_is_never_trusted` |
| Price manipulation within tolerance | Accepted; reported deviation never exceeds `maxDeviationBps` (documented residual risk) | `test_manipulation_within_tolerance_is_accepted_but_bounded` |
| Oracle stale, zero, negative or from the future | Not trusted, regardless of whether the pool agrees | `test_stale_oracle_blocks_trust_regardless_of_pool_agreement`, `test_zero_negative_and_future_answers_are_never_trusted` |
| Clamped feed during a crash | Rejected when `minAnswer` sits above the feed's clamp | `test_clamped_feed_answer_is_rejected_when_min_answer_sits_above_the_clamp` |
| Thin V3 fallback manipulated | TWAP shift is `floor(spike * seconds / window)`; fooled only while Chainlink is down (known issue) | `test_twap_manipulation_cost_scales_with_window`, `test_known_issue_fallback_can_be_fooled_only_while_chainlink_is_down` |
| L2 sequencer outage | Untrusted until the sequencer has been up for strictly more than 3,600 seconds | `test_sequencer_outage_timeline` |
| Stablecoin depeg | Only noticed beyond the tolerance (known limitation) | `test_stablecoin_depeg_is_only_noticed_beyond_the_tolerance` |
| Compromised or racing owner | Bounded by hard caps and the live-price check; cannot be front-run or hijacked | `test_compromised_owner_is_bounded_by_the_hard_caps`, `test_nobody_can_front_run_the_first_configuration`, `test_hijacking_a_pending_transfer_is_impossible` |
| Reentrancy through a reference contract that is also the owner | Blocked by the STATICCALL context, not by access control | `test_reference_contract_cannot_reenter_the_guard_during_validation` |
| Hostile or broken references (garbage data, reverting StateView, state-writing feed or token) | Never produce trust; configuration is rejected | `test_malformed_feed_response_never_yields_trust`, `test_state_view_failure_never_yields_trust`, `test_feed_cannot_write_state_during_validation_or_runtime`, `test_token_cannot_write_state_while_decimals_are_read` |
| Wrong `invertFeed`, wrong decimals | Rejected at configuration time | `test_wrong_invert_feed_flag_is_rejected_at_configuration`, `test_wrong_feed_decimals_are_rejected_at_configuration`, `test_inverted_feed_with_unequal_decimals_matches_pool` |

## Additional controls

- `PriceGuard` never holds ETH or tokens and rejects ETH sent to it.
- `isPriceTrusted` returns `(false, type(uint256).max)` for every degraded-oracle case, including a reference price that rounds to zero or lies outside the convertible range, and never divides by zero.
- Storage can only change through a successful owner call (`invariant_configuration_changes_only_through_successful_set_calls`).
- Shared type layouts (`PoolKey`, `PairConfig`, `VaultConfig`, `Band`, enum ordinals) are locked by `test/unit/TypesLayout.t.sol`.
- `test/unit/SrcPolicy.t.sol` fails the build if any `src/` file has a loose pragma, a wrong SPDX identifier, a forbidden Uniswap import, a revert string, `require`, `selfdestruct`, `tx.origin`, `delegatecall`, or missing/incomplete NatSpec.

## M3 `ShapeLibrary`

`ShapeLibrary` is pure: no storage, no owner, no external calls, no ETH, no way to be disabled. Its only risks are wrong output and cost.

| Threat | Control | Test |
| --- | --- | --- |
| Hostile inputs (negative or extreme widths, zero or absurd spacing, invalid shape id, centers anywhere in int24) | Documented errors only (`InvalidShape`, `InvalidInput`, `EmptyRange`), never a panic; arithmetic in `int256` and checked narrowing after the clamp | `testFuzz_matches_the_independent_specification`, `test_int24_extremes_for_every_shape_never_panic` |
| More than five bands or unbounded gas | Band count capped by the preset table; worst case measured under 50,000 gas for every input | `testFuzz_gas_stays_below_50000_for_any_input`, `test_adversarial_inputs_cannot_inflate_band_count_or_gas` |
| A malicious or buggy library address supplied to a vault | The vault re-checks count, weights, alignment, usable range and contiguity; the checker rejects gap, overlap, misalignment, out-of-range, too many bands, bad weights, empty and inverted bands, and bands carrying state | `test_the_recheck_rejects_every_kind_of_tampering` |
| One-sided strategies producing a range on the wrong side of the pool tick | Anchored ranges end exactly at (left only) or start exactly at (right only) the aligned anchor | `testFuzz_one_sided_ranges_stay_strictly_on_their_side_of_the_pool_tick` |
| Bands that overlap or leave gaps in Uniswap arithmetic | Per-band amounts at any price sum to the amounts of the whole range, within rounding | `testFuzz_band_amounts_add_up_to_the_whole_range` |
| Result depending on caller or block context | None: output depends only on arguments | `test_result_is_independent_of_caller_and_block_context`, `invariant_the_library_is_stateless_ether_free_and_unchanged` |

## Re-audit additions (M2/M3)

| Attack | Result | Test |
| --- | --- | --- |
| Pool id aliasing through dirty ABI words (high bits in a currency, fee, spacing or hooks word) or an unextended negative tick spacing | The decoder rejects them; they never alias a configured pool | `test_dirty_abi_words_in_the_pool_key_are_rejected_not_aliased`, `test_negative_tick_spacing_must_be_sign_extended`, `test_dirty_key_cannot_reconfigure_either` |
| Truncated or padded calldata | Truncated reverts; trailing bytes change nothing | `test_truncated_and_padded_calldata` |
| Hook moves the price between the trust check and the valuation | Exploitable (+50% credit) unless the consumer re-checks after the call | `test_stale_trust_across_an_external_call_is_exploitable_unless_rechecked` |
| Deposit sandwich within tolerance | Profit at most `deposit * m / (1 - m)` | `testFuzz_sandwich_profit_is_capped_by_the_deviation_limit`, `test_valuation_error_under_manipulation_is_bounded_by_the_guard_tolerance` |
| One pool's price or configuration affecting another | None | `testFuzz_one_pools_price_and_configuration_never_affect_another` |
| Feed upgrade changing decimals | Fails closed | `test_feed_decimals_change_fails_closed_until_the_owner_reconfigures` |
| Mis-set sequencer address | Fails closed (reverts), silently | `test_known_issue_sequencer_address_without_code_bricks_trust_checks_closed` |
| Gas cost of the trust check on the slowest path (sequencer, stale Chainlink, V3 fallback) | 61,874 gas | `test_worst_case_gas_of_the_trust_check` |
| Disagreement with real Uniswap v4 (pool id, `StateView` ABI, tick and liquidity maths, shape bands for every fee tier, preset and tick extreme, add/remove round trip, guard through real swaps) | None found | `test/integration/RealV4Integration.t.sol` |

## M4 vault

All tests below run against the real Uniswap v4 PoolManager, PositionManager and StateView deployed in-process, unless noted.

| Attack or failure | Result | Test |
| --- | --- | --- |
| Deposits after fees accrue (fee credit exceeds what the deposit owes) | Deposits keep working; existing holders keep their fees | `test_deposits_keep_working_after_fees_accrue_and_fees_stay_with_existing_holders`, `test_erc20_pool_deposits_keep_working_after_fees_accrue` |
| ETH forced into the PositionManager and swept to the vault | Native deposits keep working; the surplus is a donation | `test_forced_eth_in_the_position_manager_cannot_block_native_deposits` |
| Redeem at a manipulated spot price | Refused unless PriceGuard trusts the price; bounded by the tolerance otherwise | `test_redeem_at_a_manipulated_spot_price_cannot_take_other_holders_funds`, `test_priced_exits_close_while_the_oracle_is_stale` |
| Token hook moves the price between the oracle check and the mint | Reverts with `PriceMovedDuringDeposit` | `test_a_token_hook_cannot_move_the_price_between_the_check_and_the_mint` |
| Token hook inside settlement re-enters or swaps | Re-entry and nested swaps fail; price unchanged | `test_a_hook_inside_settlement_cannot_reenter_the_vault_or_move_the_price` |
| Foreign NFT pushed into the vault | Rejected with `UnexpectedNft` | `test_a_foreign_position_nft_cannot_be_pushed_into_the_vault` |
| Tampered strategy/shape output (gap, overlap, misalignment, out of range, too many bands, bad weights, empty or inverted bands) | Rejected as `InvalidPlan` before PositionManager interaction | `test_tampered_library_output_is_rejected_before_any_token_moves` |
| PositionManager mints a band NFT to someone else | Reverts with `InvalidPositionOwner` | `test_first_deposit_reverts_if_a_band_nft_is_not_owned_by_the_vault` |
| Settlement round-up exceeding the exact Permit2 allowance | Never happens for any deposit size | `testFuzz_deposit_sizes_never_fail_inside_uniswap_settlement` |
| First-depositor inflation | Attacker never profits | `test_first_depositor_inflation_never_profits` |
| Reentrant refund receiver | Re-entry fails | `test_a_reentrant_refund_receiver_cannot_reenter` |
| Pause by a stranger, unpause by the guardian | Refused; withdrawals stay open while paused | `test_only_guardian_or_factory_can_pause_and_only_timelock_or_factory_can_unpause`, `test_pause_blocks_both_deposit_paths_but_never_withdrawals` |
| ERC-4626 conformance (`maxDeposit` honest, previews exact, `max*` never revert) | Holds | `test/integration/VaultErc4626RealV4.t.sol` |
| Stateful: overpaid depositors, NFT ownership and real liquidity, PositionManager leftovers, standing Permit2 allowances, config immutability, share conservation, unauthorized pause | All hold over random sequences | `test/invariant/VaultRealV4Invariant.t.sol` |

## M5 withdraw, fees and views

All tests run against the real Uniswap v4 PoolManager, PositionManager and StateView in-process.

| Attack or failure | Result | Test |
| --- | --- | --- |
| Fee collector rejects ETH, is blacklisted by the token, returns `false`, burns gas, or is unset; factory reverts | Withdrawals still complete; the undeliverable fee stays with the holders and is reported | `test_withdraw_survives_*`, `test_a_false_returning_fee_transfer_is_reported_as_forfeited`, `test_forfeited_protocol_fee_is_reported` |
| No-band vault withdrawal touching anything but token transfers | No factory, oracle, StateView or PositionManager call | `test_no_band_withdraw_makes_no_call_except_token_transfers` |
| Withdraw while paused, oracle reverting, no keeper ever | Works | `test_withdraw_works_when_paused_and_the_oracle_reverts` |
| Deposit or compound sweeping pending fees past the protocol | Protocol cut paid exactly on every fee-collecting path | `test_deposit_pays_the_protocol_fee_on_the_fees_it_sweeps`, `test_compound_pays_the_protocol_fee_on_the_fees_it_sweeps`, `test_erc20_lifecycle_pays_exact_protocol_fees_and_leaves_nothing_behind` |
| Factory fee above 100 percent, malformed collector word, fee getter returning no data | Fee clamped at 100 percent of fees (principal untouched); malformed collector treated as unset; missing fee data treated as zero | `test_a_protocol_fee_above_100_percent_is_clamped`, `test_a_malformed_fee_collector_reads_as_unset`, `test_a_factory_returning_no_fee_data_reads_as_zero_fee` |
| In-kind preview differing from the real withdrawal (UI sandwich surface) | Equal to the wei, also under a broken collector and any fee | `test_previewWithdrawPair_*`, `testFuzz_previewWithdrawPair_matches_the_real_withdrawal` |
| ERC-4626 exit by a spender without allowance | Refused; allowance spent exactly | `test_erc4626_exits_by_a_spender_require_and_spend_allowance` |
| Compound when fee credits exceed what it spends | Works; exact balance identity | `test_compound_does_not_revert_when_swept_fees_exceed_what_it_spends` |
| Exit-route arbitrage (ERC-4626 redeem vs pair withdraw) to dodge the protocol fee | Redeem pays no more than the pair exit | `test_erc4626_redeem_cannot_dodge_the_protocol_fee` |
| Read-only reentrancy through the native leg of a withdrawal or refund | Receiver sees final state | `test_native_withdraw_receiver_sees_the_final_share_price`, `test_native_deposit_refund_receiver_sees_the_final_share_price` |
| Re-entrant native receiver | Re-entry fails | `test_a_reentrant_native_receiver_cannot_reenter` |
| Direct calls into the delegatecall module | Refused | `test_the_m5_module_refuses_direct_calls` |
| Stateful (256 runs x depth 64): random deposits, withdrawals, redemptions, swaps, collections, compounds, fee changes above the cap, pause, oracle outage, broken collectors | Every holder can always exit; exits never exceed `totalAssets` (plus any forfeited fee); every withdrawal pays the reported share value; collector receives exactly `feeBps` of every collected fee; NFTs, liquidity, Permit2 and PositionManager custody stay clean | `test/invariant/VaultM5RealV4Invariant.t.sol` |

## M6 swap executor and rebalance

All tests run against the real Uniswap v4 PoolManager, PositionManager, StateView, PriceGuard and ShapeLibrary in-process, with swaps through the real v4 `V4Router` action pipeline behind a Universal Router double (`test/integration/utils/UniversalRouterDouble.sol`), plus mainnet fork tests against the deployed Universal Router.

| Attack or failure | Result | Test |
| --- | --- | --- |
| Rebalance swap on an ERC-20/ERC-20 pool (router parameter layout) | Works on the real decoder and on the mainnet router; the old encoding reverted | `test_erc20_pool_rebalance_with_a_swap`, `test/fork/SwapExecutorErc20PoolFork.t.sol` |
| 1-wei donation to the executor to block a token's swaps | No effect; the donation is never spent | `test_a_donation_to_the_executor_cannot_block_rebalances`, `test_unsolicited_erc20_is_never_spent_and_never_blocks_swaps` |
| Sandwich within the oracle tolerance, both directions | Loss at the oracle price within the keeper tolerance (measured 9 bps of a 100 bps bound); large adverse pushes are refused by the swap floor | `test_sandwiched_rebalance_loss_is_bounded_price_pushed_down`, `..._up` |
| Non-keeper, paused, auto-rebalance off, cooldown, stale oracle, pool beyond tolerance, center more than 200 ticks away, tolerance above 1%, no trigger | Each reverts with its own error; boundary at exactly 200 ticks | `test_rebalance_gates_revert_with_the_right_errors`, `test_center_drift_boundary_is_exactly_200_ticks`, `test_rebalance_reverts_when_auto_rebalance_is_off` |
| Hostile strategy plans: overlapping, misaligned or out-of-range bands, bad or zero weights, lock-idle on Normal LP, zero swap, swap above 60% of value or above holdings, one-sided band crossing the price | Refused before any token moves; old positions intact | `test_hostile_plans_are_rejected_atomically`, `test_one_sided_plan_must_stay_on_its_side_of_the_price` |
| Lock-idle path | No bands, `filled`, loss brake applied, withdrawals open, deposits refused, re-entry clears `filled` | `test_lock_idle_leaves_idle_tokens_no_bands_filled_and_withdrawals_open` |
| Protocol fee on the rebalance's burn; fee above 100%; empty factory answer; unset collector | Exact; clamped; zero; whole rebalance reverts atomically | `test_rebalance_pays_exactly_the_protocol_fee_on_collected_fees`, `test_a_factory_fee_above_100_percent_is_clamped_in_rebalance`, `test_a_factory_returning_no_fee_data_charges_no_rebalance_fee`, `test_rebalance_with_an_unset_collector_reverts_atomically` |
| ETH forced into the PositionManager or the executor | Swept to the vault / not counted as swap output | `test_forced_eth_cannot_block_or_inflate_a_native_rebalance` |
| Accounting after a rebalance | Preview equals withdrawal to the wei; every holder exits | `test_after_a_rebalance_previews_exits_and_deposits_stay_exact` |
| Stateful (256 runs x depth 64): deposits, withdrawals, attacker pushes, trends, hostile rebalances, collections, compounds, fee changes | Protocol fee exact, loss within tolerance, cooldown respected, every holder exits, no orphaned NFT, no tokens or allowances left in the PositionManager, executor or router | `test/invariant/VaultM6RealV4Invariant.t.sol` |

## M7 strategies

| Threat | Control | Test |
| --- | --- | --- |
| Negative-tick truncation places a range on the wrong side | Mathematical signed floor/ceiling helpers; 100,000-case fuzz property | `testFuzz_roundingProperties100k`, `test_negativeTickRoundingExactBoundaries` |
| Wrong strategy/config pairing or irrelevant fields | Initialization-time `validateConfig`; strict shape, width, drift, trail, lock, and strategy checks | `test_validateConfigRejectsInvalidStrategyFields` |
| Base-token orientation selects the wrong deposit asset | Shared orientation identity and explicit below/above token rules | `test_oneSidedModesBothStrategiesAndOrientations` |
| Off-by-one trigger at range, drift, trail, or fill boundary | Exact boundary vectors for both directions | `test_normalTriggerBoundaries`, `test_belowRangeDepositAndTriggerBoundaries`, `test_aboveRangeDepositAndTriggerBoundaries` |
| Keeper controls a one-sided center | One-sided plans ignore keeper center and anchor only from current tick | `test_oneSidedPlanIgnoresKeeperCenterAndLocksOnFill` |
| Strategy returns stateful, malformed, wrong-side, zero-weight, locking, or invalid-swap first-deposit data | Independent module validation before PositionManager interaction | `test_tampered_library_output_is_rejected_before_any_token_moves`, M6 hostile-plan tests |
| Callback during burn changes the planning price/tick | Pool state and PriceGuard trust refreshed after burn/fee callbacks | M6 real-v4 attack and invariant suites |
| Production strategies fail against native or ERC-20 settlement | Real PoolManager/PositionManager integration tests | `test/integration/M7StrategiesRealV4.t.sol` |
| First-deposit swap cost (fee, impact, sandwich within the oracle floor) charged to idle holders | Depositor credited `min(net supplied value, measured value added)` at the pre-deposit price (M7-01) | `test_first_band_deposit_swap_cost_is_not_charged_to_existing_holders`, `testFuzz_pair_deposit_shares_are_exactly_the_floor` |
| Hostile first-deposit plan: lock-idle, one-sided swap, swap above the supplied input, inconsistent swap flags, six bands, zero weight, a band one tick across the price | `VaultM5Module.depositPlan` validator, before any token leaves the vault | `test_firstDepositRejects*`, `test_firstDepositOneSidedBoundaryIsExact` |
| Executor keeps an allowance, gets a loose output floor, or the swap output is stranded | Exact approve and revoke; floor = reference output less pool fee less 1%; output joins the deposit budget | `test_firstDepositSwap*UsesTheOracleFloorRevokesAndDeploysTheOutput` |
| Vault initialized with a strategy of another kind or an invalid ladder | `initialize` delegates `validateStrategy` at the live tick | `test_initializeValidatesTheConfigurationThroughTheStrategy`, `test_oneSidedConfig*`, `test_normalConfigRejectsAZeroWidthOnEitherSide` |
| One-sided ladder minted across the price, swapping, or reopening deposits after a fill under random sequences | Strategy anchoring plus module and M6 validation | `invariant_one_sided_rules_and_custody` (both orientations, native and ERC-20) |
| Normal LP swap sized short of the shortfall or above holdings | Buy-side ceil rounding, fee gross-up, holding caps | `testFuzz_normalSwapCoversTheShortfallAfterTheFee` |
| A dust first deposit (or a full exit, or a very large deposit) makes later deposits and compounds pull more than their budget | Existing-band sizing on a probe-scaled copy of the stored proportions, one implementation for deposits and compound (recheck R-01) | `test_a_dust_first_deposit_cannot_block_*`, `test_compound_of_large_idle_funds_into_dust_bands`, `testFuzz_any_later_deposit_size_settles_inside_its_budget`, the invariants' unexpected-failure checks |
| Sandwich around a first-deposit swap inside the oracle tolerance | Spot valuation behind PriceGuard; bounded by the documented `deposit * m / (1 - m)` (measured about 0.06%) | `test_sandwiched_first_deposit_swap_stays_inside_the_documented_bound` |
| ERC-4626 first-deposit inflation on a one-sided vault | Dead shares and the 10,000-unit minimum; deposits worth less than one share are refused | `testFuzz_erc4626_first_deposit_inflation_on_a_one_sided_vault_never_profits` |

## M8 control plane

| Threat | Control | Test |
| --- | --- | --- |
| Clone initialized by an attacker or twice | Implementation is locked; initializer accepts only the immutable factory and only once | `test_factoryCreatesPredictedCloneAndNormalizesConfig` plus existing Vault initialization tests |
| Address collision/front-running | Salt includes creator and normalized full identity; prediction fuzz checks creator separation | `testFuzz_predictionIsCreatorSpecific` |
| Failed initialization leaves a registered or unusable address | Registry write follows successful initialization; transaction rollback preserves retryability | `test_failedStrategyValidationCannotRegisterOrConsumeCloneAddress` |
| Malformed pool/config enters registry | Hookless allowlist, initialization, oracle/trust, shape, sorted/aligned/bounded geometry, cap and strategy checks | `test_factoryRejectsCreationPolicyFailures`, `test_factoryRejectsHooksMissingOracleStrategyAndBadShape` |
| Future implementation swaps custody/oracle dependencies | Factory strictly reads and compares implementation/executor immutable identities | `test_feeKeeperGuardianAndImplementationAdministration`, deployment script tests |
| Registry update mutates an existing vault | Strategy/config/implementation are clone-local and write-once | `test_existingVaultIsUnaffectedByRegistryAndImplementationPolicyChanges` |
| Guardian resumes or moves funds | Guardian is recognized only by Vault's pause path; owner/timelock alone unpauses | `test_guardianCanOnlyPauseAndOwnerCanUnpause` |
| Open timelock execution or instant takeover | Restricted executor, 48-hour mainnet floor, two-step ownership, deployer admin removal | M8 unit and script timelock tests |
| Fee flush theft or native reentrancy | Caller never selects recipient; full balance goes to fixed treasury under `nonReentrant` | FeeCollector unit and reentrancy tests |
| Dashboard batch DoS or ambiguous zero accounting | 50-vault bound and explicit availability flags | Lens unit/failure tests |

## M8 audit additions

| Threat | Control | Test |
| --- | --- | --- |
| Deployer keeps or grants itself a role during the pre-handover window | `PostDeployM8Check` requires a recorded deployer with no Timelock role, no keeper/guardian/treasury role, no pending ownership transfer and the configured pool rule | `test_postDeployCheckRequiresTheHandoverAndAnInertDeployer` |
| Production graph deployed without the Zap (immutable in the executor, executor pinned by the factory) | `DeployM8` refuses mainnet without a Zap; production deploys through M11 | `test_mainnetDeploymentRequiresTheZap` |
| Governance reaches into existing vaults | Vaults read only the live keeper/guardian/fee/collector/owner getters; config, strategy and clone target are immutable | `invariant_governanceNeverRewritesAnExistingVault`, `test_governance_reaches_existing_vaults_only_through_the_live_getters` |
| Any role calls an entry point it should not | Role matrix over owner, guardian, keeper and user | `test_roleMatrix` |
| Implementation or executor substitution | Every dependency and the executor's factory/guard/module links are compared through strict getter decoding | `test_setImplementationRejectsEachDependencyChange`, `test_constructorRejectsAnExecutorBoundElsewhere`, `test_getterDecodingIsStrict` |
| Factory-created vaults fail against real settlement, fees or the executor registry | Real-v4 lifecycles through the real factory, collector and lens | `test/integration/M8FactoryRealV4.t.sol` |

## M9 Zap

| Threat | Control | Test |
| --- | --- | --- |
| Hostile router or crafted calldata drains approvals | No caller-supplied target or calldata; the only swap path is the immutable SwapExecutor on the vault's own pool | `test_unauthorizedCallerCannotUseExecutor`, every Zap test (no other path exists) |
| Fake, foreign-wired or unpinned vault | `factory.isVault`, the vault's factory/executor/PriceGuard and the executor's factory must match the Zap's; the strategy contract must be the one pinned for its kind | `test_unknownVaultAndBadTokenRevert`, `test_zapRefusesARegisteredVaultWithForeignWiring`, `test_zapDepositRejectsMismatchedStrategyContracts`, `test_strategyIdentityCannotDivergeSilently` |
| Wrong token, native value mismatch, slippage above the cap, self or zero receiver, zero amount | Validated before any funds move | `test_zeroAmountAndReceiverValidation`, `test_slippageAndNativeValueValidation` |
| Fee-on-transfer or rebasing input | Balance-delta pull | `test_feeOnTransferStyleShortfallReverts` |
| Donated dust paid to the next caller or used to subsidize a deposit | Pre-call balance snapshots; refunds and deposits use call-local balances only; balances must return exactly to the snapshot | `test_forcedDustCannotBeStolenOrUsedToSubsidizeDeposit`, `test_balance_change_during_the_refund_aborts_the_zap`, both Zap invariants |
| Standing allowances | Exact approvals revoked by the Zap itself, even when the vault or executor pulls less | `test_zap_checks_the_vault_result_and_revokes_unused_allowances`, `test_zap_checks_the_executor_output_and_revokes_its_allowance`, invariants |
| Executor or vault misreports | Swap output measured by balance delta; vault shares and used amounts checked | the two defence-in-depth tests above |
| Reentrancy through a refund or token hook | `nonReentrant` on the Zap and the vault; ETH accepted only from the executor and registered vaults | `test_reentrantNativeRefundReceiverCannotEnterZap`, `test_zapRefusesEthFromAnyoneButTheExecutorOrAVault` |
| Sandwich around the zap's swap | Executor oracle floor at the caller's tolerance, the vault's PriceGuard check, and `minShares`; loss bounded by about `maxDeviationBps + maxSlippageBps` | `test_sandwiched_zap_stays_inside_the_documented_bound` (in-process), `test_realPoolSandwichedZapStaysInsideTheConfiguredBound` (mainnet fork), `test_callerSlippageToleranceIsEnforced` |
| Zapper over-credited, or existing holders pay for the zap | Shares come from the vault's own deposit valuation | `testFuzz_zap_value_is_fair_for_the_zapper_and_existing_holders`, `invariant_zap_is_fair_and_keeps_nothing` |
| Quote promises more than the zap mints (a `minShares` set from it reverts) | Floor-valued swap, per-band rounding reserves, 1 ppm margin | `testFuzz_quote_never_exceeds_the_executed_zap`, `testFuzz_dust_quote_never_exceeds_the_executed_zap`, `test_one_sided_first_quote_mirrors_the_strategy_anchor_on_a_tick_boundary` |
| Dust-sized or dead-shares vault skews the split | Ratio from a probe-scaled copy of the bands' liquidity | `test_zap_split_on_a_dust_sized_vault_matches_a_normal_vault` |
| Mis-wired deployment | `DeployM9` address and code checks; `PostDeployM9Check` names each broken link | `test_deployM9ResolvesAndVerifiesCompleteImmutableGraph`, `test_postDeployM9NamesEveryMiswiredLink` |
