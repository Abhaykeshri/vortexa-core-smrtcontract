# M8 Security Review

> **Superseded in part by `docs/M8_AUDIT_REPORT.md` (2026-10-24).** That audit fixed the post-deploy check (it did not enforce "the deployer holds no role"), the Safe handover scripts, the Safe minimums and the missing mainnet Zap guard, and added a real-v4 factory suite, a role matrix and a mainnet deployment rehearsal. It also corrects these claims: "Source policy PASS" held only because the policy accepted `///` NatSpec, the "factory lifecycle integration" test runs on mocks, and the deployer can do more than "the ownership actions encoded by the script" before the handover.

## Result

No unresolved high-severity defect was found in the locally executable M8 scope. This is an internal engineering review, not an independent audit or authorization to deploy.

## Control matrix

| Area | Control |
|---|---|
| Clone initialization | Vault implementation is constructor-locked; only the immutable factory can initialize a clone; factory registers after initialization succeeds |
| Deterministic deployment | Salt commits to creator, normalized full config, name, and symbol; prediction uses the current implementation and factory deployer |
| Dependency substitution | Factory validates the implementation and executor's immutable factory, oracle, modules, PositionManager, Permit2, PoolManager, and StateView relationships |
| Configuration immutability | Clone config and strategy are written once; registry changes apply only to future clones |
| Pool admission | Hookless, governance-allowlisted, initialized, sorted V4 pools with configured/trusted oracle, valid shape/range, and bounded nonzero cap |
| Governance | 48-hour mainnet floor, Safe proposer/canceller, restricted executor, deployer admin removed, two-step ownership acceptance |
| Guardian | May pause a Vault directly; cannot unpause, rebalance, change policy, or move funds |
| Keeper | May call existing keeper-gated compound/rebalance paths; cannot administer roles or bypass Vault safety checks |
| Protocol fees | Current fee cannot exceed mutable governance cap; cap cannot exceed 100%; existing M5 settlement never charges principal |
| Fee custody | Anyone may flush the full balance, but only to the fixed recipient; nonReentrant native forwarding and SafeERC20 handling |
| Lens | No state changes; registry-gated; bounded batches; optional downstream failures are surfaced explicitly |
| Existing vaults | No storage/layout change; configuration, strategy, custody, and implementation remain fixed |

## Trust assumptions

- Timelock proposers/executors and the treasury addresses are operationally secure.
- Governance can approve economically dangerous fees up to 100%, malicious future strategies, collectors, or implementations. The delay makes these changes observable but does not make compromised governance harmless.
- PriceGuard configuration and external oracle correctness remain foundational trust dependencies.
- A strategy is treated as governance-approved code. The Vault independently checks safety-critical plans, but a strategy can still deny service by reverting.
- `renounceOwnership` remains inherited per the approved design. Governance must not renounce ownership of policy contracts.

## Issues found and resolved

- A test oracle mock originally returned one pair configuration for every pool, masking missing-oracle rejection. It now keys config by pool id.
- The guide's stated deployment order was incompatible with the M7 Vault constructor. The script deploys SwapExecutor before Vault and verifies the predicted factory address.
- Open timelock execution was rejected; only the configured executor receives `EXECUTOR_ROLE`.
- Registry writes occur after successful initialization, and a regression proves failed attempts consume neither registry state nor the deterministic address.
- FeeCollector recipient callbacks cannot reenter collection; the outer transfer remains atomic.
- Lens zero values are separated from failed reads through availability flags.

## Residual risk

An external audit, mainnet-fork dry run with final addresses, governance ceremony rehearsal, Safe signer verification, and transaction simulation are still required before deployment.

## Static analysis

Aderyn ran all 88 detectors over the three new production contracts. Its initial report contained one High category (`reentrancy-state-change`) covering three calls in `createVault`; each is a reviewed false positive because the function is `nonReentrant`, strategy validation is static, transaction rollback is atomic, and the specification requires registration only after initializer success. Scoped annotations document that reasoning at each call. Low categories were governance centralization (intentional Timelock control), readable large literals/constants, bounded fail-closed Lens loops, implicit zero loop counters, and a CurrencyLib transfer that internally uses OpenZeppelin SafeERC20. Slither was not installed.
