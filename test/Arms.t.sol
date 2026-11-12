// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ArmsBase} from "./ArmsBase.t.sol";
import {Arms} from "../src/Arms.sol";
import {ICourt} from "../src/ICourt.sol";
import {MockCourt} from "../src/mocks/MockCourt.sol";

contract ArmsTest is ArmsBase {
    // ------------------------------------------------------------------ bonds

    function test_bond_capsAndExit() public {
        address a = makeAddr("newArm");
        _fund(a, 2000 ether);
        vm.startPrank(a);
        vm.expectRevert(Arms.ZeroAmount.selector);
        arms.bond(0);
        vm.expectRevert(Arms.BondCap.selector);
        arms.bond(1000 ether + 1);
        arms.bond(10 ether);
        assertFalse(arms.isActive(a), "below minBond");
        arms.bond(10 ether);
        assertTrue(arms.isActive(a));
        vm.expectRevert(Arms.NotExiting.selector);
        arms.withdraw();
        arms.requestExit();
        assertFalse(arms.isActive(a), "exit stops draws");
        vm.expectRevert(Arms.AlreadyExiting.selector);
        arms.requestExit();
        vm.expectRevert(Arms.ExitDelay.selector);
        arms.withdraw();
        vm.warp(vm.getBlockTimestamp() + 14 days);
        uint256 before = token.balanceOf(a);
        arms.withdraw();
        assertEq(token.balanceOf(a) - before, 20 ether);
        assertEq(_arm(a).bond, 0);
        // Bonding again cancels the exit.
        arms.bond(20 ether);
        assertTrue(arms.isActive(a));
        vm.stopPrank();
    }

    function test_bond_totalCap() public {
        Arms.Params memory p = sepoliaParams(address(token), address(court));
        p.maxTotalBonded = 30 ether;
        p.maxBondPerArm = 30 ether;
        Arms small = new Arms(
            p.token,
            p.court,
            p.minFeePerArm,
            p.maxBondPerArm,
            p.maxTotalBonded,
            p.trancheMultiple,
            p.burnBps,
            p.challengerRewardBps,
            p.commitWindow,
            p.revealWindow,
            p.challengeWindow,
            p.courtDeadline,
            p.exitDelay
        );
        vm.startPrank(poster);
        token.approve(address(small), type(uint256).max);
        small.bond(25 ether);
        vm.expectRevert(Arms.BondCap.selector);
        small.bond(6 ether);
        vm.stopPrank();
    }

    function test_constructor_rejectsBadParams() public {
        Arms.Params memory p = sepoliaParams(address(token), address(court));
        p.trancheMultiple = 2; // the first slash could not cover the refund
        vm.expectRevert(Arms.BadParams.selector);
        new Arms(
            p.token,
            p.court,
            p.minFeePerArm,
            p.maxBondPerArm,
            p.maxTotalBonded,
            p.trancheMultiple,
            p.burnBps,
            p.challengerRewardBps,
            p.commitWindow,
            p.revealWindow,
            p.challengeWindow,
            p.courtDeadline,
            p.exitDelay
        );
        p = sepoliaParams(address(token), address(court));
        p.burnBps = 10_001;
        vm.expectRevert(Arms.BadParams.selector);
        new Arms(
            p.token,
            p.court,
            p.minFeePerArm,
            p.maxBondPerArm,
            p.maxTotalBonded,
            p.trancheMultiple,
            p.burnBps,
            p.challengerRewardBps,
            p.commitWindow,
            p.revealWindow,
            p.challengeWindow,
            p.courtDeadline,
            p.exitDelay
        );
        p = sepoliaParams(address(token), address(court));
        p.court = address(0);
        vm.expectRevert(Arms.BadParams.selector);
        new Arms(
            p.token,
            p.court,
            p.minFeePerArm,
            p.maxBondPerArm,
            p.maxTotalBonded,
            p.trancheMultiple,
            p.burnBps,
            p.challengerRewardBps,
            p.commitWindow,
            p.revealWindow,
            p.challengeWindow,
            p.courtDeadline,
            p.exitDelay
        );
    }

    function test_withdraw_onlyUnlocked() public {
        uint256 id = _post();
        _fill(id);
        address a = arms.armsOf(id)[0];
        assertEq(_arm(a).locked, TRANCHE);
        vm.startPrank(a);
        arms.requestExit();
        vm.warp(vm.getBlockTimestamp() + 14 days);
        arms.withdraw();
        vm.stopPrank();
        assertEq(_arm(a).bond, TRANCHE, "tranche stays locked");
        assertEq(arms.unlockedBond(a), 0);
    }

    function test_setSigner_commitsAndReveals() public {
        uint256 id = _post();
        _fill(id);
        address a = arms.armsOf(id)[0];
        address b = arms.armsOf(id)[1];
        address signer = makeAddr("signer");
        vm.prank(a);
        arms.setSigner(signer);
        vm.prank(b);
        arms.setSigner(signer);
        bytes32[] memory v = _vals("truth");
        vm.prank(signer);
        arms.commit(id, a, keccak256(abi.encode(id, a, v, _salt(a))));
        _commit(id, b, v);
        vm.prank(signer);
        arms.reveal(id, a, v, _salt(a), "ipfs://e");
        _reveal(id, b, v);
        // The signer may only commit and reveal: it has no bond of its own to withdraw.
        vm.prank(signer);
        vm.expectRevert(Arms.NotExiting.selector);
        arms.withdraw();
        // A stranger cannot act for the arm.
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Arms.NotOnJob.selector);
        arms.commit(id, a, bytes32(0));
        // Clearing this arm's signer leaves the other arm's delegation intact.
        vm.prank(a);
        arms.setSigner(address(0));
        assertEq(_arm(a).signer, address(0));
        assertEq(_arm(b).signer, signer);
    }

    // ------------------------------------------------------------------ forms

    function test_registerForm_rules() public {
        vm.expectRevert(Arms.FormExists.selector);
        arms.registerForm(
            keccak256("Arms form v1: four questions about a target contract"),
            KEYS,
            "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/form.md"
        );
        vm.expectRevert(Arms.BadForm.selector);
        arms.registerForm(keccak256("f2"), 0, "x");
        vm.expectRevert(Arms.BadForm.selector);
        arms.registerForm(keccak256("f2"), 33, "x");
        bytes memory long = new bytes(201);
        for (uint256 i; i < 201; ++i) {
            long[i] = "a";
        }
        vm.expectRevert(Arms.BadForm.selector);
        arms.registerForm(keccak256("f2"), 1, string(long));
        vm.expectRevert(Arms.BadForm.selector);
        arms.registerForm(keccak256("f2"), 1, unicode"ipfs://é");
        vm.expectRevert(Arms.BadForm.selector);
        arms.registerForm(keccak256("f2"), 1, 'has"quote');
        bytes32 f2 = arms.registerForm(keccak256("f2"), 32, "ipfs://ok");
        (uint8 kc, string memory uri) = arms.formRegistry().forms(f2);
        assertEq(kc, 32);
        assertEq(uri, "ipfs://ok");
    }

    function test_serve_rules() public {
        address a = armSet[0];
        vm.startPrank(a);
        vm.expectRevert(Arms.UnknownForm.selector);
        arms.serve(keccak256("nope"), FEE);
        vm.expectRevert(Arms.FeeTooLow.selector);
        arms.serve(formId, FEE - 1);
        arms.serve(formId, 2 * FEE);
        assertEq(arms.formRegistry().minFeeOf(formId, a), 2 * FEE);
        assertEq(arms.formRegistry().serversOf(formId).length, 6);
        arms.stopServing(formId);
        assertEq(arms.formRegistry().serversOf(formId).length, 6);
        assertEq(arms.formRegistry().minFeeOf(formId, a), 2 * FEE);
        assertGt(arms.formRegistry().stoppedAt(formId, a), 0);
        vm.expectRevert(Arms.UnknownForm.selector);
        arms.stopServing(formId);
        vm.stopPrank();
        // Stopping leaves every address at its permanent index.
        vm.prank(armSet[5]);
        arms.stopServing(formId);
        assertEq(arms.formRegistry().serversOf(formId).length, 6);
    }

    // ------------------------------------------------------------------ jobs

    function test_post_rules() public {
        vm.startPrank(poster);
        vm.expectRevert(Arms.UnknownForm.selector);
        arms.post(keccak256("nope"), CHAIN, target, AT_BLOCK, FEE);
        vm.expectRevert(Arms.FeeTooLow.selector);
        arms.post(formId, CHAIN, target, AT_BLOCK, FEE - 1);
        vm.expectRevert(Arms.ChainNotAllowed.selector);
        arms.post(formId, 1, target, AT_BLOCK, FEE);
        vm.expectRevert(Arms.BadTarget.selector);
        arms.post(formId, CHAIN, address(0), AT_BLOCK, FEE);
        vm.expectRevert(Arms.BadTarget.selector);
        arms.post(formId, CHAIN, target, 0, FEE);
        uint256 before = token.balanceOf(poster);
        uint256 id = arms.post(formId, 4663, target, AT_BLOCK, 2 * FEE);
        vm.stopPrank();
        assertEq(before - token.balanceOf(poster), 6 * FEE);
        assertEq(arms.totalEscrow(), 6 * FEE);
        Arms.Job memory j = _job(id);
        assertEq(uint8(j.phase), uint8(Arms.Phase.OPEN));
        assertEq(j.seedBlock, vm.getBlockNumber() + 1);
    }

    function test_draw_tooEarlyThenFills() public {
        uint256 id = _post();
        vm.expectRevert(Arms.TooEarly.selector);
        arms.draw(id);
        vm.roll(vm.getBlockNumber() + 1);
        vm.expectRevert(Arms.TooEarly.selector);
        arms.draw(id);
        vm.roll(vm.getBlockNumber() + 1);
        arms.draw(id);
        Arms.Job memory j = _job(id);
        address[] memory drawn = arms.armsOf(id);
        assertEq(drawn.length, j.needed);
        assertTrue(drawn[0] != drawn[1], "distinct");
        assertTrue(drawn[0] != poster && drawn[1] != poster);
        assertEq(_arm(drawn[0]).locked, TRANCHE);
        assertEq(uint8(j.phase), uint8(Arms.Phase.COMMIT));
        assertEq(j.deadline, vm.getBlockTimestamp() + 6 hours);
        vm.expectRevert(Arms.WrongPhase.selector);
        arms.draw(id);
    }

    function test_draw_excludesPosterAndIneligible() public {
        // Only two servers remain: one is the poster, one asks too high a fee -> no candidates.
        for (uint256 i = 2; i < 6; ++i) {
            vm.prank(armSet[i]);
            arms.stopServing(formId);
        }
        vm.prank(armSet[1]);
        arms.serve(formId, 5 * FEE);
        _fund(armSet[0], 0 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(armSet[0]);
        uint256 id = arms.post(formId, CHAIN, target, AT_BLOCK, FEE);
        vm.roll(vm.getBlockNumber() + 2);
        arms.draw(id);
        // A fee update after posting is excluded from that job too.
        vm.prank(armSet[1]);
        arms.serve(formId, FEE);
        vm.prank(armSet[1]);
        arms.requestExit();
        arms.draw(id);
        // Re-serving after posting cannot join the old snapshot.
        vm.prank(armSet[2]);
        arms.serve(formId, FEE);
        arms.draw(id);
        Arms.Job memory j = _job(id);
        if (j.needed == 2) {
            assertEq(arms.armsOf(id).length, 0);
            assertEq(uint8(j.phase), uint8(Arms.Phase.OPEN));
        }
    }

    function test_draw_expiredSeedIsNeverReplaced() public {
        uint256 id = _post();
        uint256 seedBlock = _job(id).seedBlock;
        vm.roll(vm.getBlockNumber() + 300);
        vm.expectRevert(Arms.SeedExpired.selector);
        arms.draw(id);
        Arms.Job memory j = _job(id);
        assertEq(uint8(j.phase), uint8(Arms.Phase.OPEN));
        assertEq(j.seedBlock, seedBlock, "the seed block never moves");
        assertEq(j.drawSeed, 0);
        assertEq(arms.armsOf(id).length, 0);
    }

    function test_cancel_refundsAndUnlocks() public {
        uint256 id = _post();
        vm.expectRevert(Arms.TooEarly.selector);
        arms.cancel(id);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        uint256 before = token.balanceOf(poster);
        arms.cancel(id);
        assertEq(token.balanceOf(poster) - before, 3 * FEE);
        assertEq(arms.totalEscrow(), 0);
        assertEq(uint8(_job(id).phase), uint8(Arms.Phase.CANCELLED));
        vm.expectRevert(Arms.WrongPhase.selector);
        arms.cancel(id);
        // A filled job cannot be cancelled.
        uint256 id2 = _post();
        _fill(id2);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.expectRevert(Arms.WrongPhase.selector);
        arms.cancel(id2);
    }

    function test_commitReveal_rules() public {
        uint256 id = _post();
        _fill(id);
        address a = arms.armsOf(id)[0];
        address b = arms.armsOf(id)[1];
        bytes32[] memory v = _vals("truth");
        vm.prank(poster);
        vm.expectRevert(Arms.NotOnJob.selector);
        arms.commit(id, a, bytes32(0));
        // Reveal before all committed is the wrong phase.
        _commit(id, a, v);
        vm.prank(a);
        vm.expectRevert(Arms.WrongPhase.selector);
        arms.reveal(id, a, v, _salt(a), "");
        vm.prank(a);
        vm.expectRevert(Arms.AlreadyCommitted.selector);
        arms.commit(id, a, bytes32(0));
        _commit(id, b, v);
        assertEq(uint8(_job(id).phase), uint8(Arms.Phase.REVEAL));
        // Wrong salt, wrong length, then a good reveal, then a repeat.
        vm.prank(a);
        vm.expectRevert(Arms.BadReveal.selector);
        arms.reveal(id, a, v, bytes32(0), "");
        bytes32[] memory short = new bytes32[](KEYS - 1);
        vm.prank(a);
        vm.expectRevert(Arms.BadReveal.selector);
        arms.reveal(id, a, short, _salt(a), "");
        _reveal(id, a, v);
        vm.prank(a);
        vm.expectRevert(Arms.AlreadyRevealed.selector);
        arms.reveal(id, a, v, _salt(a), "");
        vm.expectRevert(Arms.NotPending.selector);
        arms.settle(id);
        // Too late for b.
        vm.warp(vm.getBlockTimestamp() + 2 hours + 1);
        vm.prank(b);
        vm.expectRevert(Arms.TooLate.selector);
        arms.reveal(id, b, v, _salt(b), "");
    }

    function test_timeout_commitMissStrikesAndReplaces() public {
        uint256 id = _post();
        _fill(id);
        address a = arms.armsOf(id)[0];
        address b = arms.armsOf(id)[1];
        bytes32[] memory v = _vals("truth");
        _commit(id, a, v);
        vm.expectRevert(Arms.TooEarly.selector);
        arms.timeout(id);
        vm.warp(vm.getBlockTimestamp() + 6 hours + 1);
        arms.timeout(id);
        assertEq(_arm(b).strikes, 1);
        assertEq(_arm(b).locked, 0);
        assertEq(uint8(_job(id).phase), uint8(Arms.Phase.OPEN));
        assertEq(arms.armsOf(id).length, 1);
        _fill(id);
        address[] memory drawn = arms.armsOf(id);
        assertEq(drawn.length, 2);
        assertTrue(drawn[0] != b && drawn[1] != b, "struck arm is not redrawn");
        // a's commit stands; only the newcomer commits.
        address c = drawn[0] == a ? drawn[1] : drawn[0];
        _commit(id, c, v);
        assertEq(uint8(_job(id).phase), uint8(Arms.Phase.REVEAL));
        _reveal(id, a, v);
        _reveal(id, c, v);
        arms.settle(id);
        assertEq(uint8(_job(id).phase), uint8(Arms.Phase.SETTLED));
    }

    function test_timeout_revealMissAndDeactivation() public {
        address struck;
        for (uint256 round; round < 3; ++round) {
            uint256 id = _post();
            _fill(id);
            address[] memory drawn = arms.armsOf(id);
            if (struck == address(0)) struck = drawn[0];
            bytes32[] memory v = _vals("truth");
            bool onJob;
            for (uint256 i; i < drawn.length; ++i) {
                _commit(id, drawn[i], v);
                if (drawn[i] == struck) onJob = true;
            }
            if (!onJob) {
                // Not drawn this time: finish honestly and try again.
                for (uint256 i; i < drawn.length; ++i) {
                    _reveal(id, drawn[i], v);
                }
                arms.settle(id);
                if (round > 0) --round;
                else round = type(uint256).max; // wraps to 0 on ++round
                continue;
            }
            for (uint256 i; i < drawn.length; ++i) {
                if (drawn[i] != struck) _reveal(id, drawn[i], v);
            }
            vm.warp(vm.getBlockTimestamp() + 2 hours + 1);
            arms.timeout(id);
            assertEq(_arm(struck).strikes, uint32(round + 1));
        }
        Arms.ArmInfo memory s = _arm(struck);
        assertTrue(s.inactive, "three strikes deactivate");
        assertFalse(arms.isActive(struck));
        vm.prank(struck);
        vm.expectRevert(Arms.Cooldown.selector);
        arms.reactivate();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(struck);
        arms.reactivate();
        assertTrue(arms.isActive(struck));
        assertEq(_arm(struck).strikes, 0);
        vm.prank(struck);
        vm.expectRevert(Arms.NotInactive.selector);
        arms.reactivate();
    }

    function test_timeout_afterEveryoneRevealedIsNotATimeout() public {
        uint256 id = _post();
        _fill(id);
        _answerAll(id, _vals("truth"));
        vm.warp(vm.getBlockTimestamp() + 3 hours);
        vm.expectRevert(Arms.NotPending.selector);
        arms.timeout(id);
        arms.settle(id);
        assertEq(uint8(_job(id).phase), uint8(Arms.Phase.SETTLED));
        vm.expectRevert(Arms.WrongPhase.selector);
        arms.timeout(id);
    }

    function test_settle_agreedPaysBurnsReturns() public {
        uint256 id = _post();
        _fill(id);
        address[] memory drawn = arms.armsOf(id);
        bytes32[] memory v = _vals("truth");
        uint256[] memory before = new uint256[](drawn.length);
        for (uint256 i; i < drawn.length; ++i) {
            before[i] = token.balanceOf(drawn[i]);
        }
        uint256 posterBefore = token.balanceOf(poster);
        uint256 supply = token.totalSupply();
        _answerAll(id, v);
        arms.settle(id);
        for (uint256 i; i < drawn.length; ++i) {
            assertEq(token.balanceOf(drawn[i]) - before[i], FEE * 9000 / 10_000, "90% of a full fee");
        }
        assertEq(supply - token.totalSupply(), drawn.length * FEE / 10, "10% burned");
        assertEq(token.balanceOf(poster) - posterBefore, 3 * FEE - drawn.length * FEE, "rest returned");
        Arms.Verdict memory vd = arms.verdict(id);
        for (uint256 k; k < KEYS; ++k) {
            assertEq(uint8(vd.statuses[k]), uint8(Arms.Status.AGREED));
            assertEq(vd.values[k], v[k]);
        }
        assertEq(vd.challengeEnd, vm.getBlockTimestamp() + 7 days);
        assertEq(vd.atBlock, AT_BLOCK);
        assertEq(vd.arms.length, drawn.length);
        assertEq(vd.evidence[0], string.concat("ipfs://evidence/", vm.toString(drawn[0])));
        (uint256 latestId, Arms.Verdict memory lv) = arms.latest(CHAIN, target, formId);
        assertEq(latestId, id);
        assertEq(lv.values[0], v[0]);
        assertEq(arms.totalEscrow(), 0);
        assertEq(_job(id).spent, drawn.length * FEE);
    }

    function test_settle_unknownNeverPaidAndNotApplicableIsAnAnswer() public {
        uint256 id = _post();
        _fill(id);
        address[] memory drawn = arms.armsOf(id);
        vm.assume(drawn.length == 2);
        bytes32[] memory va = _vals("truth");
        va[0] = arms.NOT_APPLICABLE();
        bytes32[] memory vb = _vals("truth");
        vb[0] = arms.NOT_APPLICABLE();
        vb[1] = arms.UNKNOWN();
        _commit(id, drawn[0], va);
        _commit(id, drawn[1], vb);
        _reveal(id, drawn[0], va);
        _reveal(id, drawn[1], vb);
        uint256 b0 = token.balanceOf(drawn[0]);
        uint256 b1 = token.balanceOf(drawn[1]);
        arms.settle(id);
        Arms.Verdict memory vd = arms.verdict(id);
        assertEq(uint8(vd.statuses[0]), uint8(Arms.Status.AGREED), "NOT_APPLICABLE agreed");
        assertEq(uint8(vd.statuses[1]), uint8(Arms.Status.UNRESOLVED), "one answer plus UNKNOWN");
        assertEq(uint8(vd.statuses[2]), uint8(Arms.Status.AGREED));
        // a: keys 0, 2, 3 are final and equal -> 3/4; b: 3/4 too (UNKNOWN on key 1 is simply unpaid).
        assertEq(token.balanceOf(drawn[0]) - b0, FEE * 3 / 4 * 9 / 10);
        assertEq(token.balanceOf(drawn[1]) - b1, FEE * 3 / 4 * 9 / 10);
        // An UNRESOLVED key cannot be challenged.
        vm.prank(challenger);
        vm.expectRevert(Arms.NotChallengeable.selector);
        arms.challenge(id, 1, bytes32(uint256(1)), COURT_FEE);
    }

    function test_settle_disputeGoesToTieBreakAndMajority() public {
        uint256 id = _post();
        _fill(id);
        address[] memory drawn = arms.armsOf(id);
        vm.assume(drawn.length == 2);
        bytes32[] memory va = _vals("truth");
        bytes32[] memory vb = _vals("truth");
        vb[2] = keccak256("b says otherwise");
        _commit(id, drawn[0], va);
        _commit(id, drawn[1], vb);
        _reveal(id, drawn[0], va);
        _reveal(id, drawn[1], vb);
        arms.settle(id);
        Arms.Job memory j = _job(id);
        assertEq(uint8(j.phase), uint8(Arms.Phase.TIE_OPEN));
        assertEq(j.disputedMask, 1 << 2);
        assertEq(j.disputedCount, 1);
        assertEq(arms.totalEscrow(), 3 * FEE, "nothing paid yet");
        _fillTie(id);
        address tb = _job(id).tieBreaker;
        assertTrue(tb != drawn[0] && tb != drawn[1] && tb != poster);
        bytes32[] memory tv = new bytes32[](1);
        tv[0] = va[2];
        // Wrong length is refused; then commit and reveal only the disputed key.
        vm.prank(tb);
        arms.commit(id, tb, keccak256(abi.encode(id, tb, tv, _salt(tb))));
        assertEq(uint8(_job(id).phase), uint8(Arms.Phase.TIE_REVEAL));
        bytes32[] memory wrongLen = new bytes32[](2);
        vm.prank(tb);
        vm.expectRevert(Arms.BadReveal.selector);
        arms.reveal(id, tb, wrongLen, _salt(tb), "");
        uint256 tbBefore = token.balanceOf(tb);
        uint256 aBefore = token.balanceOf(drawn[0]);
        uint256 bBefore = token.balanceOf(drawn[1]);
        _reveal(id, tb, tv);
        arms.settle(id);
        Arms.Verdict memory vd = arms.verdict(id);
        assertEq(uint8(vd.statuses[2]), uint8(Arms.Status.MAJORITY));
        assertEq(vd.values[2], va[2]);
        assertEq(uint8(vd.statuses[0]), uint8(Arms.Status.AGREED));
        assertEq(token.balanceOf(tb) - tbBefore, FEE * 9 / 10, "tie breaker got the disputed key right");
        assertEq(token.balanceOf(drawn[0]) - aBefore, FEE * 9 / 10, "a: 4/4");
        assertEq(token.balanceOf(drawn[1]) - bBefore, FEE * 3 / 4 * 9 / 10, "b: 3/4");
        assertEq(vd.tieBreaker, tb);
    }

    function test_settle_unavailableTieBreakLeavesDisputedKeysUnresolved() public {
        for (uint256 i = 2; i < 6; ++i) {
            vm.prank(armSet[i]);
            arms.stopServing(formId);
        }
        uint256 id = _post();
        _fill(id);
        address[] memory drawn = arms.armsOf(id);
        assertEq(drawn.length, 2);
        bytes32[] memory va = _vals("truth");
        bytes32[] memory vb = _vals("other");
        _commit(id, drawn[0], va);
        _commit(id, drawn[1], vb);
        _reveal(id, drawn[0], va);
        _reveal(id, drawn[1], vb);
        arms.settle(id);
        assertEq(_job(id).disputedCount, KEYS);
        vm.roll(vm.getBlockNumber() + 2);
        arms.draw(id);
        assertEq(uint8(_job(id).phase), uint8(Arms.Phase.TIE_OPEN));
        vm.expectRevert(Arms.TooEarly.selector);
        arms.settle(id);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        uint256 before = token.balanceOf(poster);
        arms.settle(id);
        for (uint256 k; k < KEYS; ++k) {
            assertEq(uint8(arms.verdict(id).statuses[k]), uint8(Arms.Status.UNRESOLVED));
        }
        assertEq(token.balanceOf(poster) - before, 3 * FEE);
        for (uint256 i; i < drawn.length; ++i) {
            assertEq(_arm(drawn[i]).strikes, 0);
        }
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        arms.release(id);
        for (uint256 i; i < drawn.length; ++i) {
            assertEq(_arm(drawn[i]).locked, 0);
        }
    }

    function test_spotCheck_threeArmsMajorityWithoutTieBreak() public {
        uint256 id = _postSpot();
        address[] memory drawn = arms.armsOf(id);
        assertEq(drawn.length, 3);
        bytes32[] memory v = _vals("truth");
        bytes32[] memory vOdd = _vals("truth");
        vOdd[1] = keccak256("odd one out");
        _commit(id, drawn[0], v);
        _commit(id, drawn[1], v);
        _commit(id, drawn[2], vOdd);
        _reveal(id, drawn[0], v);
        _reveal(id, drawn[1], v);
        _reveal(id, drawn[2], vOdd);
        uint256 posterBefore = token.balanceOf(poster);
        arms.settle(id);
        Arms.Verdict memory vd = arms.verdict(id);
        assertEq(uint8(vd.statuses[1]), uint8(Arms.Status.MAJORITY));
        assertEq(uint8(vd.statuses[0]), uint8(Arms.Status.AGREED));
        assertEq(uint8(_job(id).phase), uint8(Arms.Phase.SETTLED));
        // 1 + 1 + 3/4 fees paid; the rest of 3 fees returns.
        assertEq(token.balanceOf(poster) - posterBefore, 3 * FEE - (2 * FEE + FEE * 3 / 4));
    }

    // ------------------------------------------------------------------ challenges

    function test_challenge_rules() public {
        uint256 id = _post();
        vm.prank(challenger);
        vm.expectRevert(Arms.WrongPhase.selector);
        arms.challenge(id, 0, bytes32(uint256(1)), COURT_FEE);
        (uint256 sid, bytes32[] memory v) = _settledJob();
        vm.startPrank(challenger);
        vm.expectRevert(Arms.BadLength.selector);
        arms.challenge(sid, KEYS, bytes32(uint256(1)), COURT_FEE);
        vm.expectRevert(Arms.SameValue.selector);
        arms.challenge(sid, 0, v[0], COURT_FEE);
        bytes32 unknown = arms.UNKNOWN();
        vm.expectRevert(Arms.SameValue.selector);
        arms.challenge(sid, 0, unknown, COURT_FEE);
        vm.expectRevert(Arms.CourtFee.selector);
        arms.challenge(sid, 0, bytes32(uint256(1)), COURT_FEE - 1);
        uint256 before = token.balanceOf(challenger);
        bytes32 caseId = arms.challenge(sid, 0, bytes32(uint256(1)), COURT_FEE);
        assertEq(before - token.balanceOf(challenger), STAKE + COURT_FEE, "stake and court fee pulled");
        assertEq(token.balanceOf(address(court)), COURT_FEE);
        assertEq(arms.totalStakes(), STAKE);
        vm.expectRevert(Arms.ChallengeExists.selector);
        arms.challenge(sid, 0, bytes32(uint256(1)), COURT_FEE);
        // A second challenge on the same key with another value is allowed.
        arms.challenge(sid, 0, bytes32(uint256(2)), COURT_FEE);
        assertEq(_job(sid).openChallenges, 2);
        vm.expectRevert(Arms.CourtPending.selector);
        arms.resolve(sid, 0, bytes32(uint256(1)));
        vm.stopPrank();
        MockCourt.Case memory c = court.caseOf(address(arms), caseId);
        assertEq(c.key, 0);
        assertEq(c.storedValue, v[0]);
        assertEq(c.payer, challenger);
        assertEq(c.formId, formId);
        // Window closes.
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        vm.prank(challenger);
        vm.expectRevert(Arms.TooLate.selector);
        arms.challenge(sid, 1, bytes32(uint256(1)), COURT_FEE);
    }

    function test_resolve_claimedCorrectsSlashesRefundsRewards() public {
        (uint256 id, bytes32[] memory v) = _settledJob();
        address[] memory drawn = arms.armsOf(id);
        bytes32 claimed = keccak256("the truth");
        bytes32 caseId = _challenge(id, 1, claimed);
        _rule(caseId, ICourt.Ruling.CLAIMED);
        uint256 posterBefore = token.balanceOf(poster);
        uint256 chBefore = token.balanceOf(challenger);
        uint256 supply = token.totalSupply();
        uint256 spent = _job(id).spent;
        arms.resolve(id, 1, claimed);
        Arms.Verdict memory vd = arms.verdict(id);
        assertEq(uint8(vd.statuses[1]), uint8(Arms.Status.CORRECTED));
        assertEq(vd.values[1], claimed);
        assertTrue(vd.overturned);
        uint256 slashed = drawn.length * TRANCHE;
        for (uint256 i; i < drawn.length; ++i) {
            assertEq(_arm(drawn[i]).bond, ARM_BOND - TRANCHE);
            assertEq(_arm(drawn[i]).locked, 0);
            assertTrue(arms.slashedIn(id, drawn[i]));
        }
        assertEq(token.balanceOf(poster) - posterBefore, spent, "poster refunded the job's cost");
        uint256 rest = slashed - spent;
        uint256 reward = rest * 3000 / 10_000;
        assertEq(token.balanceOf(challenger) - chBefore, STAKE + reward, "stake back plus reward");
        assertEq(supply - token.totalSupply(), rest - reward, "remainder burned");
        assertEq(arms.totalRewards(), 0);
        assertEq(arms.totalStakes(), 0);
        vm.expectRevert(Arms.AlreadyResolved.selector);
        arms.resolve(id, 1, claimed);
        // A corrected key cannot be challenged again.
        vm.prank(challenger);
        vm.expectRevert(Arms.NotChallengeable.selector);
        arms.challenge(id, 1, v[1], COURT_FEE);
        // Release after the window.
        vm.expectRevert(Arms.StillLocked.selector);
        arms.release(id);
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        arms.release(id);
        vm.expectRevert(Arms.AlreadyReleased.selector);
        arms.release(id);
    }

    function test_resolve_neitherOverturnsHoldsRewardThenBurnsIt() public {
        (uint256 id,) = _settledJob();
        bytes32 claimed = keccak256("wrong too");
        bytes32 caseId = _challenge(id, 0, claimed);
        _rule(caseId, ICourt.Ruling.NEITHER);
        uint256 chBefore = token.balanceOf(challenger);
        arms.resolve(id, 0, claimed);
        assertEq(uint8(arms.verdict(id).statuses[0]), uint8(Arms.Status.OVERTURNED));
        assertEq(token.balanceOf(challenger) - chBefore, STAKE, "stake back, no reward on NEITHER");
        uint256 reward = _job(id).reward;
        assertGt(reward, 0);
        assertEq(arms.totalRewards(), reward);
        // The reward waits for a CLAIMED ruling within the window; none comes, release burns it.
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        uint256 supply = token.totalSupply();
        arms.release(id);
        assertEq(supply - token.totalSupply(), reward);
        assertEq(arms.totalRewards(), 0);
    }

    function test_resolve_secondSlashBurnsAndArmsLoseOneTrancheOnly() public {
        (uint256 id,) = _settledJob();
        address[] memory drawn = arms.armsOf(id);
        bytes32 c1 = _challenge(id, 0, keccak256("k0"));
        bytes32 c2 = _challenge(id, 2, keccak256("k2"));
        _rule(c1, ICourt.Ruling.NEITHER);
        _rule(c2, ICourt.Ruling.CLAIMED);
        arms.resolve(id, 0, keccak256("k0"));
        uint256 reward = _job(id).reward;
        uint256 supply = token.totalSupply();
        uint256 posterBefore = token.balanceOf(poster);
        uint256 chBefore = token.balanceOf(challenger);
        arms.resolve(id, 2, keccak256("k2"));
        // Same arms already slashed for this job: nothing more is taken, nothing more is burned.
        for (uint256 i; i < drawn.length; ++i) {
            assertEq(_arm(drawn[i]).bond, ARM_BOND - TRANCHE, "one tranche per job");
        }
        assertEq(token.balanceOf(poster), posterBefore, "poster refunded once");
        assertEq(token.balanceOf(challenger) - chBefore, STAKE + reward, "the first CLAIMED gets the reward");
        assertEq(supply, token.totalSupply());
        assertEq(uint8(arms.verdict(id).statuses[2]), uint8(Arms.Status.CORRECTED));
    }

    function test_resolve_storedSplitsStakeAmongArms() public {
        (uint256 id,) = _settledJob();
        address[] memory drawn = arms.armsOf(id);
        bytes32 claimed = keccak256("nope");
        bytes32 caseId = _challenge(id, 3, claimed);
        _rule(caseId, ICourt.Ruling.STORED);
        uint256[] memory before = new uint256[](drawn.length);
        for (uint256 i; i < drawn.length; ++i) {
            before[i] = token.balanceOf(drawn[i]);
        }
        uint256 chBefore = token.balanceOf(challenger);
        arms.resolve(id, 3, claimed);
        for (uint256 i; i < drawn.length; ++i) {
            assertEq(token.balanceOf(drawn[i]) - before[i], STAKE / drawn.length);
        }
        assertEq(token.balanceOf(challenger), chBefore, "stake lost");
        assertEq(uint8(arms.verdict(id).statuses[3]), uint8(Arms.Status.AGREED));
        assertFalse(arms.verdict(id).overturned);
        assertEq(arms.totalStakes(), 0);
    }

    /// @dev A STORED ruling forfeits the stake whatever happened on other keys. Here both arms were
    /// slashed on key 0, so no unslashed giver of key 1 remains and the stake burns.
    function test_resolve_storedAfterOverturnBurnsStakeWhenEveryGiverWasSlashed() public {
        (uint256 id,) = _settledJob();
        bytes32 c1 = _challenge(id, 0, keccak256("k0"));
        bytes32 c2 = _challenge(id, 1, keccak256("k1"));
        _rule(c1, ICourt.Ruling.CLAIMED);
        _rule(c2, ICourt.Ruling.STORED);
        arms.resolve(id, 0, keccak256("k0"));
        uint256 chBefore = token.balanceOf(challenger);
        uint256 supplyBefore = token.totalSupply();
        arms.resolve(id, 1, keccak256("k1"));
        assertEq(token.balanceOf(challenger), chBefore, "a challenger ruled wrong keeps no stake");
        assertEq(supplyBefore - token.totalSupply(), STAKE, "with no unslashed giver the stake burns");
        assertEq(arms.totalStakes(), 0);
    }

    function test_resolve_noRulingAfterCourtDeadline() public {
        (uint256 id,) = _settledJob();
        bytes32 claimed = keccak256("k0");
        _challenge(id, 0, claimed);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.expectRevert(Arms.CourtPending.selector);
        arms.resolve(id, 0, claimed);
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 chBefore = token.balanceOf(challenger);
        arms.resolve(id, 0, claimed);
        assertEq(token.balanceOf(challenger) - chBefore, STAKE);
        assertEq(uint8(arms.verdict(id).statuses[0]), uint8(Arms.Status.AGREED), "unchanged");
        assertEq(_job(id).openChallenges, 0);
        // The window has closed and nothing is open: release unlocks.
        arms.release(id);
        address[] memory drawn = arms.armsOf(id);
        assertEq(_arm(drawn[0]).locked, 0);
        vm.expectRevert(Arms.UnknownChallenge.selector);
        arms.resolve(id, 0, keccak256("never opened"));
    }

    function test_tieBreakerIsSlashedWhenItGaveTheStoredValue() public {
        uint256 id = _post();
        _fill(id);
        address[] memory drawn = arms.armsOf(id);
        vm.assume(drawn.length == 2);
        bytes32[] memory va = _vals("truth");
        bytes32[] memory vb = _vals("truth");
        vb[0] = keccak256("b");
        _commit(id, drawn[0], va);
        _commit(id, drawn[1], vb);
        _reveal(id, drawn[0], va);
        _reveal(id, drawn[1], vb);
        arms.settle(id);
        _fillTie(id);
        address tb = _job(id).tieBreaker;
        bytes32[] memory tv = new bytes32[](1);
        tv[0] = vb[0];
        _commit(id, tb, tv);
        _reveal(id, tb, tv);
        arms.settle(id);
        assertEq(arms.verdict(id).values[0], vb[0]);
        bytes32 caseId = _challenge(id, 0, va[0]);
        _rule(caseId, ICourt.Ruling.CLAIMED);
        arms.resolve(id, 0, va[0]);
        assertTrue(arms.slashedIn(id, tb), "tie breaker slashed");
        assertTrue(arms.slashedIn(id, drawn[1]));
        assertFalse(arms.slashedIn(id, drawn[0]), "the arm that was right keeps its tranche");
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        arms.release(id);
        assertEq(_arm(drawn[0]).locked, 0);
        assertEq(_arm(tb).locked, 0);
    }

    // ------------------------------------------------------------------ no admin

    function test_noOwnerAdminPauseOrUpgrade() public {
        string[12] memory sigs = [
            "owner()",
            "pause()",
            "unpause()",
            "paused()",
            "transferOwnership(address)",
            "renounceOwnership()",
            "upgradeTo(address)",
            "upgradeToAndCall(address,bytes)",
            "initialize()",
            "setParams(uint256)",
            "admin()",
            "proxiableUUID()"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            (bool ok,) = address(arms).call(abi.encodeWithSignature(sigs[i]));
            assertFalse(ok, sigs[i]);
            (ok,) = address(arms).staticcall(abi.encodeWithSignature(sigs[i]));
            assertFalse(ok, sigs[i]);
        }
        (bool ethOk,) = address(arms).call{value: 0}("");
        assertFalse(ethOk, "no fallback");
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_bondWithdrawRoundTrip(uint96 amount, uint32 wait) public {
        amount = uint96(bound(amount, 1, 1000 ether));
        address a = makeAddr("fuzzArm");
        _fund(a, amount);
        vm.startPrank(a);
        arms.bond(amount);
        arms.requestExit();
        vm.warp(vm.getBlockTimestamp() + bound(wait, 14 days, 365 days));
        arms.withdraw();
        vm.stopPrank();
        assertEq(token.balanceOf(a), amount);
        assertEq(arms.totalBonded(), 6 * ARM_BOND);
    }

    function testFuzz_commitHashBindsJobArmValuesSalt(bytes32 salt, bytes32 tweak) public {
        uint256 id = _post();
        _fill(id);
        address a = arms.armsOf(id)[0];
        bytes32[] memory v = _vals(tweak);
        vm.prank(a);
        arms.commit(id, a, keccak256(abi.encode(id, a, v, salt)));
        address b = arms.armsOf(id)[1];
        _commit(id, b, v);
        if (_job(id).phase != Arms.Phase.REVEAL) return;
        bytes32[] memory other = _vals(~tweak);
        vm.prank(a);
        vm.expectRevert(Arms.BadReveal.selector);
        arms.reveal(id, a, other, salt, "");
        vm.prank(a);
        arms.reveal(id, a, v, salt, "");
    }

    function testFuzz_settlePaymentsNeverExceedEscrow(bytes32 sa, bytes32 sb, uint8 agreeMask) public {
        uint256 id = _post();
        _fill(id);
        address[] memory drawn = arms.armsOf(id);
        bytes32[] memory va = _vals(sa);
        bytes32[] memory vb = _vals(sb);
        for (uint256 k; k < KEYS; ++k) {
            if (agreeMask & (1 << k) != 0) vb[k] = va[k];
        }
        uint256 posterBefore = token.balanceOf(poster);
        uint256 balanceBefore = token.balanceOf(address(arms));
        for (uint256 i; i < drawn.length; ++i) {
            _commit(id, drawn[i], i == 1 ? vb : va);
        }
        for (uint256 i; i < drawn.length; ++i) {
            _reveal(id, drawn[i], i == 1 ? vb : va);
        }
        arms.settle(id);
        if (_job(id).phase == Arms.Phase.TIE_OPEN) {
            vm.warp(vm.getBlockTimestamp() + 1 days + 1);
            arms.settle(id);
        }
        assertEq(uint8(_job(id).phase), uint8(Arms.Phase.SETTLED));
        assertEq(balanceBefore - token.balanceOf(address(arms)), 3 * FEE, "the whole escrow left");
        assertLe(token.balanceOf(poster) - posterBefore, 3 * FEE);
        assertEq(token.balanceOf(address(arms)), arms.totalBonded() + arms.totalEscrow());
    }
}
