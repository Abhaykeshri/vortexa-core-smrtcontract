# Contract Specification

## Delivered scope

This repository implements M0 to M9. It does not implement the final deployment (M11), frontend/backend, or operations milestones.

## M1 shared types

`Currency` is an address value type; zero is native ETH. `PoolKey` uses the v4 field order: currency0, currency1, fee, tickSpacing, hooks. `VaultConfig` includes the final strategy fields from the guide, including `baseIsCurrency0`. `Plan` and `RebalanceParams` reflect the later corrected strategy and rebalance signatures.

## M1 helpers and math

- `PoolIdLib.toId` hashes the five static ABI words and is compared against the pinned v4 `PoolIdLibrary`.
- `CurrencyLib` identifies native ETH, reports the caller's balance, skips zero transfers, uses OpenZeppelin `SafeERC20`, and reverts with `NativeTransferFailed` if a native transfer fails. Call sites that send native currency must provide their own reentrancy protection.
- `PosmActions` contains the PositionManager action identifiers and is compared against pinned v4-periphery constants.
- `SqrtPriceMath.getSqrtPriceAtTick` is an independent Q128.128 bitwise implementation for ticks [-887272, 887272], with nearest-integer rounded constants matching the pinned v4 implementation. No inverse price-to-tick operation is provided.
- `LiquidityMath` normalizes endpoints, uses OpenZeppelin full-precision `Math.mulDiv`, checks uint128 conversion, and rounds required token amounts down.

## Licensing decision

Production M1 tick math is independently implemented; it does not import Uniswap source. The pinned Uniswap v4 implementation and test-only `LiquidityAmounts` are used only as differential test oracles under `test/`.

## M1 acceptance tests

The suite checks exact tick values at boundaries and dense samples, fuzzes tick parity against v4, differentially fuzzes both liquidity directions (at most 1 wei for amounts), proves round-trip amounts do not exceed inputs, and compares PoolId/action encodings.

## M2 oracle price guard

`PriceGuard` uses OpenZeppelin `Ownable2Step`. The deployer is the temporary initial owner, calls `transferOwnership(timelock)`, and the timelock must call `acceptOwnership()` before it becomes the only account allowed to manage pool reference oracle settings with `setPairConfig`. Consumers call `isPriceTrusted(PoolKey)` to compare the current v4 pool sqrt price from `StateView` against an external reference price and receive `(trusted, deviationBps)`.

`PairConfig` supports:

- Chainlink feed reference with inversion, max staleness, and answer bounds.
- Uniswap v3 TWAP fallback with inversion and minimum 600 second window.
- Maximum deviation in basis points from 1 to 1000.

The guard rejects missing configs, unset references, invalid Chainlink decimals, stale/future/zero/negative/clamped Chainlink answers, L2 sequencer-down or grace-period states, short v3 TWAP history, wrong v3 token pairs, and broken reference tokens. Native ETH pools are matched against the configured wrapped native token for v3 fallback checks.

M2 deliberately does not contain deployment scripts or chain address configuration. Production deployment still needs the target v4 `StateView`, optional sequencer uptime feed, wrapped native token address, Chainlink feed addresses, pool keys, and v3 fallback pools for the selected chain.

## M2 price conversion (corrected formula)

With feed decimals `fd`, answer `a`, and token decimals `d0`, `d1`, the raw price `token1 raw units / token0 raw units` is:

- feed quoting token1 per token0: `a * 10**d1 / (10**fd * 10**d0)`
- feed quoting token0 per token1 (`invertFeed`): `10**fd * 10**d1 / (a * 10**d0)`

The developer guide builds the inverted case by swapping the numerator and denominator of the first formula, which also swaps `10**d0` and `10**d1`. That is only correct when `d0 == d1`, and it makes a pool such as USDC (6 decimals, currency0) / WETH (18 decimals, currency1) impossible to configure with Chainlink's ETH/USD feed. The implementation uses the corrected formula above. V3 TWAP references are in raw token units already, so `invertV3` is a plain reciprocal.

