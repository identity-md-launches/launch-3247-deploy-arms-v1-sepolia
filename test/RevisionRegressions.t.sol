// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ArmsBase} from "./ArmsBase.t.sol";
import {Arms} from "../src/Arms.sol";
import {ArmsForms} from "../src/ArmsForms.sol";
import {ICourt} from "../src/ICourt.sol";
import {IIntake} from "../src/IIntake.sol";
import {IMDCourt} from "../src/IMDCourt.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Regressions for the review findings that reopened the launch
/// @dev One contract per finding; each test names the behaviour the finding reported.
contract RemoteHeadTest is ArmsBase {
    uint256 constant REMOTE = 4663;
    uint256 constant MAX_BLOCK = 9_007_199_254_740_991;

    /// Finding 22cf09bc: a remote `atBlock` is bounded by the court's confirmed head, exactly as a
    /// local one is bounded by this chain's height. Without a published head nothing remote is admitted.
    function test_remotePostIsBoundedByTheCourtsConfirmedHead() public {
        vm.chainId(CHAIN);
        uint256 balance = token.balanceOf(poster);
        court.setConfirmedHead(REMOTE, 0);
        vm.startPrank(poster);
        vm.expectRevert(Arms.BadTarget.selector);
        arms.post(formId, REMOTE, target, 1, FEE);
        vm.expectRevert(Arms.BadTarget.selector);
        arms.post(formId, REMOTE, target, MAX_BLOCK, FEE);
        vm.stopPrank();

        court.setConfirmedHead(REMOTE, 1000);
        vm.startPrank(poster);
        vm.expectRevert(Arms.BadTarget.selector);
        arms.post(formId, REMOTE, target, 996, FEE);
        vm.expectRevert(Arms.BadTarget.selector);
        arms.post(formId, REMOTE, target, MAX_BLOCK, FEE);
        assertEq(token.balanceOf(poster), balance, "nothing moved on a refused post");
        uint256 id = arms.post(formId, REMOTE, target, 995, FEE);
        vm.stopPrank();
        assertEq(_job(id).atBlock, 995);
        // The local chain keeps using its own height, not the court's head.
        vm.roll(AT_BLOCK + 5);
        vm.prank(poster);
        arms.post(formId, CHAIN, target, AT_BLOCK, FEE);
    }

    function testFuzz_remoteBoundary(uint64 rawHead, uint64 rawBlock) public {
        vm.chainId(CHAIN);
        uint256 head = bound(rawHead, 0, MAX_BLOCK);
        uint256 atBlock = bound(rawBlock, 1, MAX_BLOCK);
        court.setConfirmedHead(REMOTE, head);
        vm.prank(poster);
        if (atBlock + 5 > head) vm.expectRevert(Arms.BadTarget.selector);
        arms.post(formId, REMOTE, target, atBlock, FEE);
    }

    /// The real court publishes nothing by default; only its owner moves a head, forward, for a
    /// supported remote chain. Arms wired to it refuses every remote target until then.
    function test_realCourtHeadIsOwnerPublishedForwardOnlyAndRemoteOnly() public {
        vm.chainId(CHAIN);
        address owner = makeAddr("courtOwner");
        IMDCourt real = new IMDCourt(
            owner,
            IIntake(makeAddr("intake")),
            IERC20(address(token)),
            bytes32("oracle.request@oracle-1"),
            makeAddr("s")
        );
        assertEq(real.confirmedHead(REMOTE), 0);
        Arms wired = _deploy(sepoliaParams(address(token), address(real)));
        bytes32 form = wired.registerForm(keccak256("remote form"), KEYS, "ipfs://remote-form");
        vm.prank(poster);
        token.approve(address(wired), type(uint256).max);
        vm.prank(poster);
        vm.expectRevert(Arms.BadTarget.selector);
        wired.post(form, REMOTE, target, 1, FEE);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        real.setConfirmedHead(REMOTE, 1000);
        vm.startPrank(owner);
        vm.expectRevert(IMDCourt.BadParams.selector);
        real.setConfirmedHead(1, 1000); // not a supported target chain
        vm.expectRevert(IMDCourt.BadParams.selector);
        real.setConfirmedHead(CHAIN, 1000); // the executing chain vouches for itself
        vm.expectRevert(IMDCourt.BadParams.selector);
        real.setConfirmedHead(REMOTE, 0);
        real.setConfirmedHead(REMOTE, 1000);
        vm.expectRevert(IMDCourt.BadParams.selector);
        real.setConfirmedHead(REMOTE, 1000); // heads only move forward
        vm.expectRevert(IMDCourt.BadParams.selector);
        real.setConfirmedHead(REMOTE, 999);
        real.setConfirmedHead(REMOTE, 1001);
        vm.stopPrank();
        assertEq(real.confirmedHead(REMOTE), 1001);
        vm.prank(poster);
        uint256 id = wired.post(form, REMOTE, target, 996, FEE);
        (, bytes memory d) = address(wired).staticcall(abi.encodeWithSelector(wired.jobs.selector, id));
        Arms.Job memory wj = abi.decode(d, (Arms.Job));
        assertEq(wj.atBlock, 996);
    }
}

