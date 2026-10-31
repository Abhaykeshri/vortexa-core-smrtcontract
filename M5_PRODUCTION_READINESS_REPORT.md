# M5 Production Readiness Report

Audit date: 2026-10-13
Branch audited: `milestone/M5`
Scope: read-only production readiness audit of M0-M5 code, tests, deployment surface, and M5 reports.

## Final Verdict

**NOT PRODUCTION READY**

The M5 branch has strong local and mainnet-fork test results, and the implemented M5 behavior largely matches the confirmed M5 milestone requirements. However, production readiness is not proven because production M8 Factory/FeeCollector deployment is intentionally absent, local end-to-end deployment through a production Factory is not available, independent static analysis tools were not installed, `VaultM5Module.sol` branch coverage remains low at 48.89%, and one M5 invariant suite overrides the required 256 runs / depth 64 setting below the requested minimum.

## Command Evidence

| Command | Result |
| --- | --- |
| `git status --short --branch` | On `milestone/M5`; tracked tree clean, with pre-existing untracked `.gas-snapshot`, `M5_CONFLICT_DETAILS.txt`, `testing-logs/`, and `lib/v4-core` status. |
| `forge fmt --check` | PASS, exit 0. |
| `forge test --match-path "test/unit/*" -vv` | PASS: 165 passed, 0 failed, 0 skipped. |
| `forge test --match-path "test/integration/*" -vv` | PASS: 13 passed, 0 failed, 0 skipped. |
| `forge test --match-path "test/attack/*" -vv` | PASS: 53 passed, 0 failed, 0 skipped. |
| `forge test -vv` | PASS: 308 passed, 0 failed, 2 skipped. Skips are fork-only under local chain. |
| `forge test --profile ci -vv` | PASS: 308 passed, 0 failed, 0 skipped. Fork tests are excluded by CI profile. |
| `forge test --match-path test/fork/* --fork-url https://ethereum.publicnode.com -vv` | PASS: 15 passed, 0 failed, 0 skipped. Real Ethereum mainnet fork tests executed. |
| `forge coverage --summary` | PASS: total 95.58% lines, 95.31% statements, 88.47% branches, 92.12% functions. Output saved to `testing-logs/M5_PRODUCTION_COVERAGE.txt`. |
| `forge inspect src/Vault.sol:Vault bytecode` | Vault initcode 37,266 bytes, runtime 24,576 bytes. |
| `forge inspect src/VaultM5Module.sol:VaultM5Module bytecode` | Module initcode 11,798 bytes, runtime 11,770 bytes. |
| `slither --version` | NOT VERIFIED: command not found. |
| `aderyn --version` | NOT VERIFIED: command not found. |
| Local Anvil deployment via `script/DeployPriceGuard.s.sol` | FAIL/NOT VERIFIED: script reverted with `UnsupportedNetwork(31337)` from `NetworkConfig::getConfigs()`. |

## Acceptance Criteria Matrix

