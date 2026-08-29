// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {CheckpointHook} from "../src/CheckpointHook.sol";

// Deploys a TimelockController and starts the Ownable2Step handover of an already-deployed
// CheckpointHook to it. This is a two-transaction handover by design (Ownable2Step requires the
// new owner to accept, and the timelock can only "act" through its own schedule/execute flow),
// so this script only gets you halfway. See the finishTimelockHandover() instructions below for
// step two, which has to wait out minDelay before it can run.
//
// forge script script/DeployTimelock.s.sol:DeployTimelock \
//   --rpc-url <RPC_URL> --private-key <CURRENT_GOVERNANCE_KEY> --broadcast
//
// env vars:
//   HOOK_ADDRESS      already-deployed CheckpointHook
//   MIN_DELAY         timelock delay in seconds, e.g. 172800 for 2 days
//   PROPOSERS         comma-separated addresses with PROPOSER_ROLE, must include the broadcaster
//                     for this script to also schedule the acceptOwnership call in the same run
//   EXECUTORS         comma-separated addresses with EXECUTOR_ROLE, or "0x0000000000000000000000000000000000000000"
//                     for an open executor role (anyone can execute once an operation is ready)
contract DeployTimelock is Script {
    function run() external returns (TimelockController timelock) {
        CheckpointHook hook = CheckpointHook(vm.envAddress("HOOK_ADDRESS"));
        uint256 minDelay = vm.envUint("MIN_DELAY");
        address[] memory proposers = vm.envAddress("PROPOSERS", ",");
        address[] memory executors = vm.envAddress("EXECUTORS", ",");

        vm.startBroadcast();

        timelock = new TimelockController(minDelay, proposers, executors, address(0));
        console2.log("timelock deployed at:", address(timelock));

        // Step 1 of 2: start the Ownable2Step handover. hook.owner() is unchanged until the
        // timelock itself calls acceptOwnership(), which only happens via schedule + wait + execute.
        hook.transferOwnership(address(timelock));
        console2.log("transferOwnership called, hook.pendingOwner() is now the timelock");

        // If the broadcaster has PROPOSER_ROLE (typical for a bootstrap deploy where governance
        // proposes its own handover), go ahead and schedule the acceptOwnership call too, so
        // there's nothing left to do after minDelay except call execute().
        bytes memory acceptOwnershipCall = abi.encodeCall(Ownable2Step.acceptOwnership, ());
        if (timelock.hasRole(timelock.PROPOSER_ROLE(), msg.sender)) {
            timelock.schedule(address(hook), 0, acceptOwnershipCall, bytes32(0), bytes32(0), minDelay);
            console2.log("acceptOwnership scheduled, ready at timestamp:", block.timestamp + minDelay);
        } else {
            console2.log("broadcaster lacks PROPOSER_ROLE, schedule acceptOwnership separately");
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("After the delay has passed, finish the handover by calling execute() with:");
        console2.log("  target:     ", address(hook));
        console2.log("  value:      0");
        console2.log("  predecessor:", vm.toString(bytes32(0)));
        console2.log("  salt:       ", vm.toString(bytes32(0)));
        console2.log("  payload:    ", vm.toString(acceptOwnershipCall));
    }
}
