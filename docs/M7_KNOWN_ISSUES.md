# M7 Known Issues and Verification Limits

> **Superseded in part by `docs/M7_AUDIT_REPORT.md` (2026-10-22).** That audit fixed a first-deposit accounting defect (M7-01) and the CI workflow (M7-03), and corrects these claims: no `.gas-snapshot` existed, initialization-time validation was untested, the fork matrix ran at the latest block rather than the pinned one (which predated the Universal Router deployment), and the `Vault` size is now 24,348 bytes.

- Exact one-wei reproduction of the PDF's approximate 4,400-price and trailing examples is blocked because the original design-tab inputs (balances, exact ticks, weights and expected wei outputs) were unavailable. Documented formulas, independently derivable vectors and 100,000-run properties pass.
- The mainnet-fork matrix was independently rerun: 5 suites and 32/32 tests passed against Ethereum mainnet.
- Aderyn 0.6.8 was run through WSL with all 88 detectors and reports 0 High / 0 Low. Slither was not available for a fresh M7 run. Foundry and repository policy/security suites pass; an independent audit remains required before deployment.
- Normal LP first-deposit swap intent is executed atomically through `SwapExecutor`; ERC-20/ERC-20 and native/ERC-20 integration tests prove execution and allowance revocation. The vault independently enforces the 60% value cap and a one-percent oracle-derived output floor.
- The Vault remains below the EIP-170 limit with optimizer runs set to the guide's required 200. Future core features should continue using fixed storage-mirrored modules and must retain the size gate.
- The Vault constructor retains an otherwise unused ShapeLibrary parameter for deployment-interface compatibility; each production strategy has its own immutable ShapeLibrary dependency.
- M8+ factory/registry product work and production operations are outside M7. This implementation is not authorization to deploy user funds.
