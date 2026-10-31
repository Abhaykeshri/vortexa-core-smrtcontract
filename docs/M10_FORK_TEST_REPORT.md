# M10 Mainnet Fork Test Report

| Field | Value |
| --- | --- |
| Chain | Ethereum mainnet (chain id 1) |
| Pinned block | 26,275,306 |
| Address source | `script/NetworkConfigs.s.sol` |
| RPC input | `MAINNET_RPC_URL` (infrastructure only; never a contract dependency address) |
| Command | `forge test --profile fork --fork-url "$MAINNET_RPC_URL" --fork-block-number 26275306 --match-path "test/fork/*.t.sol" -vvv` |

The fresh M10 replay completed on 2026-10-26 against the pinned block: **35 passed, 0 failed, and 1 intentionally skipped** across eight suites. The skip is `M8MainnetForkTest`, which has no separately deployed M8 mainnet instance; the deployment-path fork test still ran and passed. The campaign covers both swap directions, native and ERC-20 pools, real Permit2/Universal Router/PositionManager/StateView interactions, repeated deposits, withdrawals, rebalances, Zap, oracle manipulation rejection, and deployment graph validation.

CI has a separate `fork` profile job, requires a non-empty archive RPC secret, selects `test/fork/*.t.sol`, and requires zero failures plus exactly the one documented skip. The public replay endpoint was infrastructure only; every dependency address remained sourced from `script/NetworkConfigs.s.sol`.
