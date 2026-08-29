// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CheckpointHookTestBase} from "./utils/CheckpointHookTestBase.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {CheckpointHook} from "../src/CheckpointHook.sol";

// Covers the governance handover to a TimelockController, not the hook's own logic (that's
// CheckpointHook.t.sol). CheckpointHook itself needed zero changes for this, Ownable2Step already
// supports any address as owner, TimelockController is designed to be dropped in as one.
contract CheckpointHookTimelockTest is CheckpointHookTestBase {
    TimelockController internal timelock;
    address internal proposer = makeAddr("proposer");
    address internal executor = makeAddr("executor");
    uint256 internal constant MIN_DELAY = 2 days;

    function setUp() public override {
        super.setUp();

        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = executor;

        timelock = new TimelockController(MIN_DELAY, proposers, executors, address(0));

        vm.prank(governance);
        hook.transferOwnership(address(timelock));
    }

    function _acceptOwnershipPayload() internal pure returns (bytes memory) {
        return abi.encodeCall(Ownable2Step.acceptOwnership, ());
    }

    function _scheduleAndCompleteHandover() internal {
        vm.prank(proposer);
        timelock.schedule(address(hook), 0, _acceptOwnershipPayload(), bytes32(0), bytes32(0), MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        vm.prank(executor);
        timelock.execute(address(hook), 0, _acceptOwnershipPayload(), bytes32(0), bytes32(0));
    }

    function test_handover_pendingOwnerIsTimelockAfterTransfer() public view {
        assertEq(hook.owner(), governance, "owner unchanged until acceptOwnership");
        assertEq(hook.pendingOwner(), address(timelock));
    }

    function test_handover_completesViaScheduleAndExecute() public {
        _scheduleAndCompleteHandover();
        assertEq(hook.owner(), address(timelock));
    }

    function test_handover_executeBeforeDelayReverts() public {
        vm.prank(proposer);
        timelock.schedule(address(hook), 0, _acceptOwnershipPayload(), bytes32(0), bytes32(0), MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY - 1);

        vm.prank(executor);
        vm.expectRevert();
        timelock.execute(address(hook), 0, _acceptOwnershipPayload(), bytes32(0), bytes32(0));
    }

    function test_handover_nonProposerCannotSchedule() public {
        vm.prank(alice);
        vm.expectRevert();
        timelock.schedule(address(hook), 0, _acceptOwnershipPayload(), bytes32(0), bytes32(0), MIN_DELAY);
    }

    function test_governance_directCallFailsOnceTimelockOwns() public {
        _scheduleAndCompleteHandover();

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, governance));
        hook.setTreasury(makeAddr("newTreasury"));
    }

    function test_governance_setTreasuryThroughTimelock() public {
        _scheduleAndCompleteHandover();

        address newTreasury = makeAddr("newTreasury");
        bytes memory payload = abi.encodeCall(CheckpointHook.setTreasury, (newTreasury));

        vm.prank(proposer);
        timelock.schedule(address(hook), 0, payload, bytes32(0), bytes32(0), MIN_DELAY);

        vm.prank(executor);
        vm.expectRevert();
        timelock.execute(address(hook), 0, payload, bytes32(0), bytes32(0));

        vm.warp(block.timestamp + MIN_DELAY);

        vm.prank(executor);
        timelock.execute(address(hook), 0, payload, bytes32(0), bytes32(0));

        assertEq(hook.treasury(), newTreasury);
    }

    function test_governance_setFeeDestinationThroughTimelock() public {
        _scheduleAndCompleteHandover();

        bytes memory payload =
            abi.encodeCall(CheckpointHook.setFeeDestination, (CheckpointHook.FeeDestination.Treasury));

        vm.prank(proposer);
        timelock.schedule(address(hook), 0, payload, bytes32(0), bytes32(0), MIN_DELAY);
        vm.warp(block.timestamp + MIN_DELAY);
        vm.prank(executor);
        timelock.execute(address(hook), 0, payload, bytes32(0), bytes32(0));

        assertEq(uint8(hook.feeDestination()), uint8(CheckpointHook.FeeDestination.Treasury));
    }
}
