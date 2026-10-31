# M10 Coverage Report

Measured on 2026-10-26 with Foundry 1.8.4:

```bash
forge coverage --report summary --no-match-coverage "^(test|script)/"
```

Result: **584 passed, 0 failed, 8 fork suites skipped** (no RPC was supplied to this non-fork command).

| Metric | Covered | Total | Percent | M10 gate |
| --- | ---: | ---: | ---: | --- |
| Lines | 1,984 | 1,991 | 99.65% | Pass (>=95%) |
| Statements | 2,704 | 2,758 | 98.04% | Informational |
| Branches | 586 | 644 | 90.99% | Pass (>=90%) |
| Functions | 280 | 280 | 100.00% | Pass |

## Remaining uncovered surface

No production function is wholly uncovered. Seven production lines and 58 branch paths remain. The concentrations are:

| File | Lines | Statements | Branches | Uncovered branch paths |
| --- | ---: | ---: | ---: | ---: |
| `Zap.sol` | 97.69% | 93.60% | 72.29% | 23 |
| `Vault.sol` | 99.78% | 98.52% | 92.65% | 10 |
| `VaultM5Module.sol` | 100.00% | 98.46% | 92.38% | 8 |
| `VaultM6Module.sol` | 100.00% | 97.92% | 90.41% | 7 |
| `NormalLPMath.sol` | 100.00% | 91.67% | 62.50% | 3 |
| `SwapMath.sol` | 100.00% | 83.33% | 50.00% | 2 |
| Other production files | >=97.44% lines each | varies | five paths total | 5 |

The aggregate acceptance thresholds are met without excluding production files or adding artificial coverage-only contracts. CI now parses and enforces both aggregate line and branch values. The lower per-file branch percentages in compact math and Zap conditionals are retained as transparent follow-up targets; all their externally callable functions are exercised and the math is also covered by differential/property tests.