| Requirement | Status | Evidence |
| --- | --- | --- |
| `withdrawPair` implemented separately from M4 withdraw/redeem | PASS | `src/Vault.sol:706`, delegated to `VaultM5Module.withdrawPair`; M4 ERC-4626 paths remain separate. |
| Withdrawal burns correct shares and distributes LP principal, fees, and idle balances proportionally | PASS with coverage caveat | Burn at `src/VaultM5Module.sol:136-138`; liquidity proportion at `src/VaultM5Module.sol:140-157`; payout at `src/VaultM5Module.sol:344-353`. Unit tests include `test_withdraw_pair_during_pause_oracle_failure_takes_protocol_fee_from_fees_only` and `test_withdraw_pair_respects_slippage_min_outputs`. |
| Withdrawals work during pause, oracle failure, and keeper unavailability | PASS | `withdrawPair` has no paused/oracle/keeper gate in `src/VaultM5Module.sol:111-170`. Covered by tests around `test/unit/Vault.t.sol:348-385`. |
| Protocol fee is taken from fees only, never principal | PASS | `_transferProtocolFees` receives pending/gross fee arguments only at `src/VaultM5Module.sol:162` and `189`; `_withdrawPayout` separates principal from pending fees at `src/VaultM5Module.sol:352-353`. |
| Dynamic fee read from Factory at settlement time | PASS | `IVaultFactory(factory).protocolFeeBps()` at `src/VaultM5Module.sol:325`. |
| Mutable protocol fee and mutable maximum cap | PASS for M5 mock/interface | Interface at `src/interfaces/IVaultFactory.sol:23-38`; mock state and setters at `test/mocks/VaultMocks.sol:335-367`. |
| Fee setter authorization, events, and bounds | PASS for M5 mock | Owner checks at `test/mocks/VaultMocks.sol:354-364`; events at `test/mocks/VaultMocks.sol:359` and `367`; constructor validation at `test/mocks/VaultMocks.sol:342-347`; unit tests around `test/unit/Vault.t.sol:254-298`. |
| Production M8 Factory/FeeCollector not implemented in M5 | PASS for milestone, BLOCKER for production | Interface-only `src/interfaces/IVaultFactory.sol`; mock-only `test/mocks/VaultMocks.sol`. No production M8 Factory exists. |
| `collectFees` uses real PositionManager path and prevents fee double counting | PASS with branch coverage caveat | Zero-liquidity decrease via `modifyLiquidities` at `src/VaultM5Module.sol:183-190`. Tests include `test_collect_fees_uses_dynamic_protocol_fee` and `test_collect_fees_does_not_double_count_repeated_collection`; mainnet fork suite passed. |
| Keeper-only `compound` | PASS | Keeper gate at `src/VaultM5Module.sol:209`; pause and price gates at `src/VaultM5Module.sol:210-213`; wrapper at `src/Vault.sol:724-729`. Covered by `test_compound_keeper_only_reinvests_without_minting_shares` and attack/invariant tests. |
| Permit2 approvals do not remain standing after compound/deposit flows | PASS for tested flows | Approval and revoke at `src/VaultM5Module.sol:443-447`; invariant `invariant_no_standing_permit2_allowance` in `test/invariant/VaultRealV4Invariant.t.sol:209`. |
| `checkRebalance` uses M7 Strategy mock and gates pause/auto/price | PASS | `Vault.sol:736-745`; `VaultM5Module.sol:240-259`; unit tests around `test/unit/Vault.t.sol:438-459`. |
| `script/NetworkConfigs.s.sol` remains single dependency config source | PASS | Mainnet-only config in `script/NetworkConfigs.s.sol:164-209`; no duplicate `scripts/` config source observed. |
| Real mainnet fork tests execute | PASS | `forge test --match-path test/fork/* --fork-url https://ethereum.publicnode.com -vv`: 15 passed, 0 skipped. |
| Invariants at 256 runs x depth 64 | PARTIAL/FAIL | Root `foundry.toml:36-37` sets 256/64, but `test/invariant/VaultRealV4Invariant.t.sol:146-149` overrides default to 48/40 and CI to 128/64. |
| Independent static scan | NOT VERIFIED | Slither and Aderyn are not installed in this environment. |
| Local Anvil deployment and end-to-end workflow through production Factory | FAIL/NOT VERIFIED | `DeployPriceGuard.s.sol` reverts on local chain with `UnsupportedNetwork(31337)`; production M8 Factory is intentionally absent. |

## Delegatecall Architecture Audit

