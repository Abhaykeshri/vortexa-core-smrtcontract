# M10 Static Analysis Report

## Executed tools

Both required analyzers were run against the final 38-file production `src/` scope on 2026-10-26:

| Tool | Version / environment | Result | Evidence |
| --- | --- | --- | --- |
| Slither | 0.11.6, Windows, solc 0.8.26 | 185 findings; **0 High** | `test-reports/M10-Security-20261026/slither-final.json` |
| Aderyn | 0.6.8, WSL Ubuntu, solc 0.8.26 | **0 High / 2 Low** | `test-reports/M10-Security-20261026/aderyn.md` |

Slither initially emitted 12 High results. They were duplicate traces of two analyzer limitations:

- `Zap._deposit` sends native value only to an `IZapVault` already bound to `factory.isVault(vault)` by `_validatedVault`; Slither loses that registry proof across the private call.
- `Vault._depositPair` and delegated `VaultM5Module.withdrawPair` are reachable through `Vault` entry points protected by `nonReentrant`; Slither analyzes the internal/delegate module paths without propagating that external guard.

The affected sites now have narrow, adjacent suppressions with the missing proof stated in source. No detector was globally disabled and no runtime bytecode behavior changed. The final rerun contains zero High findings.

## Remaining triage

The only Medium/High-confidence result is `incorrect-equality` at `VaultLens.userPosition`: `position.shares == 0` is an intentional read-only early return. It neither controls a price nor authorizes value movement.

The 66 Medium/Medium results are dominated by module reentrancy/event ordering, immutable delegatecall architecture, bounded external calls, and deliberate numeric rounding. `Vault` guards every token-moving entry point with `nonReentrant`; module functions require delegated execution; module storage mirrors the Vault layout; loop bounds are capped by five bands; casts are range-checked or bounded at their call sites. These are architectural/static-analysis limitations already exercised by the attack, invariant, and fork suites, not demonstrated vulnerabilities.

Slither's `unimplemented-functions` result for `VaultFactory.strategyOf` is a false positive: Solidity's `public override` mapping at `src/VaultFactory.sol:79` supplies the interface getter and the compiler confirms the implementation. Zero-initialized locals and storage-mirror `constable-state` results likewise reflect Solidity semantics and delegatecall layout.

Aderyn's two Low categories are the bounded five-band Zap loops and token operations. Atomic loop failure is required, and token flows use SafeERC20, Permit2 plus measured balance deltas. Detailed detector-level reasoning remains in `docs/ADERYN_TRIAGE.md` and accepted operational limitations remain in `docs/known-issues.md`.

## Reproduction

```bash
slither . --config-file slither.config.json --json test-reports/M10-Security-20261026/slither-final.json
aderyn . -o test-reports/M10-Security-20261026/aderyn.md
```

The Aderyn command was executed inside WSL because Aderyn 0.6.8 does not publish a native Windows package. CI runs the same pinned version on Ubuntu.
