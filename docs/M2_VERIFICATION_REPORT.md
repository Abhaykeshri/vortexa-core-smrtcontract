# M2 Verification Report

Date: 2026-10-09
Branch: milestone/M2
Scope: M2 PriceGuard only

## Source Requirements

M2 was checked against `Contracts developer guide.pdf`, pages 11-15. The implemented scope is the owned `PriceGuard` oracle layer with Chainlink primary reference, Uniswap v3 TWAP fallback, optional L2 sequencer uptime gate, cached token decimals, native ETH/WETH mapping, and deviation checks.

External addresses were selected from official/public sources:

- Uniswap v4 Ethereum `StateView`: `0x7ffe42c4A5DeeA5b0fec41C94C136Cf115597227`
  Source: https://developers.uniswap.org/docs/protocols/v4/deployments
- Uniswap v4 ETH/USDC example pool key: native ETH, USDC, fee `500`, tick spacing `10`, hooks `0x0000000000000000000000000000000000000000`
  Source: https://developers.uniswap.org/docs/sdks/v4/guides/pool-data
- Chainlink Ethereum ETH/USD feed: `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419`
  Source: https://docs.chain.link/docs/data-feeds/price-feeds/addresses
- Uniswap v3 Ethereum factory: `0x1F98431c8aD98523631AE4a59f267346ea31F984`
  Source: https://developers.uniswap.org/docs/protocols/v3/deployments
- Mainnet WETH: `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`
- Mainnet USDC: `0xA0b86991c6218b36c1d19D4a2e9Eb0ce3606eB48`

## Changes

- `src/PriceGuard.sol`
  - Runtime Chainlink `latestRoundData()` and `decimals()` reverts now return `(false, 0)` so `isPriceTrusted` returns not trusted instead of bubbling oracle failures.
  - `_sqrtFromRatio` now explicitly reverts with `PriceOutOfRange` if a future arithmetic domain ever exceeds `uint160`.
- `test/unit/PriceGuard.t.sol`
  - Added coverage for future Chainlink timestamps, runtime reverted feed data, and runtime reverted decimals.
- `test/fork/PriceGuardMainnetFork.t.sol`
  - Added mainnet fork integration tests for actual Chainlink ETH/USD, Uniswap v4 StateView ETH/USDC pool key, and Uniswap v3 ETH/USDC TWAP fallback.
  - Tests self-skip outside chain id 1 so local non-fork coverage remains usable.
- `foundry.toml`
  - CI profile excludes `test/fork/*`; fork profile matches `test/fork/*`.
- `.gitattributes`
  - Normalizes Solidity/Markdown/TOML/lockfile line endings to LF.

## Verification Results

| Command | Result |
| --- | --- |
| `forge fmt --check` | PASS |
| `forge build --sizes` | PASS. `PriceGuard` runtime size: 8,699 bytes; runtime margin: 15,877 bytes. |
| `forge test --profile ci` | PASS. 28 passed, 0 failed, 0 skipped. |
| `forge test --match-path test/unit/PriceGuard.t.sol --fuzz-runs 100000` | PASS. 16 passed, 0 failed. |
| `forge test --match-path test/fuzz/MathDifferential.t.sol --fuzz-runs 100000` | PASS. 6 passed, 0 failed. |
| `forge coverage --report summary` | PASS. 28 passed, 0 failed, 1 skipped. |
| `forge test --profile fork --match-path "test/fork/*" --fork-url $env:RPC_URL --fork-block-number $env:BLOCK -vv` | BLOCKED. `RPC_URL` and `BLOCK` environment variables were not set in this shell. |
| `slither .` | BLOCKED. Slither is not installed in this shell. |
| `aderyn .` | BLOCKED. Aderyn is not installed in this shell. |

## Coverage

Latest local non-fork coverage:

| File | Lines | Statements | Branches | Functions |
| --- | --- | --- | --- | --- |
| `src/PriceGuard.sol` | 100.00% (123/123) | 97.74% (173/177) | 87.50% (35/40) | 100.00% (16/16) |
| Total | 95.35% (246/258) | 97.08% (333/343) | 94.12% (80/85) | 90.16% (55/61) |

The fork test file is skipped during non-fork coverage and must be executed with an Ethereum mainnet RPC URL and pinned block.

## Method Surface

`forge inspect PriceGuard methods` reported:

- `setPairConfig((address,address,uint24,int24,address),(address,bool,uint32,uint256,uint256,address,bool,uint32,uint16))`
- `isPriceTrusted((address,address,uint24,int24,address))`
- `configOf((address,address,uint24,int24,address))`
- `stateView()`
- `sequencerUptimeFeed()`
- `nativeWrapper()`
- `owner()`

Only `setPairConfig` is a state-changing external/public function. The other methods are view getters or view checks.

