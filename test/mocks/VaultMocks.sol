// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPriceGuard} from "../../src/interfaces/IPriceGuard.sol";
import {IShapeLibrary} from "../../src/interfaces/IShapeLibrary.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {ShapeLibrary} from "../../src/ShapeLibrary.sol";
import {ISwapExecutor} from "../../src/interfaces/ISwapExecutor.sol";
import {IVaultFactory} from "../../src/interfaces/IVaultFactory.sol";
import {IStateViewLike} from "../../src/interfaces/external/IStateViewLike.sol";
import {CurrencyLib} from "../../src/libraries/CurrencyLib.sol";
import {Currency, DepositMode, Band, Plan, PoolKey, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {PoolIdLib} from "../../src/libraries/PoolIdLib.sol";
import {PosmActions} from "../../src/libraries/PosmActions.sol";
import {SqrtPriceMath} from "../../src/libraries/SqrtPriceMath.sol";
import {VaultM6Module} from "../../src/VaultM6Module.sol";

contract MockVaultStateView is IStateViewLike {
    uint160 public sqrtPriceX96 = uint160(1 << 96);
    int24 public tick;
    mapping(bytes32 => mapping(bytes32 => uint128)) public liquidities;
    mapping(bytes32 => mapping(bytes32 => uint256)) public last0;
    mapping(bytes32 => mapping(bytes32 => uint256)) public last1;
    uint256 public feeGrowth0;
    uint256 public feeGrowth1;

    function setSlot0(uint160 sqrtPriceX96_, int24 tick_) external {
        sqrtPriceX96 = sqrtPriceX96_;
        tick = tick_;
    }

    function setFees(uint256 feeGrowth0_, uint256 feeGrowth1_) external {
        feeGrowth0 = feeGrowth0_;
        feeGrowth1 = feeGrowth1_;
    }

    function setLiquidity(bytes32 poolId, uint256 tokenId, uint128 liquidity) external {
        liquidities[poolId][bytes32(tokenId)] = liquidity;
    }

    function setSnapshot(bytes32 poolId, uint256 tokenId) external {
        last0[poolId][bytes32(tokenId)] = feeGrowth0;
        last1[poolId][bytes32(tokenId)] = feeGrowth1;
    }

    function getSlot0(bytes32) external view returns (uint160, int24, uint24, uint24) {
        return (sqrtPriceX96, tick, 0, 0);
    }

    function getPositionInfo(bytes32 poolId, address, int24, int24, bytes32 salt)
        external
        view
        returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128)
    {
        return (liquidities[poolId][salt], last0[poolId][salt], last1[poolId][salt]);
    }

    function getFeeGrowthInside(bytes32, int24, int24) external view returns (uint256, uint256) {
        return (feeGrowth0, feeGrowth1);
    }
}

contract MockVaultPriceGuard is IPriceGuard {
    using PoolIdLib for PoolKey;

    bool public trusted = true;
    bool public shouldRevert;
    uint160 public referencePrice = uint160(1 << 96);
    mapping(bytes32 poolId => PairConfig config) private _pairConfigs;

    function setTrusted(bool trusted_) external {
        trusted = trusted_;
    }

    function setRevert(bool shouldRevert_) external {
        shouldRevert = shouldRevert_;
    }

    function setReference(uint160 reference_) external {
        referencePrice = reference_;
    }

    function setPairConfig(PoolKey calldata key, PairConfig calldata config) external {
        _pairConfigs[key.toId()] = config;
    }

    function configOf(PoolKey calldata key) external view returns (PairConfig memory, uint8, uint8) {
        return (_pairConfigs[key.toId()], 18, 18);
    }

    function isPriceTrusted(PoolKey calldata) external view returns (bool, uint256) {
        if (shouldRevert) revert();
        return (trusted, trusted ? 0 : type(uint256).max);
    }

    function referenceSqrtPriceX96(PoolKey calldata) external view returns (uint160) {
        if (shouldRevert || !trusted) revert();
        return referencePrice;
    }
}

