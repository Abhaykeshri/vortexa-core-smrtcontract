# Vortex Vault Contracts

This repository implements milestones M0 through M8: shared math and types, price protection, band shapes, vault accounting and lifecycle operations, atomic rebalancing, production strategies, deterministic vault creation, fee collection, views, and timelocked governance. M9 and later product/deployment milestones remain out of scope.

## Requirements

- Foundry with Solidity 0.8.26 available through `svm`
- Git with submodule support

## Build and test

```powershell
git submodule update --init --recursive
forge build --sizes
forge fmt --check
forge test
forge test --profile ci
forge coverage
```

The math differential tests use the pinned Uniswap v4-core `TickMath` and test-only `LiquidityAmounts`, and v4-periphery action constants. Uniswap dependencies are available under `uni-test/` only for tests; production source does not import them.

## Exact M1 fuzz gate

```powershell
forge test --match-path test/fuzz/MathDifferential.t.sol --fuzz-runs 100000
```

## Dependency pins

All direct dependencies are Git submodules recorded in `.gitmodules` and pinned by the Git index to exact commits. Run `git submodule status` to inspect the resolved revisions.

## M2 price guard

`PriceGuard` compares the live v4 pool sqrt price against a configured reference price. The reference can come from a Chainlink feed, a Uniswap v3 TWAP fallback, or both. It rejects stale, invalid, clamped, sequencer-grace-period, token-mismatch, short-history, and over-deviation cases.

M2 is an oracle guard only. It does not deploy feeds, create pools, custody funds, rebalance positions, execute swaps, or configure chain-specific addresses.

## M7 strategies

- `NormalLPStrategy`: two-sided bands, out-of-range/drift triggers, and M6 unit-liquidity swap sizing.
- `BuyTheDipStrategy` and `SellThePumpStrategy`: orientation-aware one-sided deposits, trailing triggers, fill locking, and current-tick anchoring.
- `StrategyBase`: immutable ShapeLibrary dependency, shared trigger reasons, signed floor/ceiling alignment, orientation, edge, and one-sided helpers.

Vault initialization validates the selected strategy configuration. First deposits request a strategy plan with reason `NONE`; the vault independently validates every band, weight, side, state, lock, and swap field before minting. A valid Normal LP swap is executed atomically through the M6 executor with a trusted-oracle output floor, a 1% slippage ceiling, a 60% value cap, measured output, and exact ERC-20 allowance revocation. One-sided strategies cannot request a deposit swap.

## M8 factory and governance

`VaultFactory` deploys creator-namespaced deterministic EIP-1167 clones after enforcing the pool allowlist, hookless pool policy, initialized StateView state, PriceGuard configuration/trust, valid range geometry, strategy validation, and deposit-cap policy. Existing vault configuration, strategy, and implementation remain immutable; fee, collector, keeper, and guardian policy are read dynamically as designed.

`FeeCollector` permissionlessly flushes full native/ERC-20 balances to its fixed treasury recipient. `VaultLens` provides bounded, failure-aware dashboard views. Deployment scripts resolve the immutable executor/vault/factory address cycle with checked CREATE nonce prediction and hand `VaultFactory`, `FeeCollector`, and `PriceGuard` to a restricted-executor `TimelockController` through a delayed two-step acceptance batch.

## Scope

M0-M8 are implemented. Zap work (M9), backend/frontend, production address selection, governance ceremony, operations, and production deployment remain out of scope.

## Test suites and audit

`forge test` runs unit, fuzz, invariant, attack, real-v4 integration, and policy tests (see `docs/spec.md`). The M7 signed-rounding property executes 100,000 fuzz cases. `forge test --profile ci` raises general fuzz runs to 10,000 and invariants to 1,000 runs of depth 128. `test/unit/SrcPolicy.t.sol` enforces the pragma, licence, forbidden-construct and NatSpec rules on every file under `src/`.
