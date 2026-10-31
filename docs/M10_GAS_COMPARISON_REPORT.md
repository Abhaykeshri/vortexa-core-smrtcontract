# M10 Gas and Contract Size Report

## Contract size

Measured with Foundry 1.8.4, Solidity 0.8.26, optimizer 200 runs, Cancun, no CBOR metadata.

| Production contract | Runtime bytes | EIP-170 headroom |
| --- | ---: | ---: |
| Vault | 24,264 | 312 |
| VaultM5Module | 20,988 | 3,588 |
| VaultM6Module | 15,013 | 9,563 |
| Zap | 14,686 | 9,890 |
| PriceGuard | 10,550 | 14,026 |
| VaultFactory | 10,243 | 14,333 |
| NormalLPStrategy | 6,590 | 17,986 |
| VaultLens | 6,006 | 18,570 |
| SwapExecutor | 5,931 | 18,645 |
| BuyTheDipStrategy | 4,524 | 20,052 |
| SellThePumpStrategy | 4,524 | 20,052 |
| ShapeLibrary | 3,161 | 21,415 |
| FeeCollector | 1,713 | 22,863 |

Every production runtime is below 24,576 bytes. Vault is the limiting contract and must not absorb additional feature logic without re-measurement.

## Gas regression policy

`.gas-snapshot` was regenerated after the security campaign so it includes the complete deterministic M9/M10 suite and the new mutation-survivor regression. CI runs `forge snapshot --check --tolerance 1 --no-match-test "testFuzz|invariant"`, flagging changes above 1%. Fuzz/invariant gas is excluded because selector sequences and seeds vary. The five-band worst-case rebalance is exercised by `test_five_band_rebalance_with_a_swap_and_its_gas`; bounded shape generation is checked by unit, fuzz, attack, and invariant tests. The M10 production-source edits are analysis comments only, so runtime bytecode and protocol gas behavior are unchanged.
