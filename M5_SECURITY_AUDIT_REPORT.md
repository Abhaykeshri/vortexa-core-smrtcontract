# M5 Security Audit Report

Date: 2026-10-13

## Verdict

FAIL for deployment readiness due to EIP-170 bytecode size.

No Critical or High functional test failure is currently reproduced in the executed local and fork suites, but the Vault runtime is 27,459 bytes and cannot be deployed as-is.

## Merge Resolution

- Resolved all Git conflict markers in the reported conflict files.
- Preserved M4 V1-V6 security fixes:
  - independent `CLOSE_CURRENCY` settlement for deposits
  - PriceGuard validation for ERC-4626 `withdraw` and `redeem`
  - safe forced-ETH accounting
  - transfer-hook price movement rejection
  - ERC-4626 `mint`, `previewMint` and `maxMint`
  - guardian pause and owner/factory unpause authorization
  - restricted ERC-721 receiver callback during PositionManager calls only
- Retained M5 `withdrawPair`, `collectFees`, `compound`, `checkRebalance`, mutable fee mock behavior and related interfaces.

## Verified Security Areas

- Reentrancy: `withdrawPair`, `collectFees`, `compound`, deposit, withdraw and redeem paths remain `nonReentrant` where state/external-call sequencing requires it.
- Fee/principal separation: protocol fees are calculated from pending/collected fees and not principal.
- Withdrawal safety: `withdrawPair` does not depend on pause, oracle trust or keeper availability.
- ERC-4626 exits: `withdraw` and `redeem` remain PriceGuard-gated.
- NFT receiver: foreign or unexpected position NFT pushes revert through `UnexpectedNft`.
- Mutable protocol fees: mock factory validates authorization and fee/cap bounds.

## Executed Evidence

- `forge fmt --check`: PASS
- `forge test -vv`: 308 passed, 0 failed, 2 skipped
- `forge test --fuzz-runs 10000 -vv`: 308 passed, 0 failed, 2 skipped
- `forge test --match-path test/fork/* --fork-url https://ethereum.publicnode.com -vv`: 15 passed, 0 failed, 0 skipped
- `forge build --sizes`: FAIL, Vault runtime 27,459 bytes

## Remaining Blockers

- Critical deployment blocker: Vault exceeds EIP-170 by 2,883 bytes.
- Static analysis tools were not run in this pass: Slither, Aderyn and Halmos are NOT RUN.
- Coverage was not rerun after the final semantic merge.
- `VaultRealV4InvariantTest` still runs at 48 runs by suite configuration, while other invariant suites observed 256 runs.

## Recommendation

Do not deploy this M5 Vault as a monolithic contract. The next safe step is an approved architecture change to split size-heavy M5 logic into a storage-safe module or equivalent pattern, followed by full regression, fork, fuzz, invariant, coverage and static-analysis reruns.
