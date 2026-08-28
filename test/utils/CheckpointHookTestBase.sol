// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {CheckpointHook} from "../../src/CheckpointHook.sol";

// Shared setup: fresh PoolManager, mine a CREATE2 salt for the hook, deploy it, init a pool with
// enough liquidity that the attack-sim tests don't just blow through the price range.
contract CheckpointHookTestBase is Test, Deployers {
    using StateLibrary for IPoolManager;

    CheckpointHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    address internal governance = makeAddr("governance");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal attacker = makeAddr("attacker");

    uint48 internal constant BLOCK_OFFSET = 5;

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );

        bytes memory constructorArgs = abi.encode(manager, BLOCK_OFFSET, governance, treasury);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(CheckpointHook).creationCode, constructorArgs);

        hook = new CheckpointHook{salt: salt}(manager, BLOCK_OFFSET, governance, treasury);
        require(address(hook) == hookAddress, "hook address mismatch");

        (poolKey, poolId) = initPool(currency0, currency1, IHooks(address(hook)), 3000, 60, SQRT_PRICE_1_1);

        // narrow default range plus a deep full-range position, otherwise the swap sizes in the
        // attack tests just exhaust the pool and hit a price limit revert instead of telling us
        // anything useful
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, "");
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 1e24,
                salt: 0
            }),
            ""
        );
    }
}
