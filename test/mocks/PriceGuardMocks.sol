// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IStateViewLike} from "../../src/interfaces/external/IStateViewLike.sol";
import {PriceGuard} from "../../src/PriceGuard.sol";

contract MockToken is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

contract MockExtremeDecimalsToken is ERC20 {
    constructor() ERC20("Extreme Decimals", "EXT") {}

    function decimals() public pure override returns (uint8) {
        return 78;
    }
}

contract MockStateView {
    mapping(bytes32 => uint160) public sqrtPrices;
    bool public revertGetSlot0;

    function setRevertGetSlot0(bool revertGetSlot0_) external {
        revertGetSlot0 = revertGetSlot0_;
    }

    function setSqrtPrice(bytes32 poolId, uint160 sqrtPriceX96) external {
        sqrtPrices[poolId] = sqrtPriceX96;
    }

    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        if (revertGetSlot0) revert("state view down");
        return (sqrtPrices[poolId], 0, 0, 0);
    }
}

contract MockAggregator {
    uint8 private immutable _feedDecimals;
    int256 public answer;
    uint256 public updatedAt;
    bool public revertDecimals;
    bool public revertLatestRoundData;

    constructor(uint8 decimals_) {
        _feedDecimals = decimals_;
    }

    function setAnswer(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function setRevertDecimals(bool revertDecimals_) external {
        revertDecimals = revertDecimals_;
    }

    function setRevertLatestRoundData(bool revertLatestRoundData_) external {
        revertLatestRoundData = revertLatestRoundData_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (revertLatestRoundData) revert("no round");
        return (1, answer, updatedAt, updatedAt, 1);
    }

    function decimals() external view returns (uint8) {
        if (revertDecimals) revert("no decimals");
        return _feedDecimals;
    }
}

contract MockMalformedV3Pool {
    address public immutable token0;
    address public immutable token1;
    bool public shortArray;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function setShortArray(bool shortArray_) external {
        shortArray = shortArray_;
    }

    function observe(uint32[] calldata)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidity)
    {
        tickCumulatives = new int56[](shortArray ? 1 : 2);
        if (!shortArray) tickCumulatives[1] = 0;
        secondsPerLiquidity = new uint160[](2);
    }
}

contract MockBadAggregator {
    function decimals() external pure {
        revert("no decimals");
    }
}

contract MockV3Pool {
    address public immutable token0;
    address public immutable token1;
    int56 public tickDelta;
    bool public shouldRevert;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function setTickDelta(int56 tickDelta_) external {
        tickDelta = tickDelta_;
    }

    function setShouldRevert(bool shouldRevert_) external {
        shouldRevert = shouldRevert_;
    }

    function observe(uint32[] calldata)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidity)
    {
        if (shouldRevert) revert("short history");
        tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = tickDelta;
        secondsPerLiquidity = new uint160[](2);
    }
}

contract MockBrokenV3Pool {
    function token0() external pure returns (address) {
        revert("broken token0");
    }
}

contract PriceGuardHarness is PriceGuard {
    constructor(MockStateView stateView_, address sequencer_, address nativeWrapper_, address owner_)
        PriceGuard(IStateViewLike(address(stateView_)), sequencer_, nativeWrapper_, owner_)
    {}

    function sqrtFromRatio(uint256 numerator, uint256 denominator) external pure returns (uint160) {
        return _sqrtFromRatio(numerator, denominator);
    }

    function floorDivTick(int56 numerator, int56 denominator) external pure returns (int24) {
        return _floorDivTick(numerator, denominator);
    }

    function ratioFits(uint256 numerator, uint256 denominator) external pure returns (bool) {
        return _ratioFits(numerator, denominator);
    }

    function scaledRatio(bool invert, uint256 answer, uint256 feedDecimals, uint8 decimals0, uint8 decimals1)
        external
        pure
        returns (bool ok, uint256 numerator, uint256 denominator)
    {
        return _scaledRatio(invert, answer, feedDecimals, decimals0, decimals1);
    }
}

/**
 * @dev ERC-20 whose decimals can change after deployment, to test the decimals cache.
 */
contract MockSettableDecimalsToken is ERC20 {
    uint8 public tokenDecimals;

    constructor(uint8 decimals_) ERC20("Settable", "SET") {
        tokenDecimals = decimals_;
    }

    function setDecimals(uint8 decimals_) external {
        tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }
}

/**
 * @dev Uniswap V3 pool mock that derives realistic tick cumulatives from a desired mean tick, so the
 *      observed mean tick stays consistent for any requested window.
 */
contract MockTwapPool {
    address public immutable token0;
    address public immutable token1;
    int24 public meanTick;
    int256 public spikeTicks;
    uint32 public spikeSeconds;
    bool public shouldRevert;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function setMeanTick(int24 meanTick_) external {
        meanTick = meanTick_;
    }

    /**
     * @dev Adds `spikeTicks_` of extra tick for the last `spikeSeconds_` seconds of the window.
     */
    function setSpike(int256 spikeTicks_, uint32 spikeSeconds_) external {
        spikeTicks = spikeTicks_;
        spikeSeconds = spikeSeconds_;
    }

    function setShouldRevert(bool shouldRevert_) external {
        shouldRevert = shouldRevert_;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidity)
    {
        if (shouldRevert) revert("short history");
        tickCumulatives = new int56[](2);
        // forge-lint: disable-next-line(unsafe-typecast)
        tickCumulatives[1] =
            int56(int256(meanTick) * int256(uint256(secondsAgos[0])) + spikeTicks * int256(uint256(spikeSeconds)));
        secondsPerLiquidity = new uint160[](2);
    }
}

/**
 * @dev Feed that tries to write storage from `decimals` and `latestRoundData` when `writeMode` is set. Because
 *      PriceGuard calls through a `view` interface (STATICCALL) every such write must revert.
 */
contract MockStateWritingFeed {
    uint256 public writes;
    bool public writeMode;
    int256 public answer;
    uint256 public updatedAt;

    function setAnswer(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function setWriteMode(bool writeMode_) external {
        writeMode = writeMode_;
    }

    function decimals() external returns (uint8) {
        if (writeMode) writes += 1;
        return 8;
    }

    function latestRoundData() external returns (uint80, int256, uint256, uint256, uint80) {
        if (writeMode) writes += 1;
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/**
 * @dev Feed that behaves normally until `garbage` is set, after which `latestRoundData` returns a single word
 *      so the caller's ABI decoding of the five return values fails.
 */
contract MockGarbageFeed {
    int256 public answer;
    uint256 public updatedAt;
    bool public garbage;

    function setAnswer(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function setGarbage(bool garbage_) external {
        garbage = garbage_;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (garbage) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(0, 32)
            }
        }
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/**
 * @dev Token whose `decimals` writes storage; it must be unable to do so when read through a view interface.
 */
contract MockStateWritingToken {
    uint256 public writes;

    function decimals() external returns (uint8) {
        writes += 1;
        return 6;
    }
}

/**
 * @dev Chainlink-style feed whose `decimals` can change after deployment (a feed upgrade or a mis-set mock).
 */
contract MockMutableDecimalsFeed {
    uint8 public feedDecimals;
    int256 public answer;
    uint256 public updatedAt;

    constructor(uint8 decimals_) {
        feedDecimals = decimals_;
    }

    function setDecimals(uint8 decimals_) external {
        feedDecimals = decimals_;
    }

    function setAnswer(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function decimals() external view returns (uint8) {
        return feedDecimals;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}