contract DrawOptOutTest is ArmsBase {
    /// @dev Posts a job and mines its seed block, so the first pick of the draw is public knowledge.
    function _postAndRevealSeed() internal returns (uint256 id, address firstPick) {
        id = _post();
        Arms.Job memory j = _job(id);
        vm.roll(j.seedBlock + 1);
        uint256 seed = uint256(keccak256(abi.encode(blockhash(j.seedBlock), id, uint256(0))));
        uint256 idx = uint256(keccak256(abi.encode(seed, uint256(0)))) % j.serverCount;
        firstPick = arms.formRegistry().serversOf(formId)[idx];
    }

    function _isDrawn(uint256 id, address a) internal view returns (bool) {
        address[] memory drawn = arms.armsOf(id);
        for (uint256 i; i < drawn.length; ++i) {
            if (drawn[i] == a) return true;
        }
        return false;
    }

    function _indexOf(address a) internal view returns (uint256) {
        address[] memory list = arms.formRegistry().serversOf(formId);
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == a) return i;
        }
        revert("not listed");
    }

    /// Finding 27019183: a re-serve at the same fee, a 1 wei top-up or a fee raise after the seed is
    /// visible no longer removes an eligible arm from the job.
    function test_reServeDoesNotOptOutOfAnOlderJob() public {
        (uint256 id, address dodger) = _postAndRevealSeed();
        uint256 before = arms.lastStateChange(dodger);
        vm.prank(dodger);
        arms.serve(formId, FEE);
        assertEq(arms.lastStateChange(dodger), before, "a serve is prospective by job id, not a snapshot reset");
        arms.draw(id);
        assertTrue(_isDrawn(id, dodger));
    }

    function test_topUpDoesNotOptOutOfAnOlderJob() public {
        (uint256 id, address dodger) = _postAndRevealSeed();
        uint256 before = arms.lastStateChange(dodger);
        vm.prank(dodger);
        arms.bond(1);
        assertEq(arms.lastStateChange(dodger), before, "an active arm's top-up is not a snapshot reset");
        arms.draw(id);
        assertTrue(_isDrawn(id, dodger));
    }

    function test_feeRaiseDoesNotApplyToAnOlderJob() public {
        (uint256 id, address dodger) = _postAndRevealSeed();
        vm.prank(dodger);
        arms.serve(formId, FEE + 1);
        ArmsForms reg = arms.formRegistry();
        assertEq(reg.candidate(formId, _indexOf(dodger), id, FEE), dodger, "older job keeps the old fee");
        assertEq(reg.feeAsOf(formId, dodger, id), FEE);
        assertEq(reg.minFeeOf(formId, dodger), FEE + 1, "the current fee is the raised one");
        arms.draw(id);
        assertTrue(_isDrawn(id, dodger));
        // A job posted after the raise sees the new fee.
        uint256 next = _post();
        assertEq(reg.candidate(formId, _indexOf(dodger), next, FEE), address(0));
        assertEq(reg.candidate(formId, _indexOf(dodger), next, FEE + 1), dodger);
    }

    /// The other direction is closed too: nothing done after a post makes an arm eligible for it.
    function test_lateServeFeeCutOrReServeDoesNotOptIn() public {
        // An arm that first serves after the post is not a candidate for it.
        address late = makeAddr("late");
        _fund(late, 1000 ether);
        vm.prank(late);
        arms.bond(ARM_BOND);
        uint256 id = _post();
        vm.prank(late);
        arms.serve(formId, FEE);
        ArmsForms reg = arms.formRegistry();
        assertEq(reg.feeAsOf(formId, late, id), 0);
        assertEq(reg.candidate(formId, _indexOf(late), id, FEE), address(0), "late serve does not join");
        assertEq(reg.candidate(formId, _indexOf(late), _post(), FEE), late, "but serves later jobs");

        // A fee cut after the post does not join either.
        address pricey = armSet[0];
        vm.prank(pricey);
        arms.serve(formId, 5 * FEE);
        uint256 cheap = _post();
        vm.prank(pricey);
        arms.serve(formId, FEE);
        assertEq(reg.candidate(formId, _indexOf(pricey), cheap, FEE), address(0), "fee cut does not join");

        // A stop followed by a re-serve skips the jobs posted in between.
        address stopper = armSet[1];
        vm.prank(stopper);
        arms.stopServing(formId);
        uint256 during = _post();
        vm.prank(stopper);
        arms.serve(formId, FEE);
        assertEq(reg.candidate(formId, _indexOf(stopper), during, FEE), address(0), "re-serve does not join");
        assertEq(reg.candidate(formId, _indexOf(stopper), _post(), FEE), stopper);
    }

    /// A top-up after the post does not count toward the tranche the job needs: the arm is judged on
    /// the bond it had when the job was posted.
    function test_topUpAfterPostDoesNotOptIn() public {
        address low = makeAddr("low");
        _fund(low, 1000 ether);
        bytes32 form = arms.registerForm(keccak256("two servers"), KEYS, "ipfs://two");
        vm.startPrank(low);
        arms.bond(arms.minBond()); // 20 ARMT: active, but below the 30 ARMT tranche of a 3 ARMT job
        arms.serve(form, FEE);
        vm.stopPrank();
        vm.prank(armSet[0]);
        arms.serve(form, FEE);
        vm.prank(armSet[1]);
        arms.serve(form, FEE);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(poster);
        uint256 id = arms.post(form, CHAIN, target, AT_BLOCK, 3 * FEE);
        vm.prank(low);
        arms.bond(400 ether);
        assertEq(arms.formRegistry().bondAsOf(low, id), arms.minBond());
        for (uint256 i; i < 12 && _job(id).phase == Arms.Phase.OPEN; ++i) {
            vm.roll(vm.getBlockNumber() + 2);
            arms.draw(id);
        }
        assertEq(uint8(_job(id).phase), uint8(Arms.Phase.COMMIT), "the two eligible arms fill it");
        assertFalse(_isDrawn(id, low), "the topped-up arm was not eligible when the job was posted");
        // A job posted after the top-up counts the whole bond.
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(poster);
        uint256 next = arms.post(form, CHAIN, target, AT_BLOCK, 3 * FEE);
        assertEq(arms.formRegistry().bondAsOf(low, next), arms.minBond() + 400 ether);
    }

    /// `lastStateChange` still moves when a bond makes the arm newly active, so a newly active arm cannot
    /// join an older job either. A bond that cancels an exit does not move it (finding cab68d38): the
    /// jobs posted during the exit are closed by the zero bond `requestExit` checkpointed instead.
    function test_newlyActiveBondStillInvalidatesOlderJobs() public {
        address fresh = makeAddr("fresh");
        _fund(fresh, 1000 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(fresh);
        arms.bond(ARM_BOND);
        assertEq(arms.lastStateChange(fresh), vm.getBlockNumber(), "first activation resets the snapshot");

        address leaver = armSet[2];
        uint256 before = arms.lastStateChange(leaver);
        vm.prank(leaver);
        arms.requestExit();
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(leaver);
        arms.bond(1);
        assertEq(arms.lastStateChange(leaver), before, "a cancelled exit does not reset the snapshot");
    }
}