contract MockStrategy is IStrategy {
    bool public allowed = true;
    bool public rebalanceNeeded;
    bytes32 public rebalanceReason = bytes32("MOCK");
    DepositMode public mode = DepositMode.BothTokens;
    Plan private _plan;
    bool private _planSet;
    ShapeLibrary private immutable _fallbackShapes = new ShapeLibrary();

    function setAllowed(bool allowed_) external {
        allowed = allowed_;
    }

    function setMode(DepositMode mode_) external {
        mode = mode_;
    }

    function setRebalance(bool needed, bytes32 reason) external {
        rebalanceNeeded = needed;
        rebalanceReason = reason;
    }

    function setPlan(
        Band[] calldata bands_,
        uint16[] calldata weights_,
        bool needsSwap_,
        bool zeroForOne_,
        uint256 swapAmountIn_,
        bool lockIdle_
    ) external {
        _planSet = true;
        delete _plan.bands;
        delete _plan.weightsBps;
        for (uint256 i; i < bands_.length; ++i) {
            _plan.bands.push(bands_[i]);
        }
        for (uint256 i; i < weights_.length; ++i) {
            _plan.weightsBps.push(weights_[i]);
        }
        _plan.needsSwap = needsSwap_;
        _plan.zeroForOne = zeroForOne_;
        _plan.swapAmountIn = swapAmountIn_;
        _plan.lockIdle = lockIdle_;
    }

    function clearPlan() external {
        delete _plan;
        _planSet = false;
    }

    function canDeposit(VaultConfig calldata, int24, Band[] calldata) external view returns (bool) {
        return allowed;
    }

    function validateConfig(VaultConfig calldata, int24) external pure {}

    function depositMode(VaultConfig calldata) external view returns (DepositMode) {
        return mode;
    }

    function checkTrigger(VaultConfig calldata, int24, Band[] calldata) external view returns (bool, bytes32) {
        return (rebalanceNeeded, rebalanceReason);
    }

    function plan(VaultConfig calldata config, int24, int24 newCenterTick, uint160, uint256, uint256, bytes32)
        external
        view
        returns (Plan memory p)
    {
        p = _plan;
        if (!_planSet) {
            (p.bands, p.weightsBps) = _fallbackShapes.computeBands(
                config.shapeId, newCenterTick, config.ticksLeft, config.ticksRight, config.poolKey.tickSpacing
            );
        }
    }
}

contract MockShapeLibrary is IShapeLibrary {
    function computeBands(uint8, int24, int24, int24, int24)
        external
        pure
        returns (Band[] memory bands, uint16[] memory weights)
    {
        bands = new Band[](1);
        bands[0] = Band({tickLower: -120, tickUpper: -60, tokenId: 0, liquidity: 0});
        weights = new uint16[](1);
        weights[0] = 10_000;
    }

    function maxBands() external pure returns (uint8) {
        return 5;
    }

    function isValidShape(uint8 shapeId) external pure returns (bool) {
        return shapeId < 8;
    }
}

contract MockPermit2 {
    mapping(address => mapping(address => mapping(address => uint160))) public allowance;

    function approve(address token, address spender, uint160 amount, uint48) external {
        allowance[msg.sender][token][spender] = amount;
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        uint160 current = allowance[from][token][msg.sender];
        if (current != type(uint160).max) allowance[from][token][msg.sender] = current - amount;
        IERC20(token).transferFrom(from, to, amount);
    }
}

interface IERC721ReceiverLike {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

contract MockPositionManager {
    using CurrencyLib for Currency;
    using PoolIdLib for PoolKey;

    MockPermit2 public immutable permit2;
    MockVaultStateView public immutable stateView;
    uint256 public nextTokenId = 1;
    bool public safeMint;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => PoolKey) public poolKeys;
    mapping(uint256 => uint128) public liquidityOf;
    mapping(uint256 => uint256) public principal0Of;
    mapping(uint256 => uint256) public principal1Of;
    mapping(address => mapping(address => uint256)) public credits;

