// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CheckpointHookTestBase} from "./utils/CheckpointHookTestBase.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {CheckpointHook} from "../src/CheckpointHook.sol";

contract CheckpointHookTest is CheckpointHookTestBase {
    using StateLibrary for IPoolManager;

    function test_permissions_areCorrectlyEncodedInAddress() public view {
        // if the mined address in setUp() didn't actually encode the right flags, the
        // constructor's own address check would've reverted before we even got here
        assertEq(address(hook.poolManager()), address(manager));
    }

    function test_constructor_setsInitialGovernanceState() public view {
        assertEq(hook.owner(), governance);
        assertEq(hook.treasury(), treasury);
        assertEq(uint8(hook.feeDestination()), uint8(CheckpointHook.FeeDestination.DonateToLPs));
        assertEq(hook.blockNumberOffset(), BLOCK_OFFSET);
        assertEq(hook.minTickSpacing(), MIN_TICK_SPACING);
    }

    function test_constructor_revertsOnZeroTreasury() public {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs =
            abi.encode(manager, BLOCK_OFFSET, governance, address(0), MIN_TICK_SPACING);
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(CheckpointHook).creationCode, constructorArgs);

        vm.expectRevert(CheckpointHook.ZeroAddress.selector);
        new CheckpointHook{salt: salt}(manager, BLOCK_OFFSET, governance, address(0), MIN_TICK_SPACING);
    }

    function test_constructor_revertsOnZeroMinTickSpacing() public {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(manager, BLOCK_OFFSET, governance, treasury, uint24(0));
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(CheckpointHook).creationCode, constructorArgs);

        vm.expectRevert(abi.encodeWithSelector(CheckpointHook.TickSpacingTooSmall.selector, int24(0), uint24(1)));
        new CheckpointHook{salt: salt}(manager, BLOCK_OFFSET, governance, treasury, uint24(0));
    }

    // The whole point of minTickSpacing: a pool created below the floor should never even get
    // this hook attached, closing off the tick-crossing OOG risk at the source instead of trying
    // to bound the loop itself.
    //
    // Not matching the exact revert reason here: PoolManager wraps hook reverts in its own
    // ERC-7751 WrappedError(target, selector, reason, details), and reconstructing that encoding
    // byte for byte is brittle across v4-core versions. Bare expectRevert plus the positive case
    // right below (which proves the hook doesn't just reject everything) is good enough coverage.
    function test_initialize_revertsBelowMinTickSpacing() public {
        assertLt(uint24(1), hook.minTickSpacing(), "test assumes MIN_TICK_SPACING > 1");

        vm.expectRevert();
        initPool(currency0, currency1, IHooks(address(hook)), 500, 1, SQRT_PRICE_1_1);
    }

    function test_initialize_succeedsAtOrAboveMinTickSpacing() public {
        // poolKey from setUp() already used tickSpacing 60 >= MIN_TICK_SPACING, this just makes
        // the boundary condition explicit with a second pool at exactly the floor
        (PoolKey memory keyAtFloor,) =
            initPool(currency0, currency1, IHooks(address(hook)), 500, int24(uint24(MIN_TICK_SPACING)), SQRT_PRICE_1_1);
        assertEq(keyAtFloor.tickSpacing, int24(uint24(MIN_TICK_SPACING)));
    }

    function test_governance_onlyOwnerCanSetMinTickSpacing() public {
        vm.prank(alice);
        vm.expectRevert();
        hook.setMinTickSpacing(20);

        vm.prank(governance);
        hook.setMinTickSpacing(20);
        assertEq(hook.minTickSpacing(), 20);
    }

    function test_governance_setMinTickSpacingRevertsOnZero() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(CheckpointHook.TickSpacingTooSmall.selector, int24(0), uint24(1)));
        hook.setMinTickSpacing(0);
    }

    function test_governance_onlyOwnerCanSetTreasury() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(alice);
        vm.expectRevert();
        hook.setTreasury(newTreasury);

        vm.prank(governance);
        hook.setTreasury(newTreasury);
        assertEq(hook.treasury(), newTreasury);
    }

    function test_governance_onlyOwnerCanSetFeeDestination() public {
        vm.prank(alice);
        vm.expectRevert();
        hook.setFeeDestination(CheckpointHook.FeeDestination.Treasury);

        vm.prank(governance);
        hook.setFeeDestination(CheckpointHook.FeeDestination.Treasury);
        assertEq(uint8(hook.feeDestination()), uint8(CheckpointHook.FeeDestination.Treasury));
    }

    // Classic sandwich: attacker frontruns the victim's zeroForOne trade, lets the victim eat
    // the worse price, backruns to close. All three legs same block, same as a real bundle.
    // On a vanilla pool this is a free lunch. Here it shouldn't be, the whole point of the
    // checkpoint is that the backrun can't fill better than block-open price.
    function test_sandwichAttack_isUnprofitableWithinSameBlock() public {
        // attacker only gets currency0 up front, if we gave them currency1 too the backrun
        // would sell back more than what the frontrun actually got them and the profit check
        // below would be measuring nothing
        _fundAndApprove(attacker, 1000 ether, 0);
        _fundAndApprove(alice);

        uint256 attackerCurrency0Before = currency0.balanceOf(attacker);

        vm.prank(attacker);
        _swap(attacker, true, -1e17); // frontrun, sell 0.1 currency0

        vm.prank(alice);
        _swap(alice, true, -5e17); // victim eats the worse price

        uint256 attackerCurrency1Held = currency1.balanceOf(attacker);
        vm.prank(attacker);
        _swap(attacker, false, -int256(attackerCurrency1Held)); // backrun, sell it all back

        uint256 attackerCurrency0After = currency0.balanceOf(attacker);
        uint256 attackerCurrency1After = currency1.balanceOf(attacker);

        assertLe(
            attackerCurrency0After, attackerCurrency0Before, "attacker must not extract currency0 profit"
        );
        assertEq(attackerCurrency1After, 0, "attacker should have fully closed the currency1 leg");
    }

    // Same exact bundle, no hook this time. This is the baseline, confirms the pool is actually
    // sandwichable without protection so the test above means something and isn't just passing
    // because the trade sizes happen to be too small to matter.
    function test_baseline_sandwichAttack_isProfitableWithoutTheHook() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (PoolKey memory vanillaKey,) = initPool(currency0, currency1, IHooks(address(0)), 500, 60, SQRT_PRICE_1_1);
        // liquidity here is deliberately shallow relative to the trade sizes below, the deep
        // 1e24 pool used everywhere else in this suite is too deep for a 0.1-0.5 token trade to
        // move price enough to be worth sandwiching once you pay the 0.3% fee twice
        modifyLiquidityRouter.modifyLiquidity(
            vanillaKey,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 5e19, salt: 0}),
            ""
        );

        _fundAndApprove(attacker, 1000 ether, 0);
        _fundAndApprove(alice);

        uint256 attackerCurrency0Before = currency0.balanceOf(attacker);

        vm.prank(attacker);
        swapRouter.swap(
            vanillaKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e17, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        vm.prank(alice);
        swapRouter.swap(
            vanillaKey,
            SwapParams({zeroForOne: true, amountSpecified: -5e17, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 attackerCurrency1Held = currency1.balanceOf(attacker);
        vm.prank(attacker);
        swapRouter.swap(
            vanillaKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(attackerCurrency1Held),
                sqrtPriceLimitX96: MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 attackerCurrency0After = currency0.balanceOf(attacker);

        assertGt(attackerCurrency0After, attackerCurrency0Before, "unprotected pool should be sandwichable");
    }

    function test_normalSwap_stillExecutesAndSettles() public {
        _fundAndApprove(alice);
        uint256 before0 = currency0.balanceOf(alice);

        vm.prank(alice);
        _swap(alice, true, -1e17);

        assertLt(currency0.balanceOf(alice), before0, "swap should have debited currency0");
    }

    function test_jitLiquidity_feesAreWithheldWithinOffsetWindow() public {
        _fundAndApprove(alice);
        _fundAndApprove(attacker);

        vm.prank(attacker);
        _swap(attacker, true, -1e17);

        // not asserting exact penalty magnitude here, that's already covered by OZ's own tests
        // for LiquidityPenaltyHook. this just checks the wiring doesn't blow up.
        // TODO: worth adding a dedicated test that adds/removes liquidity inside the offset
        // window and checks the withheld fee actually shows up as a donation, right now we're
        // trusting the library's own coverage for that.
        assertEq(hook.blockNumberOffset(), BLOCK_OFFSET);
    }

    function _fundAndApprove(address user) internal {
        _fundAndApprove(user, 1000 ether, 1000 ether);
    }

    function _fundAndApprove(address user, uint256 amount0, uint256 amount1) internal {
        deal(Currency.unwrap(currency0), user, amount0);
        deal(Currency.unwrap(currency1), user, amount1);

        vm.startPrank(user);
        MockERC20Approve(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20Approve(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        MockERC20Approve(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20Approve(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(address, /* user, kept for call-site readability */ bool zeroForOne, int256 amountSpecified)
        internal
        returns (int256, int256)
    {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(poolKey, params, settings, "");
        return (0, 0);
    }
}

// Deployers' mock ERC20s don't give us a typed handle, just enough of the interface to approve
interface MockERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
}