| Area | Status | Evidence |
| --- | --- | --- |
| Module target control | PASS with design risk | `_m5Module` is private immutable at `src/Vault.sol:293` and constructor-created at `src/Vault.sol:392`; delegatecall target is not user-controlled. |
| Storage slot compatibility | PASS now | `forge inspect` showed identical slots 0-14 between `Vault` and `VaultM5Module`: `name`, `symbol`, `totalSupply`, packed `lastRebalance/paused/filled/_initialized`, `_cfg`, `_poolId`, `_strategy`, `_bands`, `balanceOf`, `allowance`. |
| Authorization and `msg.sender` semantics | PASS | Delegatecall preserves caller context. Share burn uses `balanceOf[msg.sender]` at `src/VaultM5Module.sol:136`; keeper auth uses `msg.sender` at `src/VaultM5Module.sol:209`. |
| Reentrancy | PASS for tested paths | Public wrappers are `nonReentrant` at `src/Vault.sol:706-724`; attack tests under `test/attack/*` passed, including refund/hook reentrancy scenarios. |
| External call risk | MEDIUM | PositionManager calls at `src/VaultM5Module.sol:152`, `186`, and `444-446`; token transfers at `src/VaultM5Module.sol:168-169` and `331-332`. Wrappers are reentrancy-protected, but external dependency trust remains a production risk. |
| Future storage safety | HIGH process risk | Any future storage variable inserted before slot 14 in either contract can break delegatecall storage compatibility. This needs a permanent storage-layout regression gate before production. |

## Raj Sir V1-V6 and Critical Division by Zero

The authoritative text of Raj Sir's V1-V6 findings was not present in this working tree or the current prompt. Therefore, the labels **V1-V6 are NOT VERIFIED individually by original finding text**. The following related classes were checked against code and tests:

| Item | Status | Evidence |
| --- | --- | --- |
| Critical Division by Zero | PARTIAL PASS / dedicated finding label NOT VERIFIED | Deposit share math checks `valueBefore == 0` before division at `src/Vault.sol:1264`; first supply branch avoids division at `src/Vault.sol:1260-1262`; `withdrawPair` rejects zero shares at `src/VaultM5Module.sol:120` and burns before using nonzero `cache.supplyBefore`. Fuzz and unit suites pass, but no dedicated test explicitly named for the critical finding was identified. |
| Fee/principal separation | PASS | `src/VaultM5Module.sol:162`, `189`, `321-353`; unit and fork tests pass. |
| Withdrawal liveness during pause/oracle/keeper outage | PASS | `test/unit/Vault.t.sol:348-385`; no module pause/oracle/keeper gate in withdrawal. |
| Reentrancy resistance | PASS for tested paths | Public nonReentrant wrappers and `test/attack/*`: 53 passed. |
| Permit2 standing approvals | PASS | `src/VaultM5Module.sol:443-447`; invariant at `test/invariant/VaultRealV4Invariant.t.sol:209`. |
| Share accounting / rounding | PASS for tested paths | Fuzz/CI suites pass; prior observed `ERC20InsufficientBalance(25000,25001)` is not reproducing. |

## Foundry Lint Warning Review

| Warning class | Status | Assessment |
| --- | --- | --- |
| `controlled-delegatecall` at `src/Vault.sol:1242` | Not directly exploitable as implemented | Target is constructor-created and immutable, but this remains a high-impact architecture pattern requiring storage-layout gates. |
| `unsafe-typecast` | Mostly false positive / low | Casts reviewed include explicit bounds before Permit2 `uint160` approval and liquidity-size casts. Continue enforcing tests around max approval values. |
| `require/revert inside loop` | Low/false positive | Loops are bounded by configured band counts; not an unbounded gas grief vector in reviewed paths. |
| `calls-loop` | Medium dependency risk | External calls inside bounded band loops go to trusted Uniswap/StateView contracts; production deployment must only use verified addresses. |
| `uninitialized-local` | False positive | Solidity zero initialization is intentional for loop counters/accumulators. |
| test-only mutability/unused try-catch/environment warnings | Test hygiene only | Not exploitable in production source. |

## Size, Initcode, Gas, and Deployment

| Item | Status | Evidence |
| --- | --- | --- |
| EIP-170 runtime size | PASS with zero margin | `Vault` runtime is exactly 24,576 bytes. This is deployable but fragile. Any compiler/source drift can break deployment. |
| EIP-3860 initcode size | PASS | `Vault` initcode is 37,266 bytes, below 49,152 bytes. |
| Module size | PASS | `VaultM5Module` runtime is 11,770 bytes. |
| Production Factory creation | NOT VERIFIED | Production M8 Factory intentionally not implemented. |
| Actual Vault clone initialization | PASS for mock Factory tests, NOT VERIFIED for production Factory | Mock clone path in `test/fork/VaultMainnetFork.t.sol:215-230` and unit helpers; no production Factory deployment. |
| Local Anvil production deployment | FAIL/NOT VERIFIED | Network config rejects chain 31337. |