The ratio is converted with `sqrt(num * 2**192 / den)`, which only fits in 256 bits when `num < den * 2**64`; ratios outside that domain, or references that round to zero in Q96, are reported as "no reference" (`(false, type(uint256).max)`), never as a revert.

## Test and policy layout

- `test/unit`: unit, boundary and "breaking" tests; `SrcPolicy.t.sol` (pragma, licence, forbidden constructs, NatSpec) and `TypesLayout.t.sol` (ABI layout lock).
- `test/fuzz`: differential and property tests for the math libraries and `PriceGuard`.
- `test/invariant`: stateful handlers and invariants for `PriceGuard` and `CurrencyLib`.
- `test/attack`: attack-catalogue scenarios.
- `test/fork`: mainnet fork tests (skipped without a fork RPC).
- `test/integration`: the real Uniswap v4 `PoolManager` and periphery `StateView` deployed in-process, driving `PriceGuard`, `ShapeLibrary` and the M1 maths with real liquidity and swaps (stands in for the fork tests when no RPC is available).
- `test/mocks`, `test/utils`: shared mocks and fixtures.

## M3 shape library

`ShapeLibrary` is a pure, deterministic, stateless band generator. It converts `(shapeId, centerTick, ticksLeft, ticksRight, tickSpacing)` into at most five contiguous, non-overlapping bands with aligned tick edges and relative liquidity weights that sum to exactly 10,000 basis points.

The implemented presets are:

- `0` Exponential: 5 bands, weights `1000, 2000, 4000, 2000, 1000`.
- `1` Narrow Stable: 1 band, weight `10000`.
- `2` Wide Stable: 3 bands, weights `2500, 5000, 2500`.
- `3` Narrow Volatile: 3 bands, weights `3333, 3334, 3333`.
- `4` Wide Volatile: 5 bands, equal `2000` weights.
- `5` Single-Tick: 1 band starting at the aligned center, weight `10000`.
- `6` Full Range: 1 band from the smallest to largest usable tick for the spacing, weight `10000`.
- `7` Custom: 1 band over the supplied range, weight `10000`.

The implementation uses `int256` intermediate tick arithmetic, floor/ceil division that handles negative ticks correctly, clamps to the usable Uniswap tick range, reduces band count when the available interval count is smaller than the preset, and leaves every returned band's `tokenId` and `liquidity` at zero.

## M3 verification summary

- Unit, boundary, fuzz, property, attack and invariant suites for `ShapeLibrary`: 11 + 2 + 18 + 13 + 5 + 4 invariants, all passing (see `docs/M3_AUDIT_REPORT.md`).
- `ShapeLibrary` coverage is 100% of lines, statements, branches and functions.
- Worst-case measured `computeBands` gas is below the 50,000 target for every tested input, including adversarial ones.
- Full local suite on the CI profile (10,000 fuzz runs, 1,000 x 128 invariants): 208 tests passing.
- The 30 injected bugs of the mutation round were all caught; see the audit report.

M3 has been reviewed internally but not independently audited.

## M4 vault core and deposit

`Vault` is an EIP-1167 clone implementation holding one Uniswap v4 position NFT per band, with ERC-20 shares (18 decimals) and value measured in `currency1` units.

