# Aderyn Finding Triage

This document classifies the supplied Aderyn report against the current M0-M9 implementation. A finding is not removed by weakening atomic validation, storage compatibility, or token-safety checks.

The fresh M10 report at `test-reports/M10-Security-20261026/aderyn.md` was generated with Aderyn 0.6.8 and reports **0 high / 2 low**. The two Low findings are bounded-loop atomic reverts and token-operation warnings in `Zap`; band loops are capped at five, and transfers use SafeERC20 plus exact balance-delta checks. Real findings were fixed in code. Remaining analyzer limitations or accepted design choices use detector-specific, line-scoped `aderyn-fp` or `aderyn-ignore` annotations rather than a global detector exclusion.

| Finding | Disposition | Evidence/action |
|---|---|---|
| H-1 state after external call | FIXED / MITIGATED | `Vault.initialize` is now `nonReentrant`; a hostile approval callback test passes. All other reported module state changes execute only through Vault `nonReentrant` entry points, and direct module calls are rejected. The constructor instance is not externally callable while constructing. |
| L-1 centralization | ACCEPTED DESIGN | PriceGuard uses OpenZeppelin `Ownable2Step`; the configured owner/timelock is an explicit trust assumption with bounded configuration validation. |
| L-2 storage writes in loops | SAFE/BOUNDED | Position updates are required accounting effects and band count is capped at five. Deferring them would complicate CEI and does not remove the writes. |
| L-3 literals | INFORMATIONAL | Shape weights and TickMath constants are specification constants. Replacing every literal with a named constant would not change security and can increase bytecode pressure. |
| L-4 modifier used once | INTENTIONAL | `onlyDelegated` is a security boundary preventing direct mutation of module-local storage; inlining it provides no safety gain. |
| L-5 revert in loop | INTENTIONAL | Invalid bands, weights, positions, or encodings must revert the complete atomic operation. Loops are bounded (maximum five bands), so this is not unbounded gas griefing. |
| L-6 state change without event | FIXED | `VaultInitialized(strategy,poolId)` is emitted only after validation and approvals complete. |
| L-7 unchecked return | FALSE POSITIVE / INTENTIONAL | Low-level delegate helpers explicitly check success and bubble revert data. Validation calls are made for their revert semantics. Shape planning calls validate feasibility by reverting; their returned arrays are intentionally discarded. |
| L-8 uninitialized locals | FIXED | The two reported loop counters are explicitly initialized to zero. |
| L-9 unsafe ERC-20 | FALSE POSITIVE | Currency transfers use OpenZeppelin `SafeERC20`; reported `permit2.approve` calls are Permit2 operations, not ERC-20 calls. Exact balance-delta checks reject fee-on-transfer shortfalls. |
| L-10 unused errors | PARTLY FIXED / ABI INTENTIONAL | Stale `InvalidBands` was removed. `PermitAmountTooLarge` remains in the Vault ABI because the delegate module can revert with that selector. |
| L-11 unused state/constants | PARTLY FIXED / LAYOUT INTENTIONAL | Stale Vault-only band/tick constants were removed. `_initialized` fields in M5/M6 deliberately mirror the Vault slot layout; removing them would corrupt delegatecall storage. `FEE_TRANSFER_GAS` is used from inline assembly. |

## OpenZeppelin guard model

The project pins OpenZeppelin Contracts v5.7.0 and Cancun EVM. Vault therefore uses `ReentrancyGuardTransient`, the v5 guard variant recommended where EIP-1153 is available; SwapExecutor uses storage-backed `ReentrancyGuard`. Both expose one guard across all marked entry points, so guarded functions cannot call one another reentrantly. M5/M6 module code runs by delegatecall inside the already-entered Vault guard.

The legacy SwapExecutor overload always reverts before any state or external call, so its redundant modifier was removed. This eliminates the compiler's unreachable `_nonReentrantAfter` warning without reducing protection on the real `swapExactInput` path.

## Scoped analyzer annotations

- `aderyn-fp` marks analyzer false positives: constructor-only reentrancy, the Vault-wide transient guard across delegatecalls, Permit2 calls, CurrencyLib transfers backed by OpenZeppelin `SafeERC20`, inline-assembly constant use, and delegatecall storage mirrors.
- `aderyn-ignore` marks reviewed design choices: bounded atomic validation loops, required accounting writes, protocol math/shape constants, the explicit module security modifier, and the documented PriceGuard owner/timelock trust boundary.
- Every annotation names only the applicable detector and source line. No detector is disabled project-wide.