    constructor(MockPermit2 permit2_, MockVaultStateView stateView_) {
        permit2 = permit2_;
        stateView = stateView_;
    }

    function setSafeMint(bool safeMint_) external {
        safeMint = safeMint_;
    }

    function modifyLiquidities(bytes calldata unlockData, uint256) external payable {
        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        for (uint256 i; i < actions.length; ++i) {
            uint8 action = uint8(actions[i]);
            if (action == PosmActions.MINT_POSITION) _mint(params[i], msg.sender);
            else if (action == PosmActions.INCREASE_LIQUIDITY) _increase(params[i], msg.sender);
            else if (action == PosmActions.DECREASE_LIQUIDITY) _decrease(params[i]);
            else if (action == PosmActions.BURN_POSITION) _burn(params[i]);
            else if (action == PosmActions.TAKE_PAIR) _takePair(params[i]);
            else if (action == PosmActions.SWEEP) _sweep(params[i]);
        }
    }

    function _mint(bytes memory params, address payer) internal {
        (
            PoolKey memory key,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidity,
            uint128 amount0Max,
            uint128 amount1Max,
            address owner,
        ) = abi.decode(params, (PoolKey, int24, int24, uint256, uint128, uint128, address, bytes));
        uint256 tokenId = nextTokenId++;
        ownerOf[tokenId] = owner;
        poolKeys[tokenId] = key;
        liquidityOf[tokenId] = uint128(liquidity);
        _pull(key, payer, amount0Max, amount1Max);
        principal0Of[tokenId] = amount0Max;
        principal1Of[tokenId] = amount1Max;
        stateView.setLiquidity(key.toId(), tokenId, uint128(liquidity));
        stateView.setSnapshot(key.toId(), tokenId);
        if (safeMint) {
            bytes4 ret = IERC721ReceiverLike(owner).onERC721Received(address(this), address(0), tokenId, "");
            require(ret == IERC721ReceiverLike.onERC721Received.selector, "receiver rejected");
        }
        tickLower;
        tickUpper;
    }

    function _increase(bytes memory params, address payer) internal {
        (uint256 tokenId, uint256 liquidity, uint128 amount0Max, uint128 amount1Max,) =
            abi.decode(params, (uint256, uint256, uint128, uint128, bytes));
        PoolKey memory key = poolKeys[tokenId];
        liquidityOf[tokenId] += uint128(liquidity);
        _pull(key, payer, amount0Max, amount1Max);
        principal0Of[tokenId] += amount0Max;
        principal1Of[tokenId] += amount1Max;
        stateView.setLiquidity(key.toId(), tokenId, liquidityOf[tokenId]);
        stateView.setSnapshot(key.toId(), tokenId);
    }

    function _decrease(bytes memory params) internal {
        (uint256 tokenId, uint256 liquidity,,,) = abi.decode(params, (uint256, uint256, uint128, uint128, bytes));
        PoolKey memory key = poolKeys[tokenId];
        uint128 current = liquidityOf[tokenId];
        uint256 remove = liquidity > current ? current : liquidity;
        (uint256 out0, uint256 out1) = _principalOut(tokenId, current, remove);
        (uint256 fee0, uint256 fee1) = _feesOut(key, tokenId);
        credits[msg.sender][Currency.unwrap(key.currency0)] += out0 + fee0;
        credits[msg.sender][Currency.unwrap(key.currency1)] += out1 + fee1;
        stateView.setLiquidity(key.toId(), tokenId, liquidityOf[tokenId]);
        stateView.setSnapshot(key.toId(), tokenId);
    }

