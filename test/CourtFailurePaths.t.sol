// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Arms} from "../src/Arms.sol";
import {ICourt} from "../src/ICourt.sol";
import {IIntake} from "../src/IIntake.sol";
import {IMDCourt} from "../src/IMDCourt.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {MockToken} from "../src/mocks/MockToken.sol";
import {MockIntake} from "./mocks/MockIntake.sol";
import {ArmsBase} from "./ArmsBase.t.sol";

/// @dev Failure paths of Arms wired to the production IMDCourt, Sepolia-shaped: bonds in one token,
/// the oracle fee in a second one (as ARMT and imdTEST), a mock Intake and a throwaway signing key.
/// None of this is a live Sepolia ruling.
contract CourtFailurePathsTest is ArmsBase {
    bytes32 constant ACTION = 0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000;
    uint256 constant PRICE = 0.5 ether;
    uint256 constant SIGNER_KEY = 0xB0B5;
    address constant WRITER = address(0x717E);

    MockToken feeToken;
    MockIntake intake;
    IMDCourt imdCourt;
    address treasury = makeAddr("treasury");

    function setUp() public override {
        super.setUp();
        feeToken = new MockToken(tokenOwner);
        intake = new MockIntake(WRITER, treasury, ACTION, address(feeToken), PRICE);
        imdCourt =
            new IMDCourt(tokenOwner, IIntake(address(intake)), IERC20(address(feeToken)), ACTION, vm.addr(SIGNER_KEY));
        arms = _wire(imdCourt);
        vm.prank(tokenOwner);
        feeToken.transfer(challenger, 100 ether);
        vm.startPrank(challenger);
        token.approve(address(arms), type(uint256).max);
        feeToken.approve(address(arms), type(uint256).max);
        vm.stopPrank();
        vm.prank(poster);
        token.approve(address(arms), type(uint256).max);
    }

    /// @dev A new Arms on `court_` with the Sepolia parameters, the standard form and six bonded arms.
    function _wire(IMDCourt court_) internal returns (Arms a) {
        a = _deploy(sepoliaParams(address(token), address(court_)));
        formId = a.registerForm(
            keccak256("Arms form v1: four questions about a target contract"),
            KEYS,
            "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/form.md"
        );
        for (uint256 i; i < armSet.length; ++i) {
            vm.startPrank(armSet[i]);
            token.approve(address(a), type(uint256).max);
            a.bond(100 ether);
            a.serve(formId, FEE);
            vm.stopPrank();
        }
    }

    function _attest(bytes32 questionHash, uint256 answer, bytes32 uuid)
        internal
        view
        returns (OracleAttestation.Attestation memory a, bytes memory sig)
    {
        a = OracleAttestation.Attestation({
            requestId: uuid,
            chainId: CHAIN,
            questionHash: questionHash,
            answerType: OracleAttestation.ANSWER_UINT256,
            answer: abi.encode(answer),
            figure: 0,
            fromBlock: uint64(AT_BLOCK),
            toBlock: uint64(AT_BLOCK),
            blockHash: keccak256("block"),
            panelJobId: keccak256("panel"),
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: uint64(vm.getBlockTimestamp()),
            expiresAt: uint64(vm.getBlockTimestamp() + 1 days)
        });
        sig = _sign(a);
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, imdCourt.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _answer(bytes32 caseId, uint256 answer) internal returns (bool ok) {
        IMDCourt.Case memory c = imdCourt.caseOf(address(arms), caseId);
        (OracleAttestation.Attestation memory a, bytes memory sig) =
            _attest(c.questionHash, answer, keccak256(abi.encode("uuid", caseId, answer)));
        vm.prank(WRITER);
        ok = intake.complete(c.requestId, a, sig);
    }

    function _owed() internal view returns (uint256) {
        return arms.totalBonded() + arms.totalEscrow() + arms.totalStakes() + arms.totalRewards();
    }

    function _challengePrice(uint256 id, uint8 key, bytes32 claimed) internal returns (bytes32 caseId) {
        vm.prank(challenger);
        caseId = arms.challenge(id, key, claimed, PRICE);
    }

    // ------------------------------------------------------------------ challenge is all or nothing

    function test_challengeRevertsWholeWhenOracleNoLongerSold() public {
        (uint256 id,) = _settledJob();
        intake.setPrice(ACTION, address(feeToken), 0);
        uint256 tokenBefore = token.balanceOf(challenger);
        uint256 feeBefore = feeToken.balanceOf(challenger);
        vm.prank(challenger);
        vm.expectRevert(IMDCourt.ActionNotSold.selector);
        arms.challenge(id, 0, keccak256("claim"), PRICE);
        assertEq(token.balanceOf(challenger), tokenBefore, "stake not taken");
        assertEq(feeToken.balanceOf(challenger), feeBefore, "fee not taken");
        assertEq(arms.totalStakes(), 0);
        assertFalse(_challengeOf(arms.caseIdOf(id, 0, keccak256("claim"))).exists);
        assertEq(_job(id).openChallenges, 0);
    }

    function test_challengeRevertsWholeWithoutFeeAssetApproval() public {
        (uint256 id,) = _settledJob();
        vm.prank(challenger);
        feeToken.approve(address(arms), 0);
        uint256 tokenBefore = token.balanceOf(challenger);
        vm.prank(challenger);
        vm.expectRevert();
        arms.challenge(id, 1, keccak256("claim"), PRICE);
        assertEq(token.balanceOf(challenger), tokenBefore, "stake not taken");
        assertEq(arms.totalStakes(), 0);
        assertEq(feeToken.balanceOf(treasury), 0);
    }

    function test_challengeRevertsWholeWhenOraclePriceRisesAboveMax() public {
        (uint256 id,) = _settledJob();
        intake.setPrice(ACTION, address(feeToken), PRICE + 1);
        vm.prank(challenger);
        vm.expectRevert(Arms.CourtFee.selector);
        arms.challenge(id, 1, keccak256("claim"), PRICE);
        assertEq(arms.totalStakes(), 0);
        assertEq(feeToken.balanceOf(treasury), 0);
        // With the higher price accepted it goes through, and exactly that price is forwarded.
        vm.prank(challenger);
        arms.challenge(id, 1, keccak256("claim"), PRICE + 1);
        assertEq(feeToken.balanceOf(treasury), PRICE + 1);
        assertEq(feeToken.balanceOf(address(arms)), 0);
        assertEq(feeToken.allowance(address(arms), address(imdCourt)), 0);
    }

    function test_unsupportedTargetChainsRefusedByArmsAndCourt() public {
        uint256[3] memory chains = [uint256(1), 8453, 0];
        for (uint256 i; i < 3; ++i) {
            vm.prank(poster);
            vm.expectRevert(Arms.ChainNotAllowed.selector);
            arms.post(formId, chains[i], target, AT_BLOCK, FEE);
        }
        vm.startPrank(challenger);
        feeToken.approve(address(imdCourt), PRICE);
        vm.expectRevert(IMDCourt.ChainNotSupported.selector);
        imdCourt.ask(keccak256("c"), formId, "ipfs://f", 0, 1, target, AT_BLOCK, 0, bytes32("x"), challenger, PRICE);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ late and odd answers

    /// A ruling that lands after the challenge was already closed at `courtDeadline` is stored by the
    /// court but moves nothing in Arms: no slash, no reward, no second stake refund.
    function test_lateRulingAfterDeadlineCloseMovesNothing() public {
        (uint256 id, bytes32[] memory v) = _settledJob();
        bytes32 claimed = keccak256("late truth");
        bytes32 caseId = _challengePrice(id, 2, claimed);
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        uint256 before = token.balanceOf(challenger);
        arms.resolve(id, 2, claimed);
        assertEq(token.balanceOf(challenger) - before, STAKE, "stake back on no ruling");
        uint256 bonded = arms.totalBonded();
        uint256 supply = token.totalSupply();
        assertTrue(_answer(caseId, 2), "court still accepts its own open case");
        assertEq(uint8(imdCourt.rulingOf(address(arms), caseId)), uint8(ICourt.Ruling.CLAIMED));
        vm.expectRevert(Arms.AlreadyResolved.selector);
        arms.resolve(id, 2, claimed);
        assertEq(uint8(_challengeOf(caseId).ruling), uint8(ICourt.Ruling.NONE));
        assertEq(arms.totalBonded(), bonded, "no slash after close");
        assertEq(token.totalSupply(), supply, "no burn after close");
        (bytes32 stored, Arms.Status status) = arms.results(id, 2);
        assertEq(stored, v[2]);
        assertEq(uint8(status), uint8(Arms.Status.AGREED));
        assertEq(token.balanceOf(address(arms)), _owed());
    }

    /// A ruling that lands after `courtDeadline` but before anyone resolved is still applied.
    function test_rulingAfterDeadlineButBeforeResolveIsApplied() public {
        (uint256 id,) = _settledJob();
        bytes32 claimed = keccak256("slow truth");
        bytes32 caseId = _challengePrice(id, 0, claimed);
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        assertTrue(_answer(caseId, 2));
        uint256 bonded = arms.totalBonded();
        arms.resolve(id, 0, claimed);
        assertEq(bonded - arms.totalBonded(), 2 * TRANCHE, "both agreeing arms slashed");
        (bytes32 stored, Arms.Status status) = arms.results(id, 0);
        assertEq(stored, claimed);
        assertEq(uint8(status), uint8(Arms.Status.CORRECTED));
        // The challenge window closed long ago and nothing else is open: no reward is held back.
        assertEq(arms.totalRewards(), 0);
        assertEq(token.balanceOf(address(arms)), _owed());
    }

    /// A signed answer outside 0..2 closes the court case with no ruling. Arms then waits for
    /// `courtDeadline`, the price is spent, a correct later answer is refused, and the same claim
    /// cannot be asked again.
    function test_outOfRangeAnswerClosesCaseAndOnlyTheDeadlineEndsIt() public {
        (uint256 id,) = _settledJob();
        bytes32 claimed = keccak256("odd");
        bytes32 caseId = _challengePrice(id, 1, claimed);
        assertTrue(_answer(caseId, 3));
        assertFalse(imdCourt.caseOf(address(arms), caseId).open);
        assertEq(uint8(imdCourt.rulingOf(address(arms), caseId)), uint8(ICourt.Ruling.NONE));
        assertFalse(_answer(caseId, 2), "no second answer for a closed case");
        vm.expectRevert(Arms.CourtPending.selector);
        arms.resolve(id, 1, claimed);
        vm.prank(challenger);
        vm.expectRevert(Arms.ChallengeExists.selector);
        arms.challenge(id, 1, claimed, PRICE);
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        uint256 before = token.balanceOf(challenger);
        arms.resolve(id, 1, claimed);
        assertEq(token.balanceOf(challenger) - before, STAKE);
        assertEq(feeToken.balanceOf(treasury), PRICE, "oracle price is never refunded");
    }

    function test_wrongAnswerTypeOrFutureIssuedAttestationLeavesCaseOpen() public {
        (uint256 id,) = _settledJob();
        bytes32 claimed = keccak256("types");
        bytes32 caseId = _challengePrice(id, 3, claimed);
        IMDCourt.Case memory c = imdCourt.caseOf(address(arms), caseId);

        (OracleAttestation.Attestation memory a,) = _attest(c.questionHash, 2, keccak256("bool"));
        a.answerType = OracleAttestation.ANSWER_BOOL;
        bytes memory sig = _sign(a);
        vm.prank(address(intake));
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleAttestationConsumer.WrongAnswerType.selector,
                OracleAttestation.ANSWER_UINT256,
                OracleAttestation.ANSWER_BOOL
            )
        );
        imdCourt.onOracleResult(c.requestId, a, sig);

        (a,) = _attest(c.questionHash, 2, keccak256("future"));
        a.issuedAt = uint64(vm.getBlockTimestamp() + 5 minutes + 1);
        sig = _sign(a);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationNotYetValid.selector, a.issuedAt));
        imdCourt.onOracleResult(c.requestId, a, sig);

        // Exactly at the tolerance it is accepted.
        a.issuedAt = uint64(vm.getBlockTimestamp() + 5 minutes);
        sig = _sign(a);
        vm.prank(address(intake));
        imdCourt.onOracleResult(c.requestId, a, sig);
        assertEq(uint8(imdCourt.rulingOf(address(arms), caseId)), uint8(ICourt.Ruling.CLAIMED));
    }

    /// A quorum larger than asked, but with `agreed` below it, is refused even though agreed >= 4.
    function test_panelThatRaisedItsOwnQuorumMustReachIt() public {
        (uint256 id,) = _settledJob();
        bytes32 caseId = _challengePrice(id, 0, keccak256("q"));
        IMDCourt.Case memory c = imdCourt.caseOf(address(arms), caseId);
        (OracleAttestation.Attestation memory a,) = _attest(c.questionHash, 2, keccak256("quorum"));
        a.panelSize = 9;
        a.quorum = 7;
        a.agreed = 6;
        bytes memory sig = _sign(a);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(IMDCourt.PanelTooWeak.selector, uint16(9), uint16(7), uint16(6)));
        imdCourt.onOracleResult(c.requestId, a, sig);
        a.quorum = 3;
        a.agreed = 9;
        sig = _sign(a);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(IMDCourt.PanelTooWeak.selector, uint16(9), uint16(3), uint16(9)));
        imdCourt.onOracleResult(c.requestId, a, sig);
    }

    // ------------------------------------------------------------------ two askers, one court

    /// Two Arms instances share one court and ask byte-identical questions (same form id, job id,
    /// key, claim, target and block). Cases stay apart, and one signed attestation settles one only.
    function test_twoAskersWithIdenticalQuestionsCannotCrossSettle() public {
        Arms first = arms;
        (uint256 id,) = _settledJob();
        bytes32 claimed = keccak256("shared");
        bytes32 caseA = _challengePrice(id, 0, claimed);

        Arms second = _wire(imdCourt);
        arms = second;
        vm.startPrank(challenger);
        token.approve(address(second), type(uint256).max);
        feeToken.approve(address(second), type(uint256).max);
        vm.stopPrank();
        vm.prank(poster);
        token.approve(address(second), type(uint256).max);
        (uint256 id2,) = _settledJob();
        assertEq(id2, id, "same job id in both instances");
        bytes32 caseB = _challengePrice(id2, 0, claimed);
        assertEq(caseA, caseB, "same case id in both instances");

        IMDCourt.Case memory a = imdCourt.caseOf(address(first), caseA);
        IMDCourt.Case memory b = imdCourt.caseOf(address(second), caseB);
        assertEq(a.questionHash, b.questionHash, "identical questions");
        assertTrue(a.requestId != b.requestId);

        (OracleAttestation.Attestation memory att, bytes memory sig) = _attest(a.questionHash, 2, keccak256("one"));
        vm.prank(WRITER);
        assertTrue(intake.complete(a.requestId, att, sig));
        assertEq(uint8(imdCourt.rulingOf(address(first), caseA)), uint8(ICourt.Ruling.CLAIMED));
        assertEq(uint8(imdCourt.rulingOf(address(second), caseB)), uint8(ICourt.Ruling.NONE));
        // The same attestation re-presented for the other request is refused as consumed.
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AlreadyConsumed.selector, att.requestId));
        imdCourt.onOracleResult(b.requestId, att, sig);
        // Arms instances read only their own namespace.
        vm.prank(address(second));
        assertEq(uint8(imdCourt.ruling(caseB)), uint8(ICourt.Ruling.NONE));
        vm.expectRevert(Arms.CourtPending.selector);
        second.resolve(id2, 0, claimed);
        first.resolve(id, 0, claimed);
    }

    /// A stranger asking the court directly with Arms' future case id occupies only its own namespace.
    function test_strangerCannotPreoccupyArmsCaseOrRuleIt() public {
        (uint256 id,) = _settledJob();
        bytes32 claimed = keccak256("front-run");
        bytes32 caseId = arms.caseIdOf(id, 0, claimed);
        address stranger = makeAddr("stranger");
        vm.prank(tokenOwner);
        feeToken.transfer(stranger, PRICE);
        vm.startPrank(stranger);
        feeToken.approve(address(imdCourt), PRICE);
        imdCourt.ask(caseId, formId, "ipfs://f", 0, CHAIN, target, AT_BLOCK, 0, claimed, stranger, PRICE);
        vm.stopPrank();
        IMDCourt.Case memory s = imdCourt.caseOf(stranger, caseId);
        (OracleAttestation.Attestation memory att, bytes memory sig) = _attest(s.questionHash, 2, keccak256("s"));
        vm.prank(WRITER);
        assertTrue(intake.complete(s.requestId, att, sig));
        // Arms' own case still opens, and the stranger's CLAIMED ruling is not Arms' ruling.
        _challengePrice(id, 0, claimed);
        assertEq(uint8(imdCourt.rulingOf(address(arms), caseId)), uint8(ICourt.Ruling.NONE));
        vm.expectRevert(Arms.CourtPending.selector);
        arms.resolve(id, 0, claimed);
    }

    // ------------------------------------------------------------------ fuzzed rulings

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_anySignedAnswerConservesFundsAndMapsRuling(uint256 answer, uint8 rawKey, bool wrongStored)
        public
    {
        uint8 key = uint8(bound(rawKey, 0, KEYS - 1));
        answer = bound(answer, 0, 6);
        uint256 id = _post();
        _fill(id);
        bytes32[] memory truth = _vals("truth");
        bytes32[] memory given = _vals("truth");
        if (wrongStored) given[key] = keccak256("wrong");
        _answerAll(id, given);
        arms.settle(id);
        bytes32 claimed = wrongStored ? truth[key] : keccak256("bogus");
        bytes32 caseId = _challengePrice(id, key, claimed);
        uint256 bonded = arms.totalBonded();
        assertTrue(_answer(caseId, answer), "callback fits 200k");
        ICourt.Ruling expected = answer == 1
            ? ICourt.Ruling.STORED
            : answer == 2 ? ICourt.Ruling.CLAIMED : answer == 0 ? ICourt.Ruling.NEITHER : ICourt.Ruling.NONE;
        assertEq(uint8(imdCourt.rulingOf(address(arms), caseId)), uint8(expected));
        if (expected == ICourt.Ruling.NONE) vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        arms.resolve(id, key, claimed);
        (bytes32 value, Arms.Status status) = arms.results(id, key);
        if (expected == ICourt.Ruling.CLAIMED || expected == ICourt.Ruling.NEITHER) {
            assertEq(bonded - arms.totalBonded(), 2 * TRANCHE);
            assertEq(
                uint8(status), uint8(expected == ICourt.Ruling.CLAIMED ? Arms.Status.CORRECTED : Arms.Status.OVERTURNED)
            );
            if (expected == ICourt.Ruling.CLAIMED) assertEq(value, claimed);
        } else {
            assertEq(arms.totalBonded(), bonded, "no slash");
            assertEq(uint8(status), uint8(Arms.Status.AGREED));
            assertEq(value, given[key]);
        }
        assertEq(arms.totalStakes(), 0);
        assertEq(token.balanceOf(address(arms)), _owed());
        assertEq(feeToken.balanceOf(address(imdCourt)) + feeToken.balanceOf(address(arms)), 0);
        // After the window closes everything unlocks and no reward is left behind.
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        if (!_job(id).released) arms.release(id);
        assertEq(arms.totalRewards(), 0);
        address[] memory drawn = arms.armsOf(id);
        for (uint256 i; i < drawn.length; ++i) {
            assertEq(_arm(drawn[i]).locked, 0, "nothing stays locked");
        }
        assertEq(token.balanceOf(address(arms)), arms.totalBonded());
    }

    // ------------------------------------------------------------------ exact time boundaries

    /// At `challengeEnd` a challenge is still accepted and `release` is still locked; one second
    /// later the challenge is refused and `release` waits only for the open case.
    function test_challengeWindowAndReleaseShareOneBoundary() public {
        (uint256 id,) = _settledJob();
        uint64 end = _job(id).challengeEnd;
        vm.warp(end);
        vm.expectRevert(Arms.StillLocked.selector);
        arms.release(id);
        bytes32 claimed = keccak256("edge");
        bytes32 caseId = _challengePrice(id, 0, claimed);
        vm.warp(uint256(end) + 1);
        vm.prank(challenger);
        vm.expectRevert(Arms.TooLate.selector);
        arms.challenge(id, 1, keccak256("too late"), PRICE);
        vm.expectRevert(Arms.StillLocked.selector);
        arms.release(id);
        // The court deadline counts from the challenge: pending at exactly openedAt + 7 days.
        uint256 opened = _challengeOf(caseId).openedAt;
        vm.warp(opened + 7 days);
        vm.expectRevert(Arms.CourtPending.selector);
        arms.resolve(id, 0, claimed);
        vm.warp(opened + 7 days + 1);
        arms.resolve(id, 0, claimed);
        arms.release(id);
        vm.expectRevert(Arms.AlreadyReleased.selector);
        arms.release(id);
        assertEq(token.balanceOf(address(arms)), _owed());
    }

    /// A failure call (status 1 or 2) closes the court case but never shortens Arms' wait, and a
    /// failure for a request the court never made is refused even from the intake.
    function test_failureNeverShortensTheDeadlineOrTouchesOtherRequests() public {
        (uint256 id,) = _settledJob();
        bytes32 claimed = keccak256("refused");
        bytes32 caseId = _challengePrice(id, 2, claimed);
        IMDCourt.Case memory c = imdCourt.caseOf(address(arms), caseId);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(IMDCourt.UnknownRequest.selector, keccak256("not ours")));
        imdCourt.onOracleFailure(keccak256("not ours"), 1, "body_refused", 0, 0, "");
        vm.prank(WRITER);
        assertTrue(intake.fail(c.requestId, 1, "body_refused"));
        assertFalse(imdCourt.caseOf(address(arms), caseId).open);
        vm.expectRevert(Arms.CourtPending.selector);
        arms.resolve(id, 2, claimed);
        assertFalse(_answer(caseId, 2), "an answer after a failure is refused");
        assertEq(_job(id).openChallenges, 1);
    }
}