- **Pair deposits (`depositPair`)** follow guide 6.4: oracle check, strategy gate, snapshot of the vault value before any funds arrive (excluding `msg.value`), exact pulls with a balance-delta check, a check that the pool price did not move during the pulls, band planning (first deposit from the selected strategy and independently re-checked; later deposits proportional to existing liquidity, planned against the budget minus 2 units per band for Uniswap's round-up), one `modifyLiquidities` call with exact Permit2 allowances revoked afterwards, then shares from the measured value, cap check, mint and refund.
- **Settlement** closes each currency with `CLOSE_CURRENCY` (pays a debt or takes a credit) and sweeps unused native ETH. Adding liquidity to an existing band also credits that band's accrued fees into the settlement; the depositor's cost per currency is measured as `pre + creditedFees - post`, so those fees stay with the existing holders. The measurement is clamped at zero (ETH forced into the PositionManager and swept back is a donation) and capped at the supplied amount.
- **ERC-4626 single-asset entry points.** `asset()` is `currency1`. `deposit`/`mint` take exactly the requested token1, hold it as idle balance (valued one to one) and mint `assets * supply / totalAssets` shares, so `previewDeposit`/`previewMint` are exact; deploying idle funds into the bands is a later compounding step. `withdraw`/`redeem` pay idle token1 only and, because they are priced from the pool price, require PriceGuard to trust it (`maxWithdraw`/`maxRedeem` are zero otherwise). The guide's oracle-free, pro-rata in-kind withdrawal is M5.
- **Pause.** `pause()` by the factory or its guardian, `unpause()` by the factory or its owner (the timelock). Pausing blocks both deposit paths; withdrawals are never paused.
- **NFT callback.** `onERC721Received` accepts a token only from the PositionManager and only during the vault's own `modifyLiquidities` call (a transient flag).
- **Native ETH.** `receive()` accepts ETH only from the PositionManager, the PoolManager and the swap executor.

M4 test layout additions: `test/integration/utils` (real v4 fixture, Permit2 double), `test/attack/VaultRealV4*.t.sol`, `test/integration/VaultErc4626RealV4.t.sol`, `test/invariant/VaultRealV4Invariant.t.sol`, `test/unit/VaultBranches.t.sol`. See `docs/M4_AUDIT_REPORT.md`.

## M5 withdraw, fees and views

The size-heavy M5 operations run in `VaultM5Module` through `delegatecall`: `Vault.withdrawPair`, `collectFees` and `compound` forward their calldata unchanged to the module functions of the same signature, and the module reads the vault's immutable dependencies back through the vault's public getters. The module is created by the `Vault` implementation constructor (`m5Module()`), mirrors `Vault`'s storage slot for slot, and refuses direct calls.

- **`withdrawPair(shares, min0, min1, receiver)`** (guide 7.2): no pause, oracle or keeper dependency. Reads supply, idle balances and each non-empty band's pending fees `F`; burns the caller's shares; lowers stored liquidity by `floor(L * s / S)`; one `modifyLiquidities` (DECREASE_LIQUIDITY per non-empty band, TAKE_PAIR to the vault), skipped when nothing is removed and no fee is pending; pays `(delta - F) + floor(s * (idle + F - protocolFee) / S)` with `protocolFee = floor(F * feeBps / 10_000)`; checks the minimums; pays currency1 then currency0. The factory is read only when `F > 0`; the fee transfer is best-effort (see known issues).
- **`collectFees()`**: permissionless; DECREASE_LIQUIDITY of zero per non-empty band plus TAKE_PAIR; the protocol cut is sent to the factory's fee collector and the rest stays idle.
- **`compound()`**: keeper-only, pause-gated, PriceGuard-gated; adds idle balances to the existing bands in proportion (no shares minted), measures the spend as `idle + creditedFees - after`, and pays the protocol cut of the fees the INCREASE credited.
- **Deposits** pay the protocol cut of the fees their INCREASE credits (computed before the call), so every path that collects fees pays exactly `feeBps` of them.
- **Protocol fee**: `min(factory.protocolFeeBps(), 10,000)`, zero if the factory read reverts or returns malformed data; the same rule is used for valuation (`totalAssets` counts pending fees net of it), collection and the preview. The business cap is mutable factory state (team decision, see `IVaultFactory`).
- **In-kind preview**: `VaultM5Module(vault.m5Module()).previewWithdrawPair(vault, shares)` returns exactly what `withdrawPair` would pay, from StateView reads only.
- **Views**: `totalAssets`, ERC-4626 previews, the in-kind preview above, `bands()`, `config()`, `paused()`, `lastRebalance()`, `priceGuard()`, `stateView()`, `positionManager()`, `permit2()`, `factory()`, `m5Module()` and `checkRebalance()` (gates `PAUSED`, `AUTO_OFF`, `COOLDOWN` (30 minutes), `PRICE`, then the strategy trigger).
- **Events**: `PairWithdrawn`, `FeesCollected`, `Compounded`, `ProtocolFeeForfeited` (declared in `IVault`).

M5 test layout additions: `test/attack/VaultM5RealV4Attacks.t.sol`, `test/integration/VaultM5LifecycleRealV4.t.sol`, `test/invariant/VaultM5RealV4Invariant.t.sol`. See `docs/M5_AUDIT_REPORT.md`.

## M6 swap executor and rebalance

- **`SwapExecutor.swapExactInput(key, zeroForOne, amountIn, minAmountOut)`**: callable only by a factory vault or the Zap. ERC-20 input is pulled from the caller with `transferFrom` and verified by balance delta (native input must equal `msg.value`); PriceGuard must trust the pool and `minAmountOut` must be at least `floor = amountIn * P_ref^{+-1} * (1 - fee) * (1 - 1%)`; one Universal Router `V4_SWAP` command with `SWAP_EXACT_IN_SINGLE`, `SETTLE_ALL`, `TAKE_ALL`, where `ExactInputSingleParams` (including `minHopPriceX36`) is encoded as one struct value; exact Permit2 allowances revoked afterwards; unspent input refunded; measured output sent to the caller.
- **`Vault.rebalance(RebalanceParams)`** forwards to `VaultM6Module` by `delegatecall`. Gates: keeper, pause, auto-rebalance, 30-minute cooldown, `maxSlippageBps <= 100`, PriceGuard trust, strategy trigger, `|newCenter - tick| <= 200`. Then: value before at the oracle reference price; burn every band (fees collected and the protocol cut paid by the shared fee rule); strategy plan, independently validated (count, contiguity, alignment, range, weights summing to 10,000, one-sided side rule, lock-idle only for one-sided strategies with `lockOnFill`, swap at most 60% of value and of the holding); optional swap through the executor with the keeper's floor; mint the new bands (custody checked before storage); loss check `valueAfter >= valueBefore * (1 - maxSlippageBps)` at the same reference price; `lastRebalance` and `Rebalanced(keeper, oldCenter, newCenter, valueBefore, valueAfter)`, where `oldCenter` is the midpoint of the bands just replaced.
- **Lock-idle**: no bands, `filled = true` (deposits refused, withdrawals open); the next rebalance that mints clears it.

M6 test layout additions: `test/integration/utils/UniversalRouterDouble.sol`, `test/utils/TestNormalLPStrategy.sol`, `test/attack/VaultM6RealV4Attacks.t.sol`, `test/invariant/VaultM6RealV4Invariant.t.sol`, `test/fork/SwapExecutorErc20PoolFork.t.sol`, `test/unit/PriceGuardReference.t.sol`. See `docs/M6_AUDIT_REPORT.md`.

## M7 production strategies

All M7 strategies are stateless contracts whose only external dependency is an immutable `ShapeLibrary`. `IStrategy.depositMode` receives the vault configuration so one deployed one-sided strategy can safely serve either base-token orientation. `validateConfig` is called during vault initialization.

- **Normal LP:** accepts both tokens; supports two-sided shapes 0-4 and 7; requires positive left/right widths and `driftTicks < min(widths)`; triggers at `tick < lower`, `tick >= upper`, or within the configured asymmetric edge distance; plans around the keeper center and uses the M6 unit-liquidity formula with fee gross-up for its executable swap intent.
- **Buy the Dip / Sell the Pump:** support shapes 3, 4 and 7; require a positive trail and exactly one zero-width side. Range orientation is `below = (strategy == BuyTheDip) == baseIsCurrency0`. Below ranges accept currency1 and above ranges accept currency0. Empty vaults accept the first deposit. Trail and fill boundaries use the guide's exact strict/inclusive comparisons. A `FILLED` plan locks idle only when configured; other plans ignore the keeper center and anchor to `floor(tick, spacing)` below or `ceil(tick + 1, spacing)` above.
- **First deposits:** call `plan(config, tick, config.centerTick, sqrtPrice, amount0, amount1, NONE)`. The storage-mirrored M5 module independently rejects more than five bands, stateful bands, gaps, overlaps, bad alignment/range, zero or non-10,000 weights, wrong-side one-sided ranges, invalid lock plans, inconsistent swap flags, one-sided swaps, swap amounts above the supplied input, and swaps above 60% of supplied oracle value. A valid Normal LP request executes atomically through `SwapExecutor` with a trusted-reference minimum output and 1% hard slippage ceiling. Liquidity is then sized from measured post-swap budgets, exact ERC-20 allowances are revoked, and unused funds are refunded. Shares are minted for `min(net supplied value, measured value added)`, both at the pre-deposit price and net of fees, so the swap's fee, impact and slippage stay with the depositor (M7 audit, M7-01). An empty deposit is refused with `InvalidDepositMode` in every mode. Later deposits and `compound` size the existing bands through one module function (`VaultM5Module.depositLiquidity`), measured on a copy of the stored proportions scaled to the first-deposit probe, so small stored liquidity cannot make a deposit pull more than its budget.
- **Rebalances:** refresh pool sqrt price and tick and re-check PriceGuard after callback-capable burns/fee payment, then plan and validate against that refreshed state. `Rebalanced.newCenter` reports the actual minted-band center, or the execution tick for lock-idle.

M7 tests are in `test/unit/Strategies.t.sol`, `test/integration/M7StrategiesRealV4.t.sol`, `test/attack/VaultM7RealV4Attacks.t.sol` (production one-sided lifecycles in all four orientations, TRAIL re-anchoring, Normal LP out-of-range rebalances, first-deposit cost isolation) and `test/invariant/VaultM7OneSidedInvariant.t.sol`, with hostile-plan coverage in `test/unit/Vault.t.sol` and the M4-M6 attack suites. Signed tick rounding runs 100,000 fuzz cases, and production strategies are exercised through real in-process Uniswap v4 ERC-20 and native pools.

## M8 factory, fees, views, and governance

- `VaultFactory` uses OpenZeppelin deterministic EIP-1167 clones. The salt commits to creator, normalized full `VaultConfig`, name, and symbol. Registration and enumeration occur only after successful initialization.
- New vaults require a governance-allowlisted hookless pool, nonzero per-vault cap, initialized StateView pool, configured and currently trusted PriceGuard, valid ShapeLibrary shape, sorted currencies, valid V4 fee/spacing, aligned in-bounds range geometry, and a registered strategy that accepts the config at the live tick.
- The pool rule supplies the authoritative `baseIsCurrency0`; caller input cannot change it. The clone stores its strategy and complete config once, and later implementation/strategy/pool-policy changes do not rewrite existing vaults.
- Implementation rotation is future-only and accepts only implementations with the same exposed immutable dependency graph and matching SwapExecutor/M6 module.
- `protocolFeeBps <= maxProtocolFeeBps <= 10_000`. Both values are timelock-controlled mutable state. The collector, keepers, and guardian are also timelock-controlled.
- `FeeCollector.collect(currency)` is permissionless and forwards the full balance to the fixed recipient under a reentrancy guard. Only governance may change the recipient.
- `VaultLens` accepts registered vaults only, caps batches at 50, and exposes explicit accounting/pool availability flags. Pair values come from the existing exact `VaultM5Module.previewWithdrawPair` path.
- Mainnet governance uses a minimum 48-hour OpenZeppelin timelock. The governance Safe proposes/cancels, execution is restricted to the configured executor, and the deployment admin renounces its timelock admin role.
- `VaultFactory`, `FeeCollector`, and `PriceGuard` complete Ownable2Step handover through a single scheduled timelock batch.
- `isRouter` and `setRouter` are absent. M8 adds no upgradeable proxy.
- M8 audit additions:
  - `PostDeployM8Check` requires the recorded deployer to hold no role anywhere: no Timelock admin, proposer, canceller or executor role, and not keeper, guardian or treasury. It also requires no pending ownership transfer and the configured ETH/USDC pool rule.
  - When the proposer or executor is a Safe, the handover scripts print the exact timelock transaction for the Safe instead of broadcasting.
  - `DeployM8` accepts Safes of at least 3-of-5 (governance) and 2-of-3 (guardian), and refuses mainnet without the Zap address, because the executor's Zap is immutable and the factory pins the executor.
  - NatSpec in `src/` is block-style only (`SrcPolicy`).

## M9 Zap

- **`Zap.zapDeposit(vault, tokenIn, amountIn, minShares, maxSlippageBps, receiver)`** is `nonReentrant` and makes no caller-chosen call: it talks only to the factory, the registered vault (and the StateView, PriceGuard and ShapeLibrary that vault and factory are wired to), the immutable SwapExecutor, and the vault's two currencies.
- It refuses a zero or self receiver, a zero amount, `maxSlippageBps` above the executor's `MAX_SLIPPAGE_BPS`, a vault the factory did not register, a registered vault whose factory, executor or PriceGuard differ from the Zap's (or an executor bound to another factory), a token that is not one of the vault's currencies, native value other than exactly `amountIn` for ETH input (zero otherwise), and a vault whose strategy contract is not the one this Zap pins for its kind.
- ERC-20 input is pulled and checked by balance delta (fee-on-transfer refused). The Zap's balances are snapshotted first, and only the current call's balances are swapped, deposited and refunded, so donated dust is never spent or paid out.
- Split. Normal LP sizes the swap with `NormalLPMath.sizeSwap` (the guide 8.3 formula, shared with the strategy) against the token ratio of the active bands, computed on a probe-scaled copy of their liquidity exactly as the vault sizes later deposits, or of the planned first-deposit bands. One-sided vaults swap all of the wrong token and none of the right one.
- The swap goes only through the executor on the vault's own pool, with `minOut = minOutFromReference(key, zeroForOne, swapAmount, referencePrice, maxSlippageBps)`. The executor allowance is exact and revoked, and the output is measured by balance delta rather than taken from the executor's return value.
- The deposit uses exact allowances and `depositPair`; the allowances are revoked afterwards and the vault's reported shares and used amounts are checked. Every call-local leftover goes back to the caller, after which the Zap's balances must equal the pre-call snapshot exactly.
- `receive()` accepts ETH only from the executor (swap output) and registered vaults (deposit refunds).
- `quoteZap` mirrors the plan, values the post-swap balances at the executor's worst-case floor (`MAX_SLIPPAGE_BPS`), and keeps per-band rounding reserves and a 1 ppm margin, so the quote never exceeds what an immediate zap mints (fuzzed down to single raw units). It is an estimate: it does not check PriceGuard trust, and dust inputs that cannot mint still revert in `zapDeposit`.
- `DeployM9` deploys the timelock, fee collector and strategies, then the Zap, SwapExecutor, Vault implementation and VaultFactory at nonce-predicted addresses (Zap at starting nonce + 5, executor + 6, factory + 8) and verifies every address and the code at each. `PostDeployM9Check` extends the M8 check with the Zap's links (executor Zap, Zap factory and executor, implementation factory, executor and PriceGuard, the three pinned strategies); each failure is reported by name.