/// @dev Finding cab68d38: `requestExit(); bond(1)` after the seed is visible used to bump
/// `lastStateChange` and so removed an eligible arm from an older job for one wei. Now a cancelled exit
/// is prospective by job id like the exit itself: the arm keeps every job it was eligible for when it
/// asked to exit and never gains one posted while it was exiting.
contract ExitCancelOptOutTest is ArmsBase {
    function _postAndRevealSeed() internal returns (uint256 id, address firstPick) {
        id = _post();
        Arms.Job memory j = _job(id);
        vm.roll(j.seedBlock + 1);
        uint256 seed = uint256(keccak256(abi.encode(blockhash(j.seedBlock), id, uint256(0))));
        uint256 idx = uint256(keccak256(abi.encode(seed, uint256(0)))) % j.serverCount;
        firstPick = arms.formRegistry().serversOf(formId)[idx];
        assertTrue(arms.isActive(firstPick));
    }

    function _isDrawn(uint256 id, address a) internal view returns (bool) {
        address[] memory drawn = arms.armsOf(id);
        for (uint256 i; i < drawn.length; ++i) {
            if (drawn[i] == a) return true;
        }
        return false;
    }

    /// The reviewer's scenario: the first pick exits and re-bonds one wei in the block after the seed.
    function test_exitThenOneWeiBondDoesNotOptOutOfAnOlderJob() public {
        (uint256 id, address dodger) = _postAndRevealSeed();
        uint256 before = arms.lastStateChange(dodger);
        vm.startPrank(dodger);
        arms.requestExit();
        arms.bond(1);
        vm.stopPrank();
        assertTrue(arms.isActive(dodger), "active again");
        assertEq(arms.lastStateChange(dodger), before, "a cancelled exit is not a snapshot reset");
        assertEq(arms.formRegistry().bondAsOf(dodger, id), ARM_BOND, "the older job reads the bond it had");
        arms.draw(id);
        assertTrue(_isDrawn(id, dodger), "requestExit + bond(1) opted the arm out of an older job");
    }

    /// The direction the old bump guarded: a job posted (in a later block) while the arm was exiting
    /// stays closed to it after the rejoin, because `requestExit` checkpointed a zero bond for it.
    function test_jobPostedDuringExitStaysClosedAfterRejoin() public {
        address leaver = armSet[0];
        vm.prank(leaver);
        arms.requestExit();
        uint256 during = _post(); // a later block: `lastStateChange` alone would not exclude it
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(leaver);
        arms.bond(1);
        assertTrue(arms.isActive(leaver));
        assertEq(arms.formRegistry().bondAsOf(leaver, during), 0, "posted while exiting");
        _fill(during);
        assertFalse(_isDrawn(during, leaver), "an exit cancelled after the post cannot join it");
        uint256 after_ = _post();
        assertEq(arms.formRegistry().bondAsOf(leaver, after_), ARM_BOND + 1, "later jobs count the bond");
    }

    /// Two exit/rejoin cycles: the jobs of the first exit stay closed after the second, and a job
    /// posted between the cycles stays open to the arm through its second exit.
    function test_everyExitIntervalStaysClosedAcrossCycles() public {
        address leaver = armSet[0];
        vm.prank(leaver);
        arms.requestExit();
        uint256 first = _post();
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(leaver);
        arms.bond(1);
        uint256 between = _post();
        vm.prank(leaver);
        arms.requestExit();
        uint256 second = _post();
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(leaver);
        arms.bond(1);
        ArmsForms reg = arms.formRegistry();
        assertEq(reg.bondAsOf(leaver, first), 0, "first exit interval");
        assertEq(reg.bondAsOf(leaver, between), ARM_BOND + 1, "between the cycles");
        assertEq(reg.bondAsOf(leaver, second), 0, "second exit interval");
        _fill(first);
        assertFalse(_isDrawn(first, leaver));
        _fill(second);
        assertFalse(_isDrawn(second, leaver));
    }

    /// Any bond checkpoint written while exiting (here a partial withdrawal) records zero, so a job
    /// posted after it is still closed once the arm rejoins.
    function test_checkpointsWrittenWhileExitingRecordZero() public {
        address leaver = armSet[0];
        vm.prank(leaver);
        arms.requestExit();
        vm.warp(block.timestamp + 14 days);
        vm.prank(leaver);
        arms.withdraw();
        assertEq(arms.unlockedBond(leaver), 0);
        uint256 during = _post();
        vm.prank(leaver);
        arms.bond(ARM_BOND);
        assertTrue(arms.isActive(leaver));
        assertEq(arms.formRegistry().bondAsOf(leaver, during), 0);
        _fill(during);
        assertFalse(_isDrawn(during, leaver));
    }
}

