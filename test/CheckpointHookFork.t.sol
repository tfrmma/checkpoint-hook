// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {CheckpointHook} from "../src/CheckpointHook.sol";

interface IERC20Minimal {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// Same sandwich-attack proof as CheckpointHook.t.sol's core test, run against Base mainnet's
// real, already-deployed PoolManager instead of a fresh in-memory one. Everything else in this
// repo's suite proves the mechanism is sound in isolation, this proves it survives contact with
// the actual deployed bytecode and real WETH/USDC contracts, not just our local copy of v4-core.
//
// Needs a fork, so it skips itself rather than failing the whole suite when no RPC is set:
//
//   export BASE_RPC_URL=<your RPC>
//   forge test --match-contract CheckpointHookForkTest --fork-url $BASE_RPC_URL -vv
//
// Optional: FORK_BLOCK to pin a specific block for reproducibility, otherwise forks at latest.
contract CheckpointHookForkTest is Test {
    // verified on BaseScan, the compiled bytecode's own immutable self-address check embeds this
    // exact value, see https://basescan.org/address/0x498581ff718922c3f8e6a244956af099b2652b2b
    address internal constant BASE_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    // OP-stack predeploy, same address on every OP-stack chain including Base
    address internal constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    // native USDC issued by Circle, not the legacy bridged USDbC
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    uint160 internal constant MIN_PRICE_LIMIT = 4295128740;
    uint160 internal constant MAX_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341;

    IPoolManager internal manager;
    PoolModifyLiquidityTest internal modifyLiquidityRouter;
    PoolSwapTest internal swapRouter;
    CheckpointHook internal hook;
    PoolKey internal poolKey;

    address internal governance = makeAddr("governance");
    address internal treasury = makeAddr("treasury");
    address internal attacker = makeAddr("attacker");
    address internal alice = makeAddr("alice");

    function setUp() public {
        string memory rpcUrl = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true, "BASE_RPC_URL not set, skipping fork test");
            return;
        }

        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.createSelectFork(rpcUrl, forkBlock);
        }

        manager = IPoolManager(BASE_POOL_MANAGER);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);

        // 0x4200... < 0x8335..., so WETH is currency0 and USDC is currency1, confirmed against
        // the real addresses above rather than assumed
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        uint48 blockOffset = 5;
        uint24 minTickSpacing = 60;
        bytes memory constructorArgs = abi.encode(manager, blockOffset, governance, treasury, minTickSpacing);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(CheckpointHook).creationCode, constructorArgs);
        hook = new CheckpointHook{salt: salt}(manager, blockOffset, governance, treasury, minTickSpacing);
        require(address(hook) == hookAddress, "hook address mismatch");

        // Fresh pool for this hook, doesn't touch any existing WETH/USDC liquidity on other fee
        // tiers. Starting price is a nominal 1:1 in raw units (tick 0), not real WETH/USDC market
        // price, that mismatch doesn't matter here: the checkpoint mechanism only cares about
        // relative price movement within a block, not what the absolute starting price represents.
        // Nominal 1:1 (tick 0) was wrong: v4's liquidity math is decimals-agnostic, all raw
        // integer units, and for an 18-decimal/6-decimal pair that "1:1" is actually an absurd
        // real-world price. Backing even a modest liquidityDelta at that price needed far more
        // USDC than any sane amount to deal. This tick approximates ~2500 USDC per WETH
        // (2500 * 1e6 / 1e18 raw price, converted via log base 1.0001, rounded to a tickSpacing-60
        // multiple), it's a rough approximation for testing purposes, not tracking live market
        // price, real WETH/USDC rate doesn't matter for what this test is proving.
        int24 initialTick = -198060;
        poolKey = PoolKey({
            currency0: Currency.wrap(BASE_WETH),
            currency1: Currency.wrap(BASE_USDC),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(initialTick));

        // +-6000 ticks around the realistic price above, liquidityDelta chosen to need roughly
        // 52 WETH and 130,000 USDC (verified with the exact v3/v4 liquidity math offline before
        // picking this number), comfortably inside what's dealt below and deep enough that the
        // 0.6 WETH combined frontrun+victim size below is a small fraction of it.
        IERC20Minimal(BASE_WETH).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20Minimal(BASE_USDC).approve(address(modifyLiquidityRouter), type(uint256).max);
        deal(BASE_WETH, address(this), 1_000_000 ether);
        deal(BASE_USDC, address(this), 1_000_000_000e6);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: initialTick - 6000,
                tickUpper: initialTick + 6000,
                liquidityDelta: 1e16,
                salt: 0
            }),
            ""
        );

        // Native ETH for gas, separate from the WETH/USDC token balances below. attacker/alice
        // are makeAddr()-derived, they start at zero ETH, and on a real fork (unlike a fresh
        // in-memory PoolManager where address(this) has Foundry's default huge balance) any call
        // they make needs to actually cover its own gas/fee.
        vm.deal(attacker, 1 ether);
        vm.deal(alice, 1 ether);

        deal(BASE_WETH, attacker, 1_000 ether);
        deal(BASE_WETH, alice, 1_000 ether);
        deal(BASE_USDC, alice, 1_000_000e6);

        vm.startPrank(attacker);
        IERC20Minimal(BASE_WETH).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(BASE_USDC).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(alice);
        IERC20Minimal(BASE_WETH).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(BASE_USDC).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // Same frontrun/victim/backrun sequence and trade sizes proven in
    // CheckpointHook.t.sol:test_sandwichAttack_isUnprofitableWithinSameBlock, against the real
    // PoolManager contract on Base instead of a fresh one.
    function test_sandwichAttack_isUnprofitableWithinSameBlock_onRealPoolManager() public {
        uint256 attackerWethBefore = IERC20Minimal(BASE_WETH).balanceOf(attacker);
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(attacker);
        swapRouter.swap(
            poolKey, SwapParams({zeroForOne: true, amountSpecified: -1e17, sqrtPriceLimitX96: MIN_PRICE_LIMIT}), settings, ""
        );

        vm.prank(alice);
        swapRouter.swap(
            poolKey, SwapParams({zeroForOne: true, amountSpecified: -5e17, sqrtPriceLimitX96: MIN_PRICE_LIMIT}), settings, ""
        );

        uint256 attackerUsdcHeld = IERC20Minimal(BASE_USDC).balanceOf(attacker);
        vm.prank(attacker);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(attackerUsdcHeld), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            settings,
            ""
        );

        assertLe(
            IERC20Minimal(BASE_WETH).balanceOf(attacker),
            attackerWethBefore,
            "attacker must not extract WETH profit against the real PoolManager"
        );
    }
}
