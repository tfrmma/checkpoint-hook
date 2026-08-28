// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {BaseHook} from "uniswap-hooks/src/base/BaseHook.sol";
import {AntiSandwichHook} from "uniswap-hooks/src/general/AntiSandwichHook.sol";
import {LiquidityPenaltyHook} from "uniswap-hooks/src/general/LiquidityPenaltyHook.sol";
import {BaseDynamicAfterFee} from "uniswap-hooks/src/fee/BaseDynamicAfterFee.sol";
import {CurrencySettler} from "uniswap-hooks/src/utils/CurrencySettler.sol";

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CheckpointHook
/// @notice Uniswap v4 hook stacking sr-AMM sandwich resistance on top of JIT-liquidity penalties.
/// @dev Two mechanisms, both borrowed from OZ's uniswap-hooks lib rather than reinvented:
///
/// 1. AntiSandwichHook (sr-AMM, see Xiao/Robinson/Umbra Research 2024). Checkpoints the pool price
///    at the start of every block and won't let a swap fill better than that checkpoint within the
///    same block. Kills the backrun leg of a sandwich because there's nothing left to recover.
///    https://www.umbraresearch.xyz/writings/sandwich-resistant-amm
///
/// 2. LiquidityPenaltyHook. The sr-AMM paper itself flags that you can route around checkpoint
///    protection by JIT'ing liquidity in and out around the victim's trade. This withholds LP fees
///    for positions touched within blockNumberOffset blocks of each other and donates the withheld
///    amount to LPs who actually sat in range.
///
/// What we bolt on top: the anti-sandwich mechanism captures the spread as an ERC-6909 claim on
/// this contract. We route it either back to in-range LPs via donate() (default) or to a treasury
/// address, redeemable later. See FeeDestination below.
///
/// Residual risk, read before you deploy this with real size behind it:
/// - block-boundary sandwiching still works if one builder controls two consecutive blocks
/// - AntiSandwichHook only protects the !zeroForOne direction upstream, that's a known limitation
///   of the library, not something we patched here
/// - beforeSwap walks every initialized tick crossed since last checkpoint, once per block. We
///   bound the worst case by refusing to attach to pools below minTickSpacing (enforced at
///   initialization), but a large enough price move can still make that loop expensive even at a
///   sane spacing, this reduces the risk, it doesn't eliminate it
/// - this has NOT been audited independently. AntiSandwichHook/LiquidityPenaltyHook went through a
///   scoped OZ audit round upstream, this composition on top of them has not.
contract CheckpointHook is AntiSandwichHook, LiquidityPenaltyHook, Ownable2Step, ReentrancyGuard, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    enum FeeDestination {
        DonateToLPs,
        Treasury
    }

    struct RedeemAction {
        Currency currency;
        uint256 amount;
        address to;
    }

    error ZeroAddress();
    error ZeroAmount();
    error UnauthorizedCallback();
    error TickSpacingTooSmall(int24 tickSpacing, uint24 minTickSpacing);

    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeeDestinationUpdated(FeeDestination oldDestination, FeeDestination newDestination);
    event MinTickSpacingUpdated(uint24 oldMinTickSpacing, uint24 newMinTickSpacing);
    event CapturedFeeDonated(PoolId indexed poolId, Currency indexed currency, uint256 amount);
    event CapturedFeeSentToTreasury(PoolId indexed poolId, Currency indexed currency, uint256 amount);
    event TreasuryClaimsRedeemed(Currency indexed currency, uint256 amount, address indexed to);

    address public treasury;
    FeeDestination public feeDestination;

    // floor on key.tickSpacing, enforced at pool init, bounds the tick-crossing loop's worst case
    uint24 public minTickSpacing;

    constructor(
        IPoolManager _poolManager,
        uint48 _blockNumberOffset,
        address _initialOwner,
        address _treasury,
        uint24 _minTickSpacing
    ) BaseHook(_poolManager) LiquidityPenaltyHook(_blockNumberOffset) Ownable(_initialOwner) {
        if (_treasury == address(0)) revert ZeroAddress();
        if (_initialOwner == address(0)) revert ZeroAddress();
        if (_minTickSpacing == 0) revert TickSpacingTooSmall(0, 1);
        treasury = _treasury;
        feeDestination = FeeDestination.DonateToLPs;
        minTickSpacing = _minTickSpacing;
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    function setFeeDestination(FeeDestination newDestination) external onlyOwner {
        emit FeeDestinationUpdated(feeDestination, newDestination);
        feeDestination = newDestination;
    }

    function setMinTickSpacing(uint24 newMinTickSpacing) external onlyOwner {
        if (newMinTickSpacing == 0) revert TickSpacingTooSmall(0, 1);
        emit MinTickSpacingUpdated(minTickSpacing, newMinTickSpacing);
        minTickSpacing = newMinTickSpacing;
    }

    function _afterSwapHandler(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta, /* delta */
        uint256, /* targetUnspecifiedAmount */
        uint256 feeAmount
    ) internal override {
        if (feeAmount == 0) return;

        PoolId poolId = key.toId();
        Currency unspecified = (params.amountSpecified < 0 == params.zeroForOne) ? key.currency1 : key.currency0;

        // TODO: silently falls back to treasury when donate() can't be used, worth its own event
        bool canDonate = feeDestination == FeeDestination.DonateToLPs && poolManager.getLiquidity(poolId) > 0;

        if (canDonate) {
            uint256 amount0 = unspecified == key.currency0 ? feeAmount : 0;
            uint256 amount1 = unspecified == key.currency1 ? feeAmount : 0;

            poolManager.donate(key, amount0, amount1, "");
            unspecified.settle(poolManager, address(this), feeAmount, true);

            emit CapturedFeeDonated(poolId, unspecified, feeAmount);
        } else {
            poolManager.transfer(treasury, unspecified.toId(), feeAmount);

            emit CapturedFeeSentToTreasury(poolId, unspecified, feeAmount);
        }
    }

    function redeemTreasuryClaims(Currency currency, uint256 amount, address to) external nonReentrant {
        if (msg.sender != treasury) revert Ownable.OwnableUnauthorizedAccount(msg.sender);
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        poolManager.unlock(abi.encode(RedeemAction({currency: currency, amount: amount, to: to})));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert UnauthorizedCallback();

        RedeemAction memory action = abi.decode(data, (RedeemAction));

        action.currency.settle(poolManager, address(this), action.amount, true);
        action.currency.take(poolManager, action.to, action.amount, false);

        emit TreasuryClaimsRedeemed(action.currency, action.amount, action.to);
        return "";
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        if (key.tickSpacing < int24(minTickSpacing)) {
            revert TickSpacingTooSmall(key.tickSpacing, minTickSpacing);
        }
        return this.beforeInitialize.selector;
    }

    // --- diamond inheritance cleanup ---
    // AntiSandwichHook and LiquidityPenaltyHook both trace back to BaseHook and each override a
    // disjoint set of its callbacks, so solc wants every touched function re-declared here.
    // These are plain passthroughs, super resolves to whichever parent actually implements the
    // logic. Nothing below overlaps in behavior, they just share an ancestor.

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feeDelta,
        bytes calldata hookData
    ) internal override(BaseHook, LiquidityPenaltyHook) returns (bytes4, BalanceDelta) {
        return super._afterAddLiquidity(sender, key, params, delta, feeDelta, hookData);
    }

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feeDelta,
        bytes calldata hookData
    ) internal override(BaseHook, LiquidityPenaltyHook) returns (bytes4, BalanceDelta) {
        return super._afterRemoveLiquidity(sender, key, params, delta, feeDelta, hookData);
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override(BaseHook, AntiSandwichHook)
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return super._beforeSwap(sender, key, params, hookData);
    }

    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
        internal
        override(BaseHook, BaseDynamicAfterFee)
        returns (bytes4, int128)
    {
        return super._afterSwap(sender, key, params, delta, hookData);
    }

    function _getBlockNumber() internal view override(AntiSandwichHook, LiquidityPenaltyHook) returns (uint48) {
        return uint48(block.number);
    }

    function getHookPermissions()
        public
        pure
        override(AntiSandwichHook, LiquidityPenaltyHook)
        returns (Hooks.Permissions memory)
    {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: true,
            afterRemoveLiquidityReturnDelta: true
        });
    }
}
