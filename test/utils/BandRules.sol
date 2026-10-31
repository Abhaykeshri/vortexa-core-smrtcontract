// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Band} from "../../src/libraries/Types.sol";

/**
 * @dev The checks the developer guide says the vault must repeat on any bands returned by a shape library or a
 *      strategy before minting, because the library address cannot be trusted blindly (guide 5.3 and 9.5):
 *      band count, weights length and sum, non-empty bands, tick alignment, usable range, and contiguity.
 *      Returns an empty string when the bands are acceptable, otherwise the first violated rule. Reusable by the
 *      M4+ vault tests.
 */
library BandRules {
    int256 internal constant MIN_TICK = -887272;
    int256 internal constant MAX_TICK = 887272;

    function check(Band[] memory bands, uint16[] memory weights, int24 spacing, uint8 maxBands)
        internal
        pure
        returns (string memory reason)
    {
        if (spacing <= 0) return "spacing not positive";
        if (bands.length == 0) return "no bands";
        if (bands.length > maxBands) return "too many bands";
        if (weights.length != bands.length) return "weights length mismatch";

        int256 s = int256(spacing);
        int256 minUsable = -((MAX_TICK) / s) * s; // MIN_TICK == -MAX_TICK, so ceil(MIN / s) * s == -floor(MAX / s) * s
        int256 maxUsable = (MAX_TICK / s) * s;
        uint256 sum;
        for (uint256 i; i < bands.length; ++i) {
            int256 lower = bands[i].tickLower;
            int256 upper = bands[i].tickUpper;
            if (lower >= upper) return "empty or inverted band";
            if (lower % s != 0 || upper % s != 0) return "misaligned tick";
            if (lower < minUsable || upper > maxUsable) return "outside usable range";
            if (i > 0 && bands[i - 1].tickUpper != bands[i].tickLower) return "gap or overlap";
            if (bands[i].tokenId != 0 || bands[i].liquidity != 0) return "planned band carries state";
            sum += weights[i];
        }
        if (sum != 10_000) return "weights do not sum to 10000";
        return "";
    }
}
