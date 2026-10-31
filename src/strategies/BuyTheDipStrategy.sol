// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IShapeLibrary} from "../interfaces/IShapeLibrary.sol";
import {Strategy} from "../libraries/Types.sol";
import {SingleSidedStrategy} from "./StrategyBase.sol";

/**
 * @title Buy The Dip Strategy
 * @notice Stateless one-sided strategy that trails the configured base asset downward.
 * @dev Base orientation determines whether its range sits below or above the current pool price.
 */
contract BuyTheDipStrategy is SingleSidedStrategy {
    /**
     * @notice Initializes the immutable ShapeLibrary dependency.
     * @dev Reverts through StrategyBase when the dependency is zero.
     * @param shapes_ Deployed ShapeLibrary.
     */
    constructor(IShapeLibrary shapes_) SingleSidedStrategy(shapes_) {}

    /**
     * @inheritdoc SingleSidedStrategy
     */
    function _strategyKind() internal pure override returns (Strategy) {
        return Strategy.BuyTheDip;
    }
}