contract ClaimedAfterNeitherTest is ArmsBase {
    /// Finding b3e816d4: a CLAIMED ruling corrects a key an earlier NEITHER ruling overturned.
    function test_claimedAfterNeitherOnTheSameKeyCorrectsIt() public {
        (uint256 id, bytes32[] memory v) = _settledJob();
        bytes32 right = keccak256("Y-right");
        bytes32 junk = keccak256("Z-junk");
        address other = makeAddr("other");
        _fund(other, 1000 ether);
        bytes32 caseRight = _challenge(id, 0, right);
        vm.prank(other);
        bytes32 caseJunk = arms.challenge(id, 0, junk, COURT_FEE);
        _rule(caseJunk, ICourt.Ruling.NEITHER);
        _rule(caseRight, ICourt.Ruling.CLAIMED);

        address[] memory drawn = arms.armsOf(id);
        uint256 bondBefore = _arm(drawn[0]).bond;
        uint256 supplyBefore = token.totalSupply();
        arms.resolve(id, 0, junk);
        (bytes32 value, Arms.Status st) = arms.results(id, 0);
        assertEq(uint8(st), uint8(Arms.Status.OVERTURNED));
        assertEq(value, v[0]);
        uint256 burnedByNeither = supplyBefore - token.totalSupply();

        uint256 chBefore = token.balanceOf(challenger);
        arms.resolve(id, 0, right);
        (value, st) = arms.results(id, 0);
        assertEq(uint8(st), uint8(Arms.Status.CORRECTED), "the attested value is recorded");
        assertEq(value, right);
        assertEq(_arm(drawn[0]).bond, bondBefore - TRANCHE, "each arm lost exactly one tranche");
        assertEq(_arm(drawn[1]).bond, bondBefore - TRANCHE);
        assertEq(supplyBefore - token.totalSupply(), burnedByNeither, "nothing more was burned by the second ruling");
        assertGt(token.balanceOf(challenger), chBefore + STAKE, "stake back plus the reward");
        assertEq(arms.verdict(id).values[0], right);
        assertEq(arms.totalStakes(), 0);
        assertEq(arms.totalRewards(), 0);
    }

    /// Resolving in the other order gives the same stored outcome.
    function test_claimedThenNeitherLeavesTheCorrection() public {
        (uint256 id,) = _settledJob();
        bytes32 right = keccak256("Y-right");
        bytes32 junk = keccak256("Z-junk");
        address other = makeAddr("other");
        _fund(other, 1000 ether);
        bytes32 caseRight = _challenge(id, 0, right);
        vm.prank(other);
        bytes32 caseJunk = arms.challenge(id, 0, junk, COURT_FEE);
        _rule(caseJunk, ICourt.Ruling.NEITHER);
        _rule(caseRight, ICourt.Ruling.CLAIMED);
        arms.resolve(id, 0, right);
        arms.resolve(id, 0, junk);
        (bytes32 value, Arms.Status st) = arms.results(id, 0);
        assertEq(uint8(st), uint8(Arms.Status.CORRECTED));
        assertEq(value, right);
    }
}

