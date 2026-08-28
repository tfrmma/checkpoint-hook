// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {CheckpointHook} from "../src/CheckpointHook.sol";

// forge script script/DeployCheckpointHook.s.sol:DeployCheckpointHook \
//   --rpc-url <RPC_URL> --private-key <DEPLOYER_KEY> --broadcast --verify
//
// env vars:
//   POOL_MANAGER        target chain's v4 PoolManager
//   GOVERNANCE_ADDRESS  owner of the deployed hook, use a multisig, not an EOA
//   TREASURY_ADDRESS    fallback recipient for captured fees
//   BLOCK_NUMBER_OFFSET optional, JIT window in blocks, defaults to 5
//   MIN_TICK_SPACING    optional, floor on pools this hook can attach to, defaults to 60
//                       (Uniswap's medium fee tier spacing), see minTickSpacing on the contract
contract DeployCheckpointHook is Script {
    // Arachnid's deterministic deployment proxy, forge script routes any new X{salt: ...}()
    // through this when broadcasting. Same address on every chain that has it deployed.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external returns (CheckpointHook hook) {
        address poolManagerAddress = vm.envAddress("POOL_MANAGER");
        address governance = vm.envAddress("GOVERNANCE_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        uint48 blockNumberOffset = uint48(vm.envOr("BLOCK_NUMBER_OFFSET", uint256(5)));
        uint24 minTickSpacing = uint24(vm.envOr("MIN_TICK_SPACING", uint256(60)));

        IPoolManager poolManager = IPoolManager(poolManagerAddress);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );

        bytes memory constructorArgs =
            abi.encode(poolManager, blockNumberOffset, governance, treasury, minTickSpacing);
        (address predictedAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(CheckpointHook).creationCode, constructorArgs);

        console2.log("mined hook address:", predictedAddress);
        console2.log("salt:", vm.toString(salt));

        vm.startBroadcast();
        hook = new CheckpointHook{salt: salt}(poolManager, blockNumberOffset, governance, treasury, minTickSpacing);
        vm.stopBroadcast();

        // if this trips, either the flags computed above drifted from getHookPermissions() or
        // the deployer address passed to HookMiner.find doesn't match CREATE2_DEPLOYER
        require(address(hook) == predictedAddress, "address mismatch, salt didn't mine right");

        console2.log("deployed at:", address(hook));
        console2.log("  poolManager    =", address(poolManager));
        console2.log("  governance     =", governance);
        console2.log("  treasury       =", treasury);
        console2.log("  blockOffset    =", blockNumberOffset);
        console2.log("  minTickSpacing =", minTickSpacing);
    }
}