## Coverage and Missing Security-Critical Paths

Coverage summary:

- Total: 95.58% lines, 95.31% statements, 88.47% branches, 92.12% functions.
- `src/Vault.sol`: 99.76% lines, 98.12% statements, 88.62% branches, 100% functions.
- `src/VaultM5Module.sol`: 97.53% lines, 91.90% statements, **48.89% branches**, 100% functions.

Missing or under-proven module branches include:

- Fee collector zero-address revert inside `_transferProtocolFees`.
- `collectFees` no-band early return.
- `compound` zero-band, paused, untrusted-price, and no-liquidity/add-liquidity edge branches.
- Native-vs-ERC20 Permit2 approval/revoke combinations.
- Slippage failure after external PositionManager settlement.
- Staticcall/revert paths in `checkRebalance` beyond the main price catch.
- Overflow/bounds branches for Permit2 `uint160` and liquidity sizing.

## Economic and Security Review

| Risk | Status | Evidence / Notes |
| --- | --- | --- |
| Malicious token reentrancy | PASS for tested hook-like scenarios | Attack suite passed, including token hook/settlement scenarios. Production still depends on token allowlist assumptions. |
| Oracle manipulation | PASS for tested paths | PriceGuard gates deposit/compound/checkRebalance; pair withdrawal remains oracle-independent by design. |
| Forced ETH donation | PASS for tested path | Attack test `test_attack_forcedEthDoesNotChangeAccounting` passed. |
| Fee leakage/double deduction | PASS for tested path | Repeated collection test passed; fee is deducted from freshly collected fee deltas. |
| Incorrect share pricing | PASS for tested paths | Unit, fuzz, attack and invariant suites pass; no current reproduction of prior redeem failure. |
| Zero supply/division by zero | PARTIAL PASS | No exploitable path found in review; dedicated original finding regression not identifiable. |
| Incorrect network dependency | BLOCKER for production | Only mainnet addresses are preserved; local deployment unsupported; `vaultFactory` is `address(0)` in config. |

## Deployment Blockers

1. **No production M8 Factory or FeeCollector exists.** This is correct for M5 scope, but it blocks production readiness.
2. **Local Anvil end-to-end deployment through production Factory is not possible.** The available script rejects chain 31337 through `NetworkConfigs`.
3. **Independent static scan was not run.** Slither and Aderyn are unavailable in this environment.
4. **`VaultM5Module.sol` branch coverage is too low for production confidence.**
5. **`VaultRealV4Invariant` overrides invariant settings below 256 runs / depth 64.**
6. **Vault runtime has zero EIP-170 headroom.** It passes exactly at 24,576 bytes, but this is too brittle for production release discipline.

## Required Fixes Before Production

1. Add or run a production Factory deployment path once M8 exists, including clone creation, initialization, pause/unpause, fee updates, keeper assignment, deposits, withdrawals, fee collection, compound, and emergency exits.
2. Raise `VaultRealV4Invariant` to at least 256 runs and depth 64 in its file-level configs, or remove the lower override.
3. Add targeted branch tests for the uncovered `VaultM5Module.sol` paths listed above.
4. Install and run Slither or Aderyn, then classify and fix findings.
5. Add a permanent storage-layout compatibility check for `Vault` and `VaultM5Module`.
6. Create explicit regression tests named for Raj Sir's V1-V6 findings once the exact finding text is available.
7. Add bytecode-size headroom or enforce an exact compiler/profile gate so future changes cannot accidentally exceed EIP-170.

## Bottom Line

M5 is **functionally strong for milestone validation**: local regression, CI, attack, and real mainnet fork suites are green. It is **not production ready** because production deployment infrastructure and independent security verification are incomplete, and several high-risk module branches remain under-covered.