contract LatestVerdictTest is ArmsBase {
    /// @dev Posts until a two-arm job is in COMMIT; three-arm spot checks are finished honestly.
    function _twoArmJob() internal returns (uint256 id) {
        for (uint256 i; i < 40; ++i) {
            id = _post();
            _fill(id);
            if (arms.armsOf(id).length == 2) return id;
            _answerAll(id, _vals("filler"));
            arms.settle(id);
        }
        revert("no two-arm job");
    }

    /// Finding 31484f86: one arm answering UNKNOWN on every key settles the job with no answer, and
    /// that job does not replace the target's latest verdict.
    function test_allUnknownJobDoesNotReplaceTheLatestVerdict() public {
        uint256 first = _twoArmJob();
        bytes32[] memory truth = _vals("truth");
        _answerAll(first, truth);
        arms.settle(first);
        (uint256 latestId,) = arms.latest(CHAIN, target, formId);
        assertEq(latestId, first);

        uint256 second = _twoArmJob();
        address[] memory drawn = arms.armsOf(second);
        bytes32[] memory unknown = new bytes32[](KEYS);
        for (uint256 k; k < KEYS; ++k) {
            unknown[k] = arms.UNKNOWN();
        }
        _commit(second, drawn[0], truth);
        _commit(second, drawn[1], unknown);
        _reveal(second, drawn[0], truth);
        _reveal(second, drawn[1], unknown);
        arms.settle(second);
        for (uint8 k; k < KEYS; ++k) {
            (, Arms.Status s) = arms.results(second, k);
            assertEq(uint8(s), uint8(Arms.Status.UNRESOLVED));
        }
        Arms.Verdict memory lv;
        (latestId, lv) = arms.latest(CHAIN, target, formId);
        assertEq(latestId, first, "a job with no answer on any key is not the latest");
        assertEq(lv.values[0], truth[0]);
    }

    /// A job about an older block than the recorded verdict's does not replace it; one about the same
    /// or a newer block does.
    function test_olderBlockDoesNotReplaceTheLatestVerdict() public {
        (uint256 first,) = _settledJob(); // AT_BLOCK
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(poster);
        uint256 old = arms.post(formId, CHAIN, target, 1, FEE);
        _fill(old);
        _answerAll(old, _vals("old reading"));
        arms.settle(old);
        (uint256 latestId,) = arms.latest(CHAIN, target, formId);
        assertEq(latestId, first, "an older block is not the latest");
        (, Arms.Status st) = arms.results(old, 0);
        assertEq(uint8(st), uint8(Arms.Status.AGREED), "the older job itself still settled with answers");

        (uint256 same,) = _settledJob(); // AT_BLOCK again
        (latestId,) = arms.latest(CHAIN, target, formId);
        assertEq(latestId, same, "the same block, settled later, is the latest");

        vm.roll(AT_BLOCK + 10);
        vm.chainId(CHAIN);
        vm.prank(poster);
        uint256 newer = arms.post(formId, CHAIN, target, AT_BLOCK + 1, FEE);
        _fill(newer);
        _answerAll(newer, _vals("newer"));
        arms.settle(newer);
        (latestId,) = arms.latest(CHAIN, target, formId);
        assertEq(latestId, newer);
    }

    /// A job with answers on some keys only still counts as an answer.
    function test_partlyAnsweredJobIsTheLatest() public {
        (uint256 first,) = _settledJob();
        uint256 id = _twoArmJob();
        address[] memory drawn = arms.armsOf(id);
        bytes32[] memory a = _vals("truth");
        bytes32[] memory b = _vals("truth");
        b[1] = arms.UNKNOWN();
        _commit(id, drawn[0], a);
        _commit(id, drawn[1], b);
        _reveal(id, drawn[0], a);
        _reveal(id, drawn[1], b);
        arms.settle(id);
        (uint256 latestId,) = arms.latest(CHAIN, target, formId);
        assertEq(latestId, id);
        assertGt(id, first);
    }
}

