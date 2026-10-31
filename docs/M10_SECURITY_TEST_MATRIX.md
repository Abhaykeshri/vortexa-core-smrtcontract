# M10 Security Test Matrix

Measured on 2026-10-26 from `milestone/M10` at the M9 base commit `231f62e1fc786470b58901c712f8b4817a33b935`. The repository contains 78 Solidity test files, 562 `test*` functions, and 45 stateful invariant functions.

| Requirement | Primary evidence | Gate |
| --- | --- | --- |
| Unit behavior, errors, events, access control | `test/unit/` | `forge test --profile ci --match-path "test/unit/*.t.sol"` |
| Accounting and math fuzzing | `test/fuzz/` plus fuzz tests in unit/integration/attack suites | CI profile: 10,000 runs |
| Stateful vault lifecycle | `test/invariant/VaultFullLifecycleInvariant.t.sol`, `VaultRealV4Invariant.t.sol`, `VaultM5RealV4Invariant.t.sol`, `VaultM6RealV4Invariant.t.sol` | CI profile: 1,000 runs, depth 128 |
| Math and shape invariants | `PriceGuardInvariant.t.sol`, `ShapeLibraryInvariant.t.sol`, `CurrencyLibInvariant.t.sol`, `MathDifferential.t.sol` | Differential and stateful checks |
| Strategy-side correctness | `VaultM7OneSidedInvariant.t.sol`, `Strategies.t.sol` | Both orientations and all three approved strategies |
| Factory/config immutability | `M8FactoryInvariant.t.sol`, `M8FactoryValidation.t.sol` | Existing vaults unchanged by future registry policy |
| Zap custody and authorization | `M9ZapInvariant.t.sol`, `M9ZapAttacks.t.sol` | No retained caller funds or standing approvals |
| Attack catalogue | `test/attack/` | See `M10_ATTACK_TEST_REPORT.md` |
| Real dependencies | `test/fork/` at block 26,275,306 | Separate RPC-gated CI job |
| Deployment graph | `M9Scripts.t.sol`, `M8Scripts.t.sol`, fork deploy suites | Code presence and immutable cycle assertions |
| Static analysis | `test-reports/M10-Security-20261026/{slither-final.json,aderyn.md}` | New Slither High or Aderyn High fails CI |
| Targeted formal checks | `test/formal/M10Halmos.t.sol` | Liquidity, share rounding, and all shape IDs |
| Mutation testing | Gambit evidence plus `Run-M10MutationCampaign.ps1` | Final 40/40 killed (100%) |
| Coverage | Foundry production-only summary | >=95% lines and >=90% branches |
| Gas regression | `.gas-snapshot` | Deterministic tests, 1% tolerance |
| Contract size | `forge build --sizes`, `SrcPolicy.t.sol` | Every production runtime <24,576 bytes |
| License/import policy | `SrcPolicy.t.sol` and CI shell scan | No BUSL production source/import |

The targeted Halmos and Gambit campaigns were completed locally. The long-duration 72-hour Echidna/Medusa soak, independent review, and signed freeze process require dedicated external infrastructure and remain release blockers. Short Foundry equivalents do not constitute those external results.
