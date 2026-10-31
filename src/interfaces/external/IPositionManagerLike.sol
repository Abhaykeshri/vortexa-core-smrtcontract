// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title Position Manager Minimal Interface
 * @notice Minimal Uniswap V4 PositionManager surface used by the M4 vault.
 * @dev This project-local interface avoids importing Uniswap production source into `src/`.
 */
interface IPositionManagerLike {
    /**
     * @notice Batches V4 liquidity actions through the PositionManager.
     * @dev `unlockData` is `abi.encode(bytes actions, bytes[] params)` and `deadline` protects stale execution.
     * @param unlockData Encoded action bytes and matching parameter array.
     * @param deadline Last timestamp at which the action batch may execute.
     */
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;

    /**
     * @notice Returns the token id that the next mint action will assign.
     * @dev Used before first deposit to predict and verify one NFT id per band.
     * @return tokenId Next PositionManager NFT id.
     */
    function nextTokenId() external view returns (uint256 tokenId);

    /**
     * @notice Returns the owner of a PositionManager NFT.
     * @dev The vault verifies ownership after minting to detect malformed or hostile PositionManager behavior.
     * @param tokenId PositionManager NFT id.
     * @return owner Current NFT owner.
     */
    function ownerOf(uint256 tokenId) external view returns (address owner);
}
