// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPriceGuard} from "../../src/interfaces/IPriceGuard.sol";
import {
    Band,
    Currency,
    DepositMode,
    Plan,
    PoolKey,
    RebalanceParams,
    Strategy,
    VaultConfig
} from "../../src/libraries/Types.sol";

/**
 * @dev Locks the ABI shape of every shared type. Field order and enum ordinals are part of the ABI that later
 *      milestones, events, indexers and the front end depend on, and `PoolKey` must match Uniswap's layout exactly.
 *      A failure here means a type changed: update docs and every dependant deliberately, never silently.
 */
contract TypesLayoutTest is Test {
    function test_pool_key_abi_layout_is_five_static_words_in_uniswap_order() public pure {
        PoolKey memory key = PoolKey(Currency.wrap(address(0xC0)), Currency.wrap(address(0xC1)), 500, 10, address(0xAB));
        bytes memory encoded = abi.encode(key);
        assertEq(encoded.length, 5 * 32);
        (address c0, address c1, uint24 fee, int24 spacing, address hooks) =
            abi.decode(encoded, (address, address, uint24, int24, address));
        assertEq(c0, address(0xC0));
        assertEq(c1, address(0xC1));
        assertEq(fee, 500);
        assertEq(spacing, 10);
        assertEq(hooks, address(0xAB));
    }

    function test_enum_ordinals_are_stable() public pure {
        assertEq(uint8(Strategy.NormalLP), 0);
        assertEq(uint8(Strategy.BuyTheDip), 1);
        assertEq(uint8(Strategy.SellThePump), 2);
        assertEq(uint8(type(Strategy).max), 2, "a new strategy was added: review docs and deposit-mode mapping");

        assertEq(uint8(DepositMode.BothTokens), 0);
        assertEq(uint8(DepositMode.Token0Only), 1);
        assertEq(uint8(DepositMode.Token1Only), 2);
        assertEq(uint8(type(DepositMode).max), 2);
    }

    function test_band_layout() public pure {
        Band memory band = Band({tickLower: -60, tickUpper: 120, tokenId: 7, liquidity: 9});
        (int24 lower, int24 upper, uint256 tokenId, uint128 liquidity) =
            abi.decode(abi.encode(band), (int24, int24, uint256, uint128));
        assertEq(lower, -60);
        assertEq(upper, 120);
        assertEq(tokenId, 7);
        assertEq(liquidity, 9);
        assertEq(abi.encode(band).length, 4 * 32);
    }

    /**
     * @dev VaultConfig is fully static: the five PoolKey words are inlined, followed by the strategy fields in the
     *      order given by the developer guide with `baseIsCurrency0` appended last.
     */
    function test_vault_config_layout_and_field_names_match_the_guide() public pure {
        VaultConfig memory config = VaultConfig({
            poolKey: PoolKey(Currency.wrap(address(1)), Currency.wrap(address(2)), 3, 4, address(5)),
            strategy: Strategy.SellThePump,
            shapeId: 6,
            centerTick: -7,
            ticksLeft: 8,
            ticksRight: 9,
            driftTicks: 10,
            trailTicks: 11,
            autoRebalance: true,
            lockOnFill: true,
            depositCap: 12,
            baseIsCurrency0: true
        });
        bytes memory encoded = abi.encode(config);
        assertEq(encoded.length, 16 * 32);

        uint256[16] memory words = _words(encoded);
        assertEq(words[0], 1); // poolKey.currency0
        assertEq(words[1], 2); // poolKey.currency1
        assertEq(words[2], 3); // poolKey.fee
        assertEq(words[3], 4); // poolKey.tickSpacing
        assertEq(words[4], 5); // poolKey.hooks
        assertEq(words[5], 2); // strategy
        assertEq(words[6], 6); // shapeId
        assertEq(int256(words[7]), -7); // centerTick
        assertEq(words[8], 8); // ticksLeft
        assertEq(words[9], 9); // ticksRight
        assertEq(words[10], 10); // driftTicks
        assertEq(words[11], 11); // trailTicks
        assertEq(words[12], 1); // autoRebalance
        assertEq(words[13], 1); // lockOnFill
        assertEq(words[14], 12); // depositCap
        assertEq(words[15], 1); // baseIsCurrency0
    }

    function test_rebalance_params_layout() public pure {
        RebalanceParams memory params = RebalanceParams({newCenterTick: -100, maxSlippageBps: 30});
        (int24 center, uint16 slippage) = abi.decode(abi.encode(params), (int24, uint16));
        assertEq(center, -100);
        assertEq(slippage, 30);
    }

    function test_plan_has_every_field_the_vault_re_checks() public pure {
        Plan memory plan;
        plan.bands = new Band[](1);
        plan.weightsBps = new uint16[](1);
        plan.weightsBps[0] = 10_000;
        plan.needsSwap = true;
        plan.zeroForOne = true;
        plan.swapAmountIn = 1;
        plan.lockIdle = false;
        assertEq(plan.bands.length, 1);
        assertEq(plan.weightsBps[0], 10_000);
    }

    /**
     * @dev PairConfig field order is part of the ABI of `setPairConfig` and of the `PairConfigSet` event.
     */
    function test_pair_config_layout_matches_the_guide() public pure {
        IPriceGuard.PairConfig memory config = IPriceGuard.PairConfig({
            chainlinkFeed: address(1),
            invertFeed: true,
            maxStaleness: 3,
            minAnswer: 4,
            maxAnswer: 5,
            v3Pool: address(6),
            invertV3: true,
            twapWindow: 7,
            maxDeviationBps: 8
        });
        bytes memory encoded = abi.encode(config);
        assertEq(encoded.length, 9 * 32);
        uint256[9] memory words;
        for (uint256 i; i < 9; ++i) {
            words[i] = abi.decode(_slice(encoded, i * 32), (uint256));
        }
        assertEq(words[0], 1);
        assertEq(words[1], 1);
        assertEq(words[2], 3);
        assertEq(words[3], 4);
        assertEq(words[4], 5);
        assertEq(words[5], 6);
        assertEq(words[6], 1);
        assertEq(words[7], 7);
        assertEq(words[8], 8);
    }

    function _words(bytes memory encoded) private pure returns (uint256[16] memory words) {
        for (uint256 i; i < 16; ++i) {
            words[i] = abi.decode(_slice(encoded, i * 32), (uint256));
        }
    }

    function _slice(bytes memory data, uint256 start) private pure returns (bytes memory out) {
        out = new bytes(32);
        for (uint256 i; i < 32; ++i) {
            out[i] = data[start + i];
        }
    }
}
