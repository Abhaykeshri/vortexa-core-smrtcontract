// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "./Types.sol";

/**
 * @title Pool Id Library
 * @notice Computes deterministic pool identifiers from Vortexa/Uniswap V4 pool keys.
 * @dev The encoding is intentionally ABI encoding of the complete `PoolKey`.
 *
 *      The identifier is the same value Uniswap v4 uses as `PoolId`, so it can be passed directly to `StateView`
 *      reads. Equality with Uniswap's `PoolIdLibrary` is asserted by a differential test.
 */
library PoolIdLib {
    /**
     * @notice Computes the canonical identifier for a pool key.
     * @dev The field order and ABI encoding match Uniswap v4 PoolKey: `currency0`, `currency1`, `fee`,
     *      `tickSpacing`, `hooks`, each occupying one 32-byte word. Changing the order or the field types would
     *      silently produce ids for non-existent pools.
     * @param key The five-word, statically encoded pool key.
     * @return id The keccak256 hash of the ABI-encoded key.
     */
    function toId(PoolKey memory key) internal pure returns (bytes32 id) {
        return keccak256(abi.encode(key));
    }
}
