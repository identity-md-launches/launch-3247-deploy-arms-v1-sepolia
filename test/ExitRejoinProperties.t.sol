// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ArmsBase} from "./ArmsBase.t.sol";
import {Arms} from "../src/Arms.sol";
import {ArmsForms} from "../src/ArmsForms.sol";

/// @dev Adversarial checks of the second-revision exit rule (a bond that cancels an exit no longer resets
/// `lastStateChange`; every bond checkpoint written while exiting records zero). The implementer's
/// `ExitCancelOptOutTest` covers the opt-out direction; these cover the opt-in direction the old
/// `lastStateChange` bump used to guard, and a model-based fuzz over random exit/rejoin/withdraw/post
/// sequences.
contract ExitRejoinPropertiesTest is ArmsBase {
    function _isDrawn(uint256 id, address a) internal view returns (bool) {
        address[] memory drawn = arms.armsOf(id);
        for (uint256 i; i < drawn.length; ++i) {
            if (drawn[i] == a) return true;
        }
        return drawn.length == 0 ? false : _job(id).tieBreaker == a;
    }

    /// @dev Exits `a` fully: request, wait out the delay, withdraw everything unlocked.
    function _exitAll(address a) internal {
        vm.prank(a);
        arms.requestExit();
        vm.warp(block.timestamp + 14 days + 1);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(a);
        arms.withdraw();
    }

    /// An arm that sat below `minBond` (but still listed as a server) when a job was posted cannot use
    /// `requestExit(); bond(big)` after the seed is visible to become drawable for that job: the cancelled
    /// exit no longer bumps `lastStateChange`, so only the posting-time bond checkpoint keeps it out.
    function test_belowMinBondArmCannotOptInByExitAndRejoin() public {
        address a = armSet[0];
        _exitAll(a);
        assertEq(_arm(a).bond, 0);
        // Rejoin with less than `minBond`: still a listed server, not active.
        vm.roll(vm.getBlockNumber() + 1);
        uint256 minBond = arms.minBond();
        vm.prank(a);
        arms.bond(minBond - 1);
        assertFalse(arms.isActive(a), "below minBond");
        uint256 before = arms.lastStateChange(a);

        uint256 id = _post();
        assertEq(arms.formRegistry().bondAsOf(a, id), minBond - 1, "posting-time bond");

        // After the post (seed about to be visible), try to opt in with a cancelled exit.
        vm.roll(vm.getBlockNumber() + 1);
        vm.startPrank(a);
        arms.requestExit();
        arms.bond(ARM_BOND);
        vm.stopPrank();
        assertTrue(arms.isActive(a), "active now");
        assertEq(arms.lastStateChange(a), before, "cancelled exit does not reset the snapshot");

        _fill(id);
        assertFalse(_isDrawn(id, a), "an arm below minBond at posting opted in via requestExit+bond");

        // A later job counts the new bond.
        uint256 later = _post();
        assertEq(arms.formRegistry().bondAsOf(a, later), minBond - 1 + ARM_BOND);
    }

    /// A plain top-up from below `minBond` (no exit) bumps the snapshot, so the same arm cannot join an
    /// older job that way either. Pins the other half of the `!wasActive && !rejoin` condition.
    function test_belowMinBondPlainTopUpResetsSnapshot() public {
        address a = armSet[0];
        _exitAll(a);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(a);
        arms.bond(1);
        uint256 id = _post();
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(a);
        arms.bond(ARM_BOND);
        assertEq(arms.lastStateChange(a), vm.getBlockNumber(), "newly active top-up bumps the snapshot");
        _fill(id);
        assertFalse(_isDrawn(id, a));
    }

    /// `requestExit` twice reverts and leaves the exit timer where it was; a bond during exit clears it.
    function test_requestExitTwiceRevertsAndRejoinClearsTimer() public {
        address a = armSet[1];
        vm.prank(a);
        arms.requestExit();
        uint64 exitAt = _arm(a).exitAt;
        vm.warp(block.timestamp + 1 days);
        vm.prank(a);
        vm.expectRevert(Arms.AlreadyExiting.selector);
        arms.requestExit();
        assertEq(_arm(a).exitAt, exitAt, "timer unchanged");
        vm.prank(a);
        arms.bond(1);
        assertFalse(_arm(a).exiting);
        assertEq(_arm(a).exitAt, 0);
        vm.prank(a);
        vm.expectRevert(Arms.NotExiting.selector);
        arms.withdraw();
    }

    /// Withdraw before the delay reverts, and a rejoin restarts the full delay on the next exit.
    function test_rejoinRestartsTheExitDelay() public {
        address a = armSet[2];
        vm.prank(a);
        arms.requestExit();
        vm.warp(block.timestamp + 14 days - 1);
        vm.prank(a);
        vm.expectRevert(Arms.ExitDelay.selector);
        arms.withdraw();
        vm.startPrank(a);
        arms.bond(1);
        arms.requestExit();
        vm.stopPrank();
        vm.warp(block.timestamp + 2);
        vm.prank(a);
        vm.expectRevert(Arms.ExitDelay.selector);
        arms.withdraw();
    }

    /// forge-config: default.fuzz.runs = 256
    /// Model: the bond a job reads for an arm is zero if the arm was exiting when the job was posted,
    /// else the bond it held then. Any sequence of exit / rejoin / partial top-up / withdraw / post must
    /// keep every job's reading equal to the model, and the arm's bond equal to deposits minus
    /// withdrawals.
    function testFuzz_exitRejoinSequenceMatchesModel(uint256 seed) public {
        address a = armSet[0];
        ArmsForms reg = arms.formRegistry();
        uint256[] memory ids = new uint256[](16);
        uint256[] memory expected = new uint256[](16);
        uint256 posted;
        bool exiting;
        uint256 bondNow = ARM_BOND;
        uint256 balance = token.balanceOf(a);

        for (uint256 step; step < 16; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = r % 4;
            if (op == 0) {
                if (posted == ids.length) continue;
                uint256 id = _post();
                ids[posted] = id;
                expected[posted] = exiting ? 0 : bondNow;
                ++posted;
            } else if (op == 1) {
                if (exiting) {
                    vm.prank(a);
                    vm.expectRevert(Arms.AlreadyExiting.selector);
                    arms.requestExit();
                } else {
                    vm.prank(a);
                    arms.requestExit();
                    exiting = true;
                }
            } else if (op == 2) {
                uint256 amt = bound(r >> 8, 1, 20 ether);
                if (bondNow + amt > 1000 ether || amt > token.balanceOf(a)) continue;
                vm.prank(a);
                arms.bond(amt);
                bondNow += amt;
                exiting = false;
            } else {
                if (!exiting || bondNow == 0) continue;
                vm.warp(block.timestamp + 14 days);
                vm.prank(a);
                arms.withdraw();
                bondNow = 0;
            }
            vm.roll(vm.getBlockNumber() + 1);
        }

        assertEq(_arm(a).bond, bondNow, "bond");
        assertEq(_arm(a).exiting, exiting, "exiting");
        assertEq(arms.isActive(a), !exiting && bondNow >= arms.minBond(), "isActive");
        // Tokens: the arm's wallet plus its bond is what it started with (nothing locked, nothing lost).
        assertEq(token.balanceOf(a) + bondNow, balance + ARM_BOND, "arm conservation");
        for (uint256 i; i < posted; ++i) {
            assertEq(reg.bondAsOf(a, ids[i]), expected[i], "bondAsOf diverged from the exit model");
        }
    }
}
