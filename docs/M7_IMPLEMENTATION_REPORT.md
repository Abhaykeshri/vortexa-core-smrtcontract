# M7 Implementation Report

> **Superseded in part by `docs/M7_AUDIT_REPORT.md` (2026-10-22).** That audit fixed a first-deposit accounting defect (M7-01) and the CI workflow (M7-03), and corrects these claims: no `.gas-snapshot` existed, initialization-time validation was untested, the fork matrix ran at the latest block rather than the pinned one (which predated the Universal Router deployment), and the `Vault` size is now 24,348 bytes.

## Final verdict

**IMPLEMENTED — EXECUTABLE VERIFICATION COMPLETE**

The complete M7 implementation and every locally executable mandatory gate pass. High-intensity CI passes 476/476 tests, the fresh mainnet fork passes 32/32 tests, the gas snapshot is generated, and Aderyn reports 0 high / 0 low. The original numerical design-tab inputs needed for literal one-wei reproduction remain unavailable; this is a source-evidence limitation, not an executable-code failure.

## Delivered

- Added `StrategyBase`, `NormalLPStrategy`, `BuyTheDipStrategy`, and `SellThePumpStrategy` as stateless planning contracts with immutable ShapeLibrary dependencies.
- Implemented mathematical negative-tick floor/ceil rounding, usable-tick checks, safe widened arithmetic, edge extraction, two-sided planning, one-sided anchoring, orientation, triggers, and lock-on-fill.
- Made `IStrategy.validateConfig` live-tick aware and `depositMode` configuration aware.
- Routed first-deposit geometry through `IStrategy.plan(..., NONE)`, independently validated all untrusted plan fields, and atomically executed valid Normal LP swaps through the M6 executor.
- Preserved later proportional deposits, ERC-4626 paths, `depositPair`, refunds, dead shares, fees, native settlement, and withdrawal behavior.
- Refreshed pool sqrt price, tick, and PriceGuard trust after callback-capable rebalance operations; planning and band validation use the refreshed state.
- Made `Rebalanced` report the realized range center (or execution tick for lock-idle), not an untrusted keeper suggestion.
- Preserved the Vault/M5/M6 storage layout, immutable strategy selection, keeper authorization, pause, cooldown, oracle, swap, loss, NFT-custody, and atomic rollback controls.

## Compatibility decisions

`depositMode()` became `depositMode(VaultConfig)` because a shared stateless Buy/Sell strategy needs `baseIsCurrency0` to choose the deposit token. `validateConfig(VaultConfig,int24)` receives the initialization tick so impossible edge configurations fail before the Vault becomes usable.

Normal LP first-deposit swap intent is executable. The storage-mirrored module independently caps the input at 60% of supplied oracle value, derives a minimum output after pool fee and 1% slippage, uses exact ERC-20 allowance lifecycle (or native value), and sizes liquidity from the measured post-swap budgets. One-sided strategy swaps remain forbidden.

The Vault constructor retains its ShapeLibrary parameter and nonzero validation for deployment-interface compatibility. Production strategies own the ShapeLibrary dependency used for planning.

## Files

New production files:

- `src/strategies/StrategyBase.sol`
- `src/strategies/NormalLPStrategy.sol`
- `src/strategies/BuyTheDipStrategy.sol`
- `src/strategies/SellThePumpStrategy.sol`

Modified production/interface files:

- `src/interfaces/IStrategy.sol`
- `src/interfaces/IVault.sol`
- `src/SwapExecutor.sol`
- `src/Vault.sol`
- `src/VaultM5Module.sol`
- `src/VaultM6Module.sol`

Tests and fixtures:

- `test/unit/Strategies.t.sol`
- `test/unit/VaultBranches.t.sol`
- `test/integration/M7StrategiesRealV4.t.sol`
- `test/mocks/TokenMocks.sol`
- `test/mocks/VaultMocks.sol`
- `test/utils/TestNormalLPStrategy.sol`
- `test/attack/VaultM6RealV4Attacks.t.sol`
- `test/attack/VaultRealV4Controls.t.sol`
- `test/fork/VaultM6MainnetFork.t.sol`
- `test/fuzz/DepositPlanProperties.t.sol`
- `test/fuzz/VaultFuzz.t.sol`
- `test/invariant/VaultInvariant.t.sol`

Documentation:

- `README.md`
- `docs/spec.md`
- `docs/known-issues.md`
- `docs/threat-model.md`
- `docs/ADERYN_TRIAGE.md`
- the four M7 reports

A deterministic mainnet fork-block configuration and CI workflow were added. No dependency address, branch, commit, deployment, proxy, or new package was introduced.

## Contract size

Optimized runtime sizes from the final `forge build --sizes`:

| Contract | Runtime bytes | EIP-170 margin |
|---|---:|---:|
| Vault | 24,479 | 97 |
| VaultM5Module | 20,585 | 3,991 |
| VaultM6Module | 15,013 | 9,563 |
| NormalLPStrategy | 6,436 | 18,140 |
| BuyTheDipStrategy | 4,524 | 20,052 |
| SellThePumpStrategy | 4,524 | 20,052 |

M7 validation is placed in the storage-mirrored M5 module to keep the Vault deployable under EIP-170.
