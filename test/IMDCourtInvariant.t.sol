// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Arms} from "../src/Arms.sol";
import {ICourt} from "../src/ICourt.sol";
import {IIntake} from "../src/IIntake.sol";
import {IMDCourt} from "../src/IMDCourt.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MockToken} from "../src/mocks/MockToken.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

/// @dev Drives Arms wired to the production IMDCourt (not MockCourt) through random sequences of
/// jobs, challenges, signed oracle answers, oracle failures, forged and replayed callbacks, time
/// jumps, resolutions, releases and cancellations. Bonds are in one token and the oracle fee in a
/// second, as on Sepolia (ARMT bonds, imdTEST oracle fee). The signer is a test key, the intake a mock.
contract CourtHandler is Test {
    bytes32 internal constant ACTION = 0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000;
    uint256 internal constant PRICE = 0.5 ether;
    uint256 internal constant FEE = 1 ether;
    uint8 internal constant KEYS = 4;
    uint256 internal constant CHAIN = 11155111;
    uint256 internal constant AT_BLOCK = 900;
    /// @dev A throwaway test key, never a real one.
    uint256 internal constant SIGNER_KEY = 0xA11CE5;
    address internal constant WRITER = address(0x717E);

    struct CaseRec {
        uint256 jobId;
        uint8 key;
        bytes32 claimed;
        bytes32 caseId;
        bytes32 requestId;
        bytes32 questionHash;
        bool closed;
        ICourt.Ruling closedRuling;
        OracleAttestation.Attestation lastA;
        bytes lastSig;
        bool delivered;
    }

    Arms public arms;
    IMDCourt public court;
    MockIntake public intake;
    MockToken public token;
    MockToken public feeToken;
    address public tokenOwner;
    address public poster = makeAddr("inv-poster");
    address public challenger = makeAddr("inv-challenger");
    address public stranger = makeAddr("inv-stranger");
    bytes32 public formId;
    address[] public armSet;

    uint256[] public jobIds;
    mapping(uint256 => bytes32[]) internal truthOf;
    CaseRec[] internal cases;

    uint256 public casesOpened;
    uint256 public forgedAccepted;
    uint256 public replayAccepted;
    uint256 public reopened;
    uint256 public rulingMismatch;
    uint256 public calls;
    uint256 public resolvedWithRuling;
    uint256 public settledJobs;

    constructor(
        Arms arms_,
        IMDCourt court_,
        MockIntake intake_,
        MockToken token_,
        MockToken feeToken_,
        address tokenOwner_,
        bytes32 formId_,
        address[] memory armSet_
    ) {
        arms = arms_;
        court = court_;
        intake = intake_;
        token = token_;
        feeToken = feeToken_;
        tokenOwner = tokenOwner_;
        formId = formId_;
        armSet = armSet_;
    }

    function fundActors() external {
        vm.startPrank(tokenOwner);
        token.transfer(poster, 50_000 ether);
        token.transfer(challenger, 50_000 ether);
        feeToken.transfer(challenger, 10_000 ether);
        vm.stopPrank();
        vm.prank(poster);
        token.approve(address(arms), type(uint256).max);
        vm.startPrank(challenger);
        token.approve(address(arms), type(uint256).max);
        feeToken.approve(address(arms), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ helpers

    function _job(uint256 id) internal view returns (Arms.Job memory j) {
        (, bytes memory d) = address(arms).staticcall(abi.encodeWithSelector(arms.jobs.selector, id));
        j = abi.decode(d, (Arms.Job));
    }

    function caseCount() external view returns (uint256) {
        return cases.length;
    }

    function caseAt(uint256 i)
        external
        view
        returns (bytes32 caseId, bool closed, ICourt.Ruling closedRuling, uint256 jobId, uint8 key, bytes32 claimed)
    {
        CaseRec storage c = cases[i];
        return (c.caseId, c.closed, c.closedRuling, c.jobId, c.key, c.claimed);
    }

    function armCount() external view returns (uint256) {
        return armSet.length;
    }

    function _truth(uint256 seed) internal pure returns (bytes32[] memory v) {
        v = new bytes32[](KEYS);
        for (uint256 k; k < KEYS; ++k) {
            v[k] = keccak256(abi.encode("truth", seed, k));
        }
    }

    // ------------------------------------------------------------------ actions

    /// @notice Posts a job, fills it, has every drawn arm give the same answers (sometimes one key
    /// wrong on purpose) and settles it, so it is open for challenges.
    function runJob(uint256 seed, bool oneWrong) external {
        ++calls;
        vm.roll(block.number + 1);
        vm.prank(poster);
        uint256 id = arms.post(formId, CHAIN, address(0xBEEF), AT_BLOCK, FEE);
        jobIds.push(id);
        bytes32[] memory truth = _truth(seed);
        truthOf[id] = truth;
        for (uint256 i; i < 40 && _job(id).phase == Arms.Phase.OPEN; ++i) {
            vm.roll(block.number + 2);
            arms.draw(id);
        }
        if (_job(id).phase != Arms.Phase.COMMIT) return; // left OPEN: `cancel` can refund it later
        bytes32[] memory given = new bytes32[](KEYS);
        for (uint256 k; k < KEYS; ++k) {
            given[k] = truth[k];
        }
        if (oneWrong) given[seed % KEYS] = keccak256(abi.encode("wrong", seed));
        address[] memory drawn = arms.armsOf(id);
        for (uint256 i; i < drawn.length; ++i) {
            vm.prank(drawn[i]);
            arms.commit(id, drawn[i], keccak256(abi.encode(id, drawn[i], given, bytes32(seed))));
        }
        for (uint256 i; i < drawn.length; ++i) {
            vm.prank(drawn[i]);
            arms.reveal(id, drawn[i], given, bytes32(seed), "ipfs://evidence");
        }
        arms.settle(id);
        ++settledJobs;
    }

    function challenge(uint256 jobSeed, uint8 keySeed, bool claimTruth) external {
        ++calls;
        if (jobIds.length == 0) return;
        uint256 id = jobIds[jobSeed % jobIds.length];
        uint8 key = keySeed % KEYS;
        bytes32 claimed = claimTruth ? truthOf[id][key] : keccak256(abi.encode("claim", jobSeed, keySeed));
        uint256 feeBefore = feeToken.balanceOf(intake.treasury());
        vm.prank(challenger);
        try arms.challenge(id, key, claimed, PRICE) returns (bytes32 caseId) {
            ++casesOpened;
            assertEq(feeToken.balanceOf(intake.treasury()) - feeBefore, PRICE, "exactly one price forwarded");
            CaseRec storage c = cases.push();
            c.jobId = id;
            c.key = key;
            c.claimed = claimed;
            c.caseId = caseId;
            IMDCourt.Case memory cc = court.caseOf(address(arms), caseId);
            c.requestId = cc.requestId;
            c.questionHash = cc.questionHash;
            assertTrue(cc.open, "a new case is open");
        } catch {}
    }

    function oracleAnswer(uint256 caseSeed, uint256 answerSeed) external {
        ++calls;
        if (cases.length == 0) return;
        CaseRec storage c = cases[caseSeed % cases.length];
        OracleAttestation.Attestation memory a = OracleAttestation.Attestation({
            requestId: keccak256(abi.encode("uuid", caseSeed, answerSeed, calls)),
            chainId: CHAIN,
            questionHash: c.questionHash,
            answerType: OracleAttestation.ANSWER_UINT256,
            answer: abi.encode(answerSeed % 5),
            figure: 0,
            fromBlock: uint64(AT_BLOCK),
            toBlock: uint64(AT_BLOCK),
            blockHash: keccak256("block"),
            panelJobId: keccak256("panel"),
            panelSize: 5,
            quorum: 4,
            agreed: uint16(4 + answerSeed % 2),
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 days)
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, court.attestationDigest(a));
        bytes memory sig = abi.encodePacked(r, s, v);
        bool wasOpen = court.caseOf(address(arms), c.caseId).open;
        vm.prank(WRITER);
        bool ok = intake.complete(c.requestId, a, sig);
        if (ok && !wasOpen) ++reopened;
        if (ok) {
            c.closed = true;
            c.closedRuling = court.rulingOf(address(arms), c.caseId);
            c.lastA = a;
            c.lastSig = sig;
            c.delivered = true;
        }
    }

    function oracleFail(uint256 caseSeed, uint8 status) external {
        ++calls;
        if (cases.length == 0) return;
        CaseRec storage c = cases[caseSeed % cases.length];
        bool wasOpen = court.caseOf(address(arms), c.caseId).open;
        vm.prank(WRITER);
        bool ok = intake.fail(c.requestId, 1 + status % 2, "disagreed");
        if (ok && !wasOpen) ++reopened;
        if (ok) {
            c.closed = true;
            c.closedRuling = court.rulingOf(address(arms), c.caseId);
        }
    }

    /// @notice Anyone but the intake calling the court's callbacks directly must always fail.
    function forgedCallback(uint256 caseSeed, bool failure) external {
        ++calls;
        if (cases.length == 0) return;
        CaseRec storage c = cases[caseSeed % cases.length];
        if (failure) {
            vm.prank(stranger);
            try court.onOracleFailure(c.requestId, 2, "x", 0, 0, "") {
                ++forgedAccepted;
            } catch {}
        } else if (c.delivered) {
            vm.prank(stranger);
            try court.onOracleResult(c.requestId, c.lastA, c.lastSig) {
                ++forgedAccepted;
            } catch {}
        }
    }

    /// @notice The intake re-presenting an answer that was already delivered must always fail.
    function replay(uint256 caseSeed) external {
        ++calls;
        if (cases.length == 0) return;
        CaseRec storage c = cases[caseSeed % cases.length];
        if (!c.delivered) return;
        vm.prank(address(intake));
        try court.onOracleResult(c.requestId, c.lastA, c.lastSig) {
            ++replayAccepted;
        } catch {}
    }

    function resolve(uint256 caseSeed) external {
        ++calls;
        if (cases.length == 0) return;
        CaseRec storage c = cases[caseSeed % cases.length];
        ICourt.Ruling courtRuling = court.rulingOf(address(arms), c.caseId);
        try arms.resolve(c.jobId, c.key, c.claimed) {
            (,,,,,,,, ICourt.Ruling applied) = arms.challenges(c.caseId);
            if (applied != courtRuling) ++rulingMismatch;
            if (applied != ICourt.Ruling.NONE) ++resolvedWithRuling;
        } catch {}
    }

    function release(uint256 jobSeed) external {
        ++calls;
        if (jobIds.length == 0) return;
        try arms.release(jobIds[jobSeed % jobIds.length]) {} catch {}
    }

    function cancel(uint256 jobSeed) external {
        ++calls;
        if (jobIds.length == 0) return;
        try arms.cancel(jobIds[jobSeed % jobIds.length]) {} catch {}
    }

    function warp(uint256 dt) external {
        ++calls;
        vm.warp(block.timestamp + bound(dt, 0, 8 days));
        vm.roll(block.number + 1);
    }
}

contract IMDCourtInvariantTest is Test {
    bytes32 internal constant ACTION = 0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000;
    uint256 internal constant PRICE = 0.5 ether;
    uint256 internal constant SIGNER_KEY = 0xA11CE5;
    address internal constant WRITER = address(0x717E);

    CourtHandler handler;
    Arms arms;
    IMDCourt court;
    MockIntake intake;
    MockToken token;
    MockToken feeToken;
    address tokenOwner = makeAddr("inv-owner");
    address treasury = makeAddr("inv-treasury");
    address[] armSet;

    function setUp() public {
        vm.chainId(11155111);
        vm.warp(1_800_000_000);
        vm.roll(5_000);
        token = new MockToken(tokenOwner);
        feeToken = new MockToken(tokenOwner);
        intake = new MockIntake(WRITER, treasury, ACTION, address(feeToken), PRICE);
        court =
            new IMDCourt(tokenOwner, IIntake(address(intake)), IERC20(address(feeToken)), ACTION, vm.addr(SIGNER_KEY));
        arms = new Arms(
            address(token),
            address(court),
            1 ether,
            1000 ether,
            100_000 ether,
            10,
            1000,
            3000,
            6 hours,
            2 hours,
            7 days,
            7 days,
            14 days
        );
        bytes32 formId = arms.registerForm(keccak256("control map invariant form"), 4, "ipfs://control-map-inv");
        for (uint256 i; i < 6; ++i) {
            address a = makeAddr(string.concat("inv-arm", vm.toString(i)));
            vm.prank(tokenOwner);
            token.transfer(a, 1000 ether);
            vm.startPrank(a);
            token.approve(address(arms), type(uint256).max);
            arms.bond(1000 ether);
            arms.serve(formId, 1 ether);
            vm.stopPrank();
            armSet.push(a);
        }
        vm.roll(5_010);
        handler = new CourtHandler(arms, court, intake, token, feeToken, tokenOwner, formId, armSet);
        handler.fundActors();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = CourtHandler.runJob.selector;
        selectors[1] = CourtHandler.challenge.selector;
        selectors[2] = CourtHandler.oracleAnswer.selector;
        selectors[3] = CourtHandler.oracleFail.selector;
        selectors[4] = CourtHandler.forgedCallback.selector;
        selectors[5] = CourtHandler.replay.selector;
        selectors[6] = CourtHandler.resolve.selector;
        selectors[7] = CourtHandler.release.selector;
        selectors[8] = CourtHandler.cancel.selector;
        selectors[9] = CourtHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_armsHoldsExactlyWhatItOwes() public view {
        assertEq(
            token.balanceOf(address(arms)),
            arms.totalBonded() + arms.totalEscrow() + arms.totalStakes() + arms.totalRewards()
        );
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_oracleFeeIsNeverHeldOrLeftApproved() public view {
        assertEq(feeToken.balanceOf(address(court)), 0, "court holds no fee");
        assertEq(feeToken.balanceOf(address(arms)), 0, "arms holds no fee");
        assertEq(feeToken.allowance(address(court), address(intake)), 0, "court leaves no intake allowance");
        assertEq(feeToken.allowance(address(arms), address(court)), 0, "arms leaves no court allowance");
        assertEq(feeToken.balanceOf(treasury), handler.casesOpened() * PRICE, "one price per opened case");
        assertEq(token.balanceOf(address(court)), 0, "court never holds bond tokens");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_onlyTheIntakeAndOnlyOnceCloseACase() public view {
        assertEq(handler.forgedAccepted(), 0, "a stranger's callback was accepted");
        assertEq(handler.replayAccepted(), 0, "a replayed attestation was accepted");
        assertEq(handler.reopened(), 0, "a closed case accepted a second callback");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_closedRulingsNeverChangeAndArmsAppliesTheCourts() public view {
        assertEq(handler.rulingMismatch(), 0, "arms applied a ruling the court did not give");
        uint256 n = handler.caseCount();
        for (uint256 i; i < n; ++i) {
            (bytes32 caseId, bool closed, ICourt.Ruling closedRuling,,,) = handler.caseAt(i);
            IMDCourt.Case memory c = court.caseOf(address(arms), caseId);
            assertTrue(c.exists, "an opened case exists");
            if (closed) {
                assertFalse(c.open, "a closed case never reopens");
                assertEq(uint8(c.ruling), uint8(closedRuling), "a ruling never changes");
            } else {
                assertEq(uint8(c.ruling), uint8(ICourt.Ruling.NONE), "an unanswered case has no ruling");
            }
            (,,,,,,, bool resolved, ICourt.Ruling applied) = arms.challenges(caseId);
            if (resolved && applied != ICourt.Ruling.NONE) assertEq(uint8(applied), uint8(c.ruling));
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_lockedWithinBondAndBondsSum() public view {
        uint256 sum;
        for (uint256 i; i < armSet.length; ++i) {
            (uint256 bond, uint256 locked,,,,,,) = arms.arms(armSet[i]);
            assertLe(locked, bond, "locked above bond");
            sum += bond;
        }
        assertEq(sum, arms.totalBonded(), "bonds sum to totalBonded");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_supplyEqualsHoldersAndFeeSupplyFixed() public view {
        uint256 held = token.balanceOf(tokenOwner) + token.balanceOf(address(arms)) + token.balanceOf(handler.poster())
            + token.balanceOf(handler.challenger());
        for (uint256 i; i < armSet.length; ++i) {
            held += token.balanceOf(armSet[i]);
        }
        assertEq(token.totalSupply(), held, "every bond token is accounted for");
        assertLe(token.totalSupply(), token.INITIAL_SUPPLY(), "supply never grows");
        assertEq(feeToken.totalSupply(), feeToken.INITIAL_SUPPLY(), "the fee is forwarded, never burned");
    }

    /// @dev Non-vacuity: one fixed sequence through the same handler reaches a settled job, an opened
    /// case, a signed CLAIMED ruling, forged and replayed callbacks refused, and a resolution that slashes.
    function test_handlerSequenceReachesEveryStage() public {
        uint256 bondedBefore = arms.totalBonded();
        handler.runJob(7, true); // key 7 % 4 = 3 is agreed wrong
        assertEq(handler.settledJobs(), 1, "job settled");
        handler.challenge(0, 3, true); // claims the truth for key 3
        assertEq(handler.casesOpened(), 1, "case opened");
        handler.forgedCallback(0, true);
        handler.oracleAnswer(0, 2); // answer 2 = CLAIMED
        handler.forgedCallback(0, false);
        handler.replay(0);
        handler.oracleFail(0, 0);
        assertEq(handler.forgedAccepted() + handler.replayAccepted() + handler.reopened(), 0);
        handler.resolve(0);
        assertEq(handler.resolvedWithRuling(), 1, "ruling applied");
        assertLt(arms.totalBonded(), bondedBefore, "wrong arms slashed");
        (bytes32 caseId,,,,,) = handler.caseAt(0);
        assertEq(uint8(court.rulingOf(address(arms), caseId)), uint8(ICourt.Ruling.CLAIMED));
        invariant_armsHoldsExactlyWhatItOwes();
        invariant_oracleFeeIsNeverHeldOrLeftApproved();
        invariant_closedRulingsNeverChangeAndArmsAppliesTheCourts();
        invariant_lockedWithinBondAndBondsSum();
        invariant_supplyEqualsHoldersAndFeeSupplyFixed();
    }
}