## Reentrancy-Events Warning Review

Foundry reports `reentrancy-events` at `src/PriceGuard.sol` on the `PairConfigSet` emission because `setPairConfig` performs external reads before emitting the event.

The reviewed `setPairConfig` flow is:

1. `onlyOwner` checks the caller.
2. `_validateConfig` reads Chainlink feed decimals and v3 pool token addresses.
3. `_currencyDecimals` reads token decimals, or uses 18 for native ETH.
4. `_validateInitialPrice` reads the v4 pool slot and calls the configured Chainlink/v3 reference path.
5. `_config`, `_dec0`, and `_dec1` are written.
6. `PairConfigSet` is emitted.

The external calls before the event are made through interfaces whose functions are declared `view`: Chainlink `decimals`/`latestRoundData`, ERC-20 `decimals`, v3 `token0`/`token1`/`observe`, and StateView `getSlot0`. Solidity emits `STATICCALL` for these external view calls, including when they are reached from the non-view `setPairConfig` transaction. A malicious oracle/token/pool reached through these calls cannot successfully reenter `setPairConfig` and mutate `PriceGuard` state because the EVM static context forbids state-changing execution and event emission in the reentrant path.

The function also does not write `PriceGuard` config state until after all external validation reads have completed. Therefore there is no partially-written config that can be observed or acted on during validation. The event is emitted only after the final stored state has been written, so off-chain consumers that read the transaction log see an event corresponding to the stored config.

Conclusion: the warning is treated as a false positive for the current M2 design. It is not suppressed in code. This conclusion depends on keeping the pre-event external calls as `view`/`STATICCALL` reads; if future milestones add non-view external calls to `setPairConfig`, this review must be repeated.

## Requirement Status

| Requirement | Status | Notes |
| --- | --- | --- |
| Preserve M0/M1 behavior | PASS | CI and 100,000-run M1 differential fuzz pass. |
| Preserve existing M2 tests and 100,000-run fuzz | PASS | M2 unit test count is now 16 after adding meaningful missing branch coverage. |
| Real Ethereum mainnet fork tests with env RPC and pinned block | BLOCKED | Tests are implemented, but cannot be executed until `RPC_URL` and `BLOCK` are set. |
| Actual Chainlink ETH/USD feed | PASS in code/test setup; BLOCKED for live execution | Fork test uses official ETH/USD feed address. |
| Actual Uniswap v4 StateView and ETH/USDC pool | PASS in code/test setup; BLOCKED for live execution | Fork test uses official StateView and SDK ETH/USDC pool key; live initialization check requires RPC. |
| Actual Uniswap v3 ETH/USDC TWAP fallback | PASS in code/test setup; BLOCKED for live execution | Fork test resolves v3 pool through official factory. |
| Native ETH/WETH mapping, ordering, decimals, inversion | PASS locally; BLOCKED for live execution | Unit tests cover native/WETH behavior; fork test verifies live WETH/USDC ordering. |
| Stale, zero, negative, clamped, reverted, invalid oracle responses | PASS | Runtime reverted feed paths added. |
| Wrong feed orientation, wrong decimals, deviation boundaries, v3 reversed ordering, insufficient TWAP history, manipulated spot | PASS locally; BLOCKED for live manipulated/fork execution | Unit tests cover most; fork test includes live wrong orientation/decimals and manipulated spot via state override. |
| L1 sequencer feed is zero; L2 safety retained | PASS locally; BLOCKED for live execution | Constructor uses zero sequencer feed for mainnet; L2 mock tests pass. |
| Remaining M2 branch checks | PASS | PriceGuard remains 100% line/function coverage. |
| Slither/Aderyn | BLOCKED | Tools not installed locally. |
| No state-changing external/public function except `setPairConfig` | PASS | Verified with `forge inspect PriceGuard methods`. |
| Solidity 0.8.26, licensing, architecture, size limits | PASS | Build uses Solc 0.8.26; size within EIP-170 limit. |

## Remaining Risks

- Real fork verification is not complete until `RPC_URL` and `BLOCK` are provided and the fork test command passes.
- Chainlink ETH/USD assumes token1 is a dollar-like stablecoin. A USDC depeg is not handled by a second feed in M2; this is documented as a design limitation from the guide.
- v3 TWAP fallback security depends on selecting deep-liquidity pools and suitable windows. The owner/timelock must configure these conservatively.
- Slither and Aderyn findings are unavailable until those tools are installed and run.

## Commands To Unblock

```powershell
$env:RPC_URL = "<ethereum-mainnet-rpc-url>"
$env:BLOCK = "<pinned-mainnet-block>"
forge test --profile fork --match-path "test/fork/*" --fork-url $env:RPC_URL --fork-block-number $env:BLOCK -vv
```

Optional security tools:

```powershell
slither .
aderyn .
```
