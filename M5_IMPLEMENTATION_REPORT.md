# M5 Implementation Report

## Scope

Implemented Milestone M5: Withdraw, Fees & Views on branch `milestone/M5`.

No production M8 Factory or FeeCollector contracts were added. M5 uses expanded interfaces and test mocks only.

Post-merge update on 2026-10-13: the unresolved stash conflicts were resolved semantically by preserving the latest M4 security fixes and retaining M5 functionality. `mint()`, `previewMint()` and `maxMint()` are present for ERC-4626 compatibility.

## Changed Files

- `src/Vault.sol`
- `src/interfaces/IVault.sol`
- `src/interfaces/IVaultFactory.sol`
- `src/interfaces/IStrategy.sol`
- `src/interfaces/IFeeCollector.sol`
- `test/mocks/VaultMocks.sol`
- `test/unit/Vault.t.sol`

`script/NetworkConfigs.s.sol` remains the single network dependency configuration source and was not duplicated.

## Implemented Interfaces and Mocks

`IVaultFactory` now exposes:

- `protocolFeeBps()`
- `maxProtocolFeeBps()`
- `setProtocolFeeBps(uint256)`
- `setMaxProtocolFeeBps(uint256)`
- `feeCollector()`
- `isKeeper(address)`
- `isVault(address)`

The M5 factory mock implements owner-only setters, constructor-configured initial values, event emission, and validation:

- `protocolFeeBps <= maxProtocolFeeBps <= 10_000`
- current fee cannot be raised above the current max
- max cap cannot be reduced below the current fee

Added a minimal FeeCollector interface and mock.

Expanded the M7 strategy interface and mock with `checkTrigger(...)` so M5 `checkRebalance()` can be implemented without production M7 strategy contracts.

## Raj Sir Deviation From PDF

The PDF described `MAX_PROTOCOL_FEE_BPS` as a code constant. Raj Sir confirmed a superseding M5 requirement:

- the current protocol fee is mutable through `setProtocolFeeBps`
- the maximum permitted protocol fee cap is also mutable through `setMaxProtocolFeeBps`
- the maximum cap is stored as state, not as a Solidity constant

This behavior is implemented in the M5 factory mock and exposed through `IVaultFactory`.

## Vault Changes

Added `withdrawPair(shares, min0, min1, receiver)`:

- burns only the caller's shares
- snapshots total supply, idle balances and pending fees before external calls
- removes proportional Uniswap v4 liquidity with `DECREASE_LIQUIDITY`
- uses `TAKE_PAIR` to receive assets into the vault
- deducts protocol fees only from pending trading fees
- distributes principal, idle balances and net fees proportionally
- supports native ETH through existing `CurrencyLib`
- does not check pause state, PriceGuard or keeper authorization

Preserved the existing M4 ERC-4626 `withdraw` and `redeem` behavior.

Added permissionless `collectFees()`:

- uses zero-liquidity `DECREASE_LIQUIDITY`
- takes fees to the vault
- reads `factory.protocolFeeBps()` dynamically
- transfers protocol fees to `factory.feeCollector()`
- leaves net fees idle for shareholders

Added keeper-only `compound()`:

- checks `factory.isKeeper(msg.sender)`
- requires not paused
- requires PriceGuard trust
- deploys idle balances proportionally into existing bands
- does not mint or burn shares
- reuses existing exact Permit2 approval lifecycle

Added `checkRebalance()`:

- returns false for paused, auto-rebalance off or untrusted/reverting PriceGuard
- delegates trigger logic to the strategy mock through `checkTrigger`

## Security Decisions

- Withdrawals intentionally bypass pause, oracle and keeper gates.
- Protocol fees are charged only against collected trading fees, never principal.
- Protocol fee values are read at settlement time and are not cached by the vault.
- If protocol fee amounts are zero, the vault does not require a configured collector.
- Receiver zero checks remain in place before native transfers.
- `nonReentrant` protects withdraw, fee collection and compound paths.
- Dust from proportional rounding remains in the vault for remaining shareholders.
- M4 V1-V6 protections were preserved during conflict resolution: `CLOSE_CURRENCY` settlement, PriceGuard-gated ERC-4626 exits, forced-ETH accounting, transfer-hook price-change protection, full ERC-4626 mint surface, pause authorization, restricted NFT receiver callbacks and reentrancy guards.

## Limitations

- Production M8 Factory and FeeCollector are not implemented by design.
- Production M7 strategies are not implemented; M5 uses a mock strategy surface.
- No NetSpec document was available, so multi-network completeness was not claimed.
- Real Ethereum mainnet fork tests were executed with `https://ethereum.publicnode.com`: 15 passed, 0 failed, 0 skipped.
- Deployment readiness is blocked: the semantically merged secure Vault runtime is 27,459 bytes, which exceeds EIP-170 by 2,883 bytes. Further reduction likely requires a deliberate architecture split rather than deleting M0-M5 behavior or V1-V6 protections.