    function _burn(bytes memory params) internal {
        (uint256 tokenId,,,) = abi.decode(params, (uint256, uint128, uint128, bytes));
        PoolKey memory key = poolKeys[tokenId];
        uint128 current = liquidityOf[tokenId];
        (uint256 out0, uint256 out1) = _principalOut(tokenId, current, current);
        (uint256 fee0, uint256 fee1) = _feesOut(key, tokenId);
        credits[msg.sender][Currency.unwrap(key.currency0)] += out0 + fee0;
        credits[msg.sender][Currency.unwrap(key.currency1)] += out1 + fee1;
        stateView.setLiquidity(key.toId(), tokenId, 0);
        delete ownerOf[tokenId];
        delete poolKeys[tokenId];
    }

    function _principalOut(uint256 tokenId, uint128 current, uint256 remove)
        internal
        returns (uint256 out0, uint256 out1)
    {
        if (current != 0 && remove != 0) {
            out0 = principal0Of[tokenId] * remove / current;
            out1 = principal1Of[tokenId] * remove / current;
            principal0Of[tokenId] -= out0;
            principal1Of[tokenId] -= out1;
            liquidityOf[tokenId] = current - uint128(remove);
        }
    }

    function _feesOut(PoolKey memory key, uint256 tokenId) internal view returns (uint256 fee0, uint256 fee1) {
        (uint128 stateLiquidity, uint256 last0, uint256 last1) =
            stateView.getPositionInfo(key.toId(), address(this), 0, 0, bytes32(tokenId));
        (uint256 now0, uint256 now1) = stateView.getFeeGrowthInside(key.toId(), 0, 0);
        fee0 = uint256(stateLiquidity) * (now0 - last0) / (1 << 128);
        fee1 = uint256(stateLiquidity) * (now1 - last1) / (1 << 128);
    }

    function _takePair(bytes memory params) internal {
        (Currency currency0, Currency currency1, address to) = abi.decode(params, (Currency, Currency, address));
        _payCredit(currency0, msg.sender, to);
        _payCredit(currency1, msg.sender, to);
    }

    function _payCredit(Currency currency, address owner, address to) internal {
        address token = Currency.unwrap(currency);
        uint256 amount = credits[owner][token];
        credits[owner][token] = 0;
        currency.transfer(to, amount);
    }

    function _pull(PoolKey memory key, address payer, uint128 amount0, uint128 amount1) internal {
        if (Currency.unwrap(key.currency0) != address(0) && amount0 > 0) {
            permit2.transferFrom(payer, address(this), amount0, Currency.unwrap(key.currency0));
        }
        if (Currency.unwrap(key.currency1) != address(0) && amount1 > 0) {
            permit2.transferFrom(payer, address(this), amount1, Currency.unwrap(key.currency1));
        }
    }

    function _sweep(bytes memory params) internal {
        (, address to) = abi.decode(params, (Currency, address));
        uint256 balance = address(this).balance;
        if (balance > 0) payable(to).transfer(balance);
    }

    receive() external payable {}
}

contract MockSwapExecutor is ISwapExecutor {
    using CurrencyLib for Currency;

    address public immutable vaultModule = address(new VaultM6Module());
    bool public executeTransfers;
    uint256 public configuredOutput;
    uint256 public lastMinOut;
    uint256 public pullShortfall;

    function setExecuteTransfers(bool enabled) external {
        executeTransfers = enabled;
    }

    /**
     * Pulls `amountIn - shortfall` of an ERC-20 input, leaving part of the caller's allowance unused.
     */
    function setPullShortfall(uint256 shortfall) external {
        pullShortfall = shortfall;
    }

    function setConfiguredOutput(uint256 amount) external {
        configuredOutput = amount;
    }

    function swap(Currency, Currency, uint256 amountIn, uint256) external payable returns (uint256) {
        return amountIn;
    }

    function swapExactInput(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minAmountOut)
        external
        payable
        returns (uint256)
    {
        lastMinOut = minAmountOut;
        uint256 amountOut = configuredOutput == 0 ? amountIn : configuredOutput;
        if (executeTransfers) {
            Currency input = zeroForOne ? key.currency0 : key.currency1;
            if (!input.isNative()) {
                IERC20Pull(Currency.unwrap(input)).transferFrom(msg.sender, address(this), amountIn - pullShortfall);
            }
            Currency output = zeroForOne ? key.currency1 : key.currency0;
            output.transfer(msg.sender, amountOut);
        }
        return amountOut;
    }
}

