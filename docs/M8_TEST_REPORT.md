# M8 Test Report

> **Superseded in part by `docs/M8_AUDIT_REPORT.md` (2026-10-24).** That audit fixed the post-deploy check (it did not enforce "the deployer holds no role"), the Safe handover scripts, the Safe minimums and the missing mainnet Zap guard, and added a real-v4 factory suite, a role matrix and a mainnet deployment rehearsal. It also corrects these claims: "Source policy PASS" held only because the policy accepted `///` NatSpec, the "factory lifecycle integration" test runs on mocks, and the deployer can do more than "the ownership actions encoded by the script" before the handover.

## Results

| Gate | Result |
|---|---|
| Optimized build | PASS |
| Production runtime sizes | PASS — Vault 24,348 B; VaultFactory 10,288 B; FeeCollector 1,713 B; VaultLens 6,006 B; SwapExecutor 5,529 B |
| M8 unit suite | PASS — 18 passed, 0 failed |
| M8 deployment/governance scripts | PASS — 4 passed, 0 failed |
| M8 factory lifecycle integration | PASS — 1 passed, 0 failed |
| M8 factory invariant (default) | PASS — 256 runs × 64 depth = 16,384 calls |
| M8 factory invariant (CI profile) | PASS — 1,000 runs × 128 depth = 128,000 calls |
| Source policy | PASS after documenting all new production declarations |
| Full default-profile regression | PASS — 57 suites, 529 passed, 0 failed, 6 configured fork skips |
| Full CI-profile regression | PASS — 51 suites, 529 passed, 0 failed, 0 skipped |
| Mainnet fork at block 26,246,332 | PASS — 6 suites, 32 passed, 0 failed; M8 deployed-address check intentionally skipped because M8 is not deployed/configured |
| Production deployment | NOT RUN — explicitly out of scope |

## Coverage added

- Deterministic prediction/deployment and creator-specific salt fuzzing.
- Registry enumeration, duplicate prevention, config normalization, and rollback/retry after validation failure.
- Hook, pool, initialization, oracle, trust, shape, geometry, strategy, and deposit-cap rejection.
- Fee/cap authorization and bounds, collector changes, keeper and guardian administration, and implementation compatibility rejection.
- Existing-vault independence after strategy/implementation policy changes.
- Guardian pause-only behavior and timelock-only unpause behavior.
- Permissionless native/ERC-20 collection, repeated zero collection, false-returning tokens, owner-only recipient changes, and native-recipient reentrancy.
- Lens empty and funded vault views, exact user position preview, optional accounting failure, pool-state failure, unknown vaults, and the 50-vault batch bound.
- Restricted timelock execution, delay enforcement, cancellation, ownership acceptance, and deployer-admin removal.
- Script-level immutable-cycle prediction and the 48-hour mainnet delay floor.

## Acceptance checklist

| Requirement | Status |
|---|---|
| Factory-created EIP-1167 clones initialize through the existing four-argument initializer | PASS |
| Implementation contract remains locked | PASS |
| Existing Vault storage layout is unchanged | PASS |
| Clone configuration and strategy are immutable | PASS |
| Existing vault registry/config is unaffected by future registry changes | PASS |
| Hookless allowlisted initialized pools only | PASS |
| PriceGuard config and live trust required at creation | PASS |
| Mutable protocol fee cap, current fee bounded by cap | PASS |
| FeeCollector fixed-recipient forwarding | PASS |
| Guardian pause-only and keeper rebalance access | PASS |
| Restricted timelock executor, not open execution | PASS |
| No `isRouter`/`setRouter` | PASS |
| Network-specific addresses remain in `NetworkConfigs.s.sol` | PASS |
| No environment address loading | PASS |
| No proxy architecture | PASS |
| Fork confirmation against final deployed addresses | PENDING DEPLOYMENT CONFIGURATION |

## Commands

```text
forge fmt
forge build
forge test --match-path test/unit/M8.t.sol -vv
forge test --match-path test/script/M8Scripts.t.sol -vv
forge test --match-path test/integration/M8FactoryLifecycle.t.sol -vv
forge test --match-path test/invariant/M8FactoryInvariant.t.sol -vv
forge test --match-path test/unit/SrcPolicy.t.sol --match-test test_every_src_file_satisfies_the_project_policy -vv
forge test
forge test --profile ci
forge coverage --report summary
FOUNDRY_PROFILE=fork forge test --fork-url <ETHEREUM_ARCHIVE_RPC> --fork-block-number 26246332 --match-path "test/fork/*.t.sol" -vvv
```
