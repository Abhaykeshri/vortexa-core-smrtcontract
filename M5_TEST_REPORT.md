# M5 Test Report

Date: 2026-10-13

## Verification Summary

Final status: FAIL for deployment readiness.

Reason: after resolving the M4/M5 merge semantically and restoring `mint()`, `previewMint()`, and `maxMint()` while preserving V1-V6 security fixes, `Vault` runtime bytecode is 27,459 bytes. This is 2,883 bytes over the EIP-170 limit of 24,576 bytes.

Functional tests executed successfully, but the Vault cannot be deployed as a single contract in its current secure M0-M5 shape.

## Commands Run

```text
forge clean
forge fmt --check
forge build --sizes
forge build --sizes --optimizer-runs 1
forge test -vv
forge test --match-path test/fork/* --fork-url https://ethereum.publicnode.com -vv
forge test --fuzz-runs 10000 -vv
```

## Exact Results

`forge fmt --check`

- Result: PASS

`forge build --sizes`

- Result: FAIL on EIP-170 size check
- Compile status: compiler run successful
- Vault runtime size: 27,459 bytes
- EIP-170 margin: 2,883 bytes over 24,576

`forge build --sizes --optimizer-runs 1`

- Result: FAIL on EIP-170 size check
- Vault runtime size: 27,459 bytes
- EIP-170 margin: 2,883 bytes over 24,576

`forge test -vv`

- Result: PASS
- Suites: 33
- Tests: 308 passed, 0 failed, 2 skipped
- Skips: local non-fork executions of `test/fork/PriceGuardMainnetFork.t.sol` and `test/fork/VaultMainnetFork.t.sol`

`forge test --match-path test/fork/* --fork-url https://ethereum.publicnode.com -vv`

- Result: PASS
- Suites: 2
- Tests: 15 passed, 0 failed, 0 skipped
- Vault mainnet fork tests: 10 passed, including real `withdrawPair()` liquidity decrease and user payout.
- PriceGuard mainnet fork tests: 5 passed.

`forge test --fuzz-runs 10000 -vv`

- Result: PASS
- Suites: 33
- Tests: 308 passed, 0 failed, 2 skipped
- Fuzz tests ran with 10,000 runs where applicable.
- Invariants observed in this run:
  - `VaultInvariantTest`: 256 runs, 16,384 calls.
  - `PriceGuardInvariantTest`: 256 runs, 16,384 calls.
  - `ShapeLibraryInvariantTest`: 256 runs, 16,384 calls.
  - `CurrencyLibInvariantTest`: 256 runs, 16,384 calls.
  - `VaultRealV4InvariantTest`: 48 runs, 1,920 calls by local suite configuration.

## Not Run After Merge

- `forge coverage --report summary`
- Slither
- Aderyn
- Halmos/formal tooling
- `forge snapshot`

## Remaining Blocker

The secure merged Vault is too large. Reaching EIP-170 without removing M0-M5 behavior likely requires an architectural split, such as moving M5 operational logic behind a module/facet/library pattern with explicit storage-safe design and new tests.