contract StoredStakeTest is ArmsBase {
    /// Advisory 42d06392: the split is gated on the key, not the job, so the order of two resolves no
    /// longer changes who keeps the stake, and a challenge on a correct key is never stake-free.
    function test_storedRulingForfeitsTheStakeInEitherResolveOrder() public {
        for (uint256 order; order < 2; ++order) {
            (uint256 id,) = _settledJob();
            address wrong = makeAddr(string.concat("wrong", vm.toString(order)));
            _fund(wrong, 1000 ether);
            bytes32 c0 = _challenge(id, 0, keccak256("k0"));
            vm.prank(wrong);
            bytes32 c1 = arms.challenge(id, 1, keccak256("junk"), COURT_FEE);
            _rule(c0, ICourt.Ruling.CLAIMED);
            _rule(c1, ICourt.Ruling.STORED);
            uint256 wrongBefore = token.balanceOf(wrong);
            uint256 supplyBefore = token.totalSupply();
            if (order == 0) {
                arms.resolve(id, 1, keccak256("junk"));
                arms.resolve(id, 0, keccak256("k0"));
            } else {
                arms.resolve(id, 0, keccak256("k0"));
                arms.resolve(id, 1, keccak256("junk"));
            }
            assertEq(token.balanceOf(wrong), wrongBefore, "the wrong challenger keeps no stake in either order");
            // Both arms gave key 0's wrong value and were slashed, so nobody is left to receive key 1's
            // stake: it burns, on top of the slash's own burn.
            assertGt(supplyBefore - token.totalSupply(), 0);
            assertEq(arms.totalStakes(), 0);
            assertTrue(arms.verdict(id).overturned);
            vm.warp(block.timestamp + 1);
        }
    }

    /// With no other key overturned, the stake still goes to the arms that gave the value.
    function test_storedRulingPaysTheGivers() public {
        (uint256 id,) = _settledJob();
        bytes32 c = _challenge(id, 1, keccak256("junk"));
        _rule(c, ICourt.Ruling.STORED);
        address[] memory drawn = arms.armsOf(id);
        uint256 a0 = token.balanceOf(drawn[0]);
        uint256 a1 = token.balanceOf(drawn[1]);
        arms.resolve(id, 1, keccak256("junk"));
        assertEq(token.balanceOf(drawn[0]) - a0 + token.balanceOf(drawn[1]) - a1, STAKE);
    }

    /// A stake-free lock is gone: after a STORED ruling the job can be released as before.
    function test_releaseAfterStoredRulingOnAnOverturnedJob() public {
        (uint256 id,) = _settledJob();
        bytes32 c0 = _challenge(id, 0, keccak256("k0"));
        bytes32 c1 = _challenge(id, 1, keccak256("junk"));
        _rule(c0, ICourt.Ruling.CLAIMED);
        _rule(c1, ICourt.Ruling.STORED);
        arms.resolve(id, 0, keccak256("k0"));
        arms.resolve(id, 1, keccak256("junk"));
        vm.warp(uint256(_job(id).challengeEnd) + 1);
        arms.release(id);
        assertTrue(_job(id).released);
    }
}