interface IERC20Pull {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract MockFeeCollector {
    using CurrencyLib for Currency;

    address public owner;
    address public recipient;

    error NotOwner();
    error ZeroAddress();

    constructor(address recipient_) {
        owner = msg.sender;
        if (recipient_ == address(0)) revert ZeroAddress();
        recipient = recipient_;
    }

    function setRecipient(address recipient_) external {
        if (msg.sender != owner) revert NotOwner();
        if (recipient_ == address(0)) revert ZeroAddress();
        recipient = recipient_;
    }

    function collect(Currency token) external returns (uint256 amount) {
        amount = token.balanceOfSelf();
        token.transfer(recipient, amount);
    }

    receive() external payable {}
}

contract MockFactory is IVaultFactory {
    mapping(address => bool) public isKnown;
    mapping(address => bool) public keeper;
    address public override owner;
    address public override guardian;
    address public override feeCollector;
    uint256 public override protocolFeeBps;
    uint256 public override maxProtocolFeeBps;
    address public override implementation;
    mapping(Strategy => IStrategy) public override strategyOf;
    mapping(bytes32 => PoolRule) public override poolRule;
    address[] private _vaults;

    error NotOwner();
    error InvalidProtocolFee();

    constructor(uint256 initialProtocolFeeBps, uint256 initialMaxProtocolFeeBps, address feeCollector_) {
        owner = msg.sender;
        if (
            initialProtocolFeeBps > initialMaxProtocolFeeBps || initialMaxProtocolFeeBps > 10_000
                || feeCollector_ == address(0)
        ) revert InvalidProtocolFee();
        protocolFeeBps = initialProtocolFeeBps;
        maxProtocolFeeBps = initialMaxProtocolFeeBps;
        feeCollector = feeCollector_;
        guardian = msg.sender;
    }

    function setProtocolFeeBps(uint256 newFeeBps) external {
        if (msg.sender != owner) revert NotOwner();
        if (newFeeBps > maxProtocolFeeBps) revert InvalidProtocolFee();
        uint256 old = protocolFeeBps;
        protocolFeeBps = newFeeBps;
        emit ProtocolFeeBpsSet(old, newFeeBps);
    }

    function setMaxProtocolFeeBps(uint256 newMaxFeeBps) external {
        if (msg.sender != owner) revert NotOwner();
        if (newMaxFeeBps > 10_000 || newMaxFeeBps < protocolFeeBps) revert InvalidProtocolFee();
        uint256 old = maxProtocolFeeBps;
        maxProtocolFeeBps = newMaxFeeBps;
        emit MaxProtocolFeeBpsSet(old, newMaxFeeBps);
    }

    function setVault(address vault, bool known) external {
        isKnown[vault] = known;
    }

    function setKeeper(address account, bool known) external {
        keeper[account] = known;
    }

    function isVault(address vault) external view returns (bool) {
        return isKnown[vault];
    }

    function isKeeper(address account) external view returns (bool) {
        return keeper[account];
    }

    function createVault(VaultConfig calldata, string calldata, string calldata) external pure returns (address) {
        revert NotOwner();
    }

    function predictVaultAddress(address, VaultConfig calldata, string calldata, string calldata)
        external
        pure
        returns (address)
    {
        return address(0);
    }

    function vaultCount() external view returns (uint256) {
        return _vaults.length;
    }

    function vaultAt(uint256 index) external view returns (address) {
        return _vaults[index];
    }
}
