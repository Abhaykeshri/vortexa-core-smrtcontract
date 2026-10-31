# M8 Known Issues and Verification Limits

> **Superseded in part by `docs/M8_AUDIT_REPORT.md` (2026-10-24).** That audit fixed the post-deploy check (it did not enforce "the deployer holds no role"), the Safe handover scripts, the Safe minimums and the missing mainnet Zap guard, and added a real-v4 factory suite, a role matrix and a mainnet deployment rehearsal. It also corrects these claims: "Source policy PASS" held only because the policy accepted `///` NatSpec, the "factory lifecycle integration" test runs on mocks, and the deployer can do more than "the ownership actions encoded by the script" before the handover.

- `NetworkConfigs.s.sol` intentionally retains zero placeholders for the governance Safe, authorized executor, guardian Safe, treasury, deployed PriceGuard, deployed ShapeLibrary, M8 addresses, and ETH/USDC deposit cap. Deployment is blocked until these are reviewed and populated.
- The ownership handover is not complete at deployment time. `VaultFactory`, `FeeCollector`, and `PriceGuard` first nominate the timelock; the governance Safe must schedule the batch, wait at least 48 hours on mainnet, and the restricted executor must execute it.
- No production or testnet transaction was broadcast, and no final-address fork test could be run before addresses exist.
- CREATE address prediction is nonce-sensitive. The deployment script validates the starting nonce and final factory address atomically; operators must not insert a deployment into the sequence.
- `VaultLens` deliberately fails closed for malformed core vault identity/config reads, while optional accounting and pool-state reads use availability flags. Consumers must inspect those flags and not interpret an unavailable value as zero.
- The absolute fee safety ceiling is 100%. This preserves the approved mutable-cap architecture but permits governance to set a confiscatory fee after the timelock delay. No unapproved fee rate limit was added.
- `renounceOwnership` is inherited as approved. Renouncing on PriceGuard, Factory, or FeeCollector would permanently disable the corresponding governance surface.
- Strategy registry entries are arbitrary governance-approved contracts. Existing clones retain their strategy; future creation calls the strategy's validator, but a reverting strategy can deny new creation for that strategy kind.
- Factory implementation validation cannot introspect the Vault constructor's ShapeLibrary argument because the current Vault exposes no getter and does not consume that immutable directly. The factory validates its own ShapeLibrary and all exposed custody/oracle/executor dependencies; deployment supplies the same library to Vault and every strategy.
- Pool allowlisting is for new vault creation. Disabling a pool does not alter or disable existing vaults.
- `isRouter` and `setRouter` are intentionally absent because the later M9 correction removes them.
