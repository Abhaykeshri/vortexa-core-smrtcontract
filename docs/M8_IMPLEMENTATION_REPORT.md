# M8 Implementation Report

> **Superseded in part by `docs/M8_AUDIT_REPORT.md` (2026-10-24).** That audit fixed the post-deploy check (it did not enforce "the deployer holds no role"), the Safe handover scripts, the Safe minimums and the missing mainnet Zap guard, and added a real-v4 factory suite, a role matrix and a mainnet deployment rehearsal. It also corrects these claims: "Source policy PASS" held only because the policy accepted `///` NatSpec, the "factory lifecycle integration" test runs on mocks, and the deployer can do more than "the ownership actions encoded by the script" before the handover.

## Verdict

**IMPLEMENTED — LOCAL VERIFICATION COMPLETE; PRODUCTION CONFIGURATION PENDING**

M8 adds the factory, deterministic EIP-1167 deployment, fee collector, dashboard lens, timelock workflow, role administration, strategy registry, pool policy, and deployment checks without changing the Vault storage layout or replacing existing vault behavior. No contract was deployed and no commit or push was made.

## Delivered

- `VaultFactory` deploys creator-namespaced deterministic clones, normalizes base orientation from governance policy, validates pool initialization, hooklessness, oracle presence/trust, shapes, range geometry, deposit caps, and strategy configuration, then registers only successfully initialized vaults.
- Implementation changes affect only future clones. A candidate must retain the factory, StateView, PriceGuard, PositionManager, Permit2, PoolManager, SwapExecutor, and M6-module identity.
- Strategy registry changes affect only future vaults. Existing clones retain their initialized strategy and immutable configuration.
- The current protocol fee, mutable cap, FeeCollector, keeper set, and guardian are governance-controlled dynamic values. The absolute safety ceiling is 10,000 bps; no unapproved 2,500-bps constant or fee rate limit was introduced.
- `FeeCollector` accepts native/ERC-20 fees and permissionlessly forwards the complete selected balance to the governance-selected fixed recipient.
- `VaultLens` returns metadata, immutable config, shares, scalar assets, pair-token withdrawal value, fee settings, bands, pool state, range state, pause/fill state, and user positions. Optional accounting/pool failures are explicit flags; empty vaults return valid zero values.
- Governance uses OpenZeppelin `TimelockController`, a minimum 48-hour mainnet delay, a Safe proposer/canceller, and one restricted executor. The deployer admin role is removed.
- `PriceGuard`, `VaultFactory`, and `FeeCollector` use two-step ownership; acceptance is scheduled and executed as one timelocked batch.
- M9's removed `isRouter`/`setRouter` API was not added.
- No upgradeable proxy, environment-sourced contract address, router allowlist, or deployment-time code mutation was introduced.

## Deployment architecture

`SwapExecutor`, `Vault`, and `VaultFactory` form an immutable address cycle. M8 resolves it with ordinary-CREATE nonce prediction:

1. Timelock
2. FeeCollector
3. Normal LP strategy
4. Buy-the-Dip strategy
5. Sell-the-Pump strategy
6. SwapExecutor, pointing to the predicted factory
7. Vault implementation, pointing to the executor and predicted factory
8. VaultFactory
9. VaultLens

This differs from the stale guide order because the current Vault constructor immediately reads `SwapExecutor.vaultModule()`. CREATE2 cannot cleanly remove the cycle: its address includes the init-code hash, which itself would contain the other predicted immutable addresses.

## Main files

- `src/VaultFactory.sol`
- `src/FeeCollector.sol`
- `src/VaultLens.sol`
- `src/interfaces/IVaultFactory.sol`
- `src/interfaces/IVaultLens.sol`
- `script/DeployM8.s.sol`
- `script/ScheduleM8Handover.s.sol`
- `script/ExecuteM8Handover.s.sol`
- `script/PostDeployM8Check.s.sol`
- `script/NetworkConfigs.s.sol`
- `test/unit/M8.t.sol`
- `test/script/M8Scripts.t.sol`

## Operational boundary

Mainnet governance identities, treasury, deployed PriceGuard/ShapeLibrary addresses, and the production pool cap remain explicit `address(0)`/zero placeholders in `NetworkConfigs.s.sol`. `DeployM8` rejects missing required values. Known values must be reviewed and committed to that file before any dry run or broadcast; addresses are never read from environment variables.
