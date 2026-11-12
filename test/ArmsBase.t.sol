// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Arms} from "../src/Arms.sol";
import {ICourt} from "../src/ICourt.sol";
import {MockCourt} from "../src/mocks/MockCourt.sol";
import {MockToken} from "../src/mocks/MockToken.sol";

/// @dev Shared harness: a token, a mock court charging a fee in the same token, Arms with the Sepolia
/// parameters, six bonded arms serving one form, a poster and a challenger.
abstract contract ArmsBase is Test {
    uint256 constant FEE = 1 ether;
    uint256 constant TRANCHE = 10 ether;
    uint256 constant STAKE = 2 ether;
    uint256 constant COURT_FEE = 0.5 ether;
    uint256 constant ARM_BOND = 500 ether;
    uint8 constant KEYS = 4;
    uint256 constant CHAIN = 11155111;
    uint256 constant AT_BLOCK = 5_000_000;

    MockToken token;
    MockCourt court;
    Arms arms;

    address tokenOwner = makeAddr("tokenOwner");
    address poster = makeAddr("poster");
    address challenger = makeAddr("challenger");
    address target = address(0xBEEF);
    bytes32 formId = keccak256("Arms form v1: four questions about a target contract");
    address[] armSet;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        vm.roll(1000);
        token = new MockToken(tokenOwner);
        court = new MockCourt(address(token), COURT_FEE);
        arms = _deploy(sepoliaParams(address(token), address(court)));
        formId = arms.registerForm(
            formId, KEYS, "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/form.md"
        );
        for (uint256 i; i < 6; ++i) {
            address a = makeAddr(string.concat("arm", vm.toString(i)));
            _fund(a, 1000 ether);
            vm.startPrank(a);
            arms.bond(ARM_BOND);
            arms.serve(formId, FEE);
            vm.stopPrank();
            armSet.push(a);
        }
        _fund(poster, 1000 ether);
        _fund(challenger, 1000 ether);
    }

    function sepoliaParams(address token_, address court_) public pure returns (Arms.Params memory p) {
        p.token = token_;
        p.court = court_;
        p.trancheMultiple = 10;
        p.minFeePerArm = FEE;
        p.maxBondPerArm = 1000 ether;
        p.maxTotalBonded = 100_000 ether;
        p.burnBps = 1000;
        p.challengerRewardBps = 3000;
        p.commitWindow = 6 hours;
        p.revealWindow = 2 hours;
        p.challengeWindow = 7 days;
        p.courtDeadline = 7 days;
        p.exitDelay = 14 days;
    }

    function _deploy(Arms.Params memory p) internal returns (Arms) {
        return new Arms(
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

    function _fund(address who, uint256 amount) internal {
        vm.prank(tokenOwner);
        token.transfer(who, amount);
        vm.prank(who);
        token.approve(address(arms), type(uint256).max);
    }

    function _job(uint256 id) internal view returns (Arms.Job memory j) {
        (, bytes memory d) = address(arms).staticcall(abi.encodeWithSelector(arms.jobs.selector, id));
        j = abi.decode(d, (Arms.Job));
    }

    function _arm(address a) internal view returns (Arms.ArmInfo memory s) {
        (, bytes memory d) = address(arms).staticcall(abi.encodeWithSelector(arms.arms.selector, a));
        s = abi.decode(d, (Arms.ArmInfo));
    }

    function _challengeOf(bytes32 caseId) internal view returns (Arms.Challenge memory c) {
        (, bytes memory d) = address(arms).staticcall(abi.encodeWithSelector(arms.challenges.selector, caseId));
        c = abi.decode(d, (Arms.Challenge));
    }

    function _post() internal returns (uint256 id) {
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(poster);
        id = arms.post(formId, CHAIN, target, AT_BLOCK, FEE);
    }

    /// @dev Draws until the job is in COMMIT.
    function _fill(uint256 id) internal {
        for (uint256 i; i < 30; ++i) {
            vm.roll(vm.getBlockNumber() + 2);
            if (_job(id).phase == Arms.Phase.COMMIT) return;
            arms.draw(id);
        }
        if (_job(id).phase == Arms.Phase.COMMIT) return;
        revert("not filled");
    }

    /// @dev Draws until the tie break arm is in place.
    function _fillTie(uint256 id) internal {
        vm.roll(vm.getBlockNumber() + 2);
        arms.draw(id);
        assertEq(uint8(_job(id).phase), uint8(Arms.Phase.TIE_COMMIT), "tie not drawn");
    }

    /// @dev Posts jobs until one is a spot check (three arms). Deterministic under the seeded hash.
    function _postSpot() internal returns (uint256 id) {
        for (uint256 i; i < 60; ++i) {
            id = _post();
            vm.roll(vm.getBlockNumber() + 2);
            arms.draw(id);
            if (_job(id).needed == 3) {
                _fill(id);
                return id;
            }
            // Finish the two-arm job honestly so nobody is struck.
            _fill(id);
            _answerAll(id, _vals("filler"));
            arms.settle(id);
        }
        revert("no spot check job found");
    }

    function _vals(bytes32 seed) internal pure returns (bytes32[] memory v) {
        v = new bytes32[](KEYS);
        for (uint256 k; k < KEYS; ++k) {
            v[k] = keccak256(abi.encode(seed, k));
        }
    }

    function _salt(address a) internal pure returns (bytes32) {
        return keccak256(abi.encode("salt", a));
    }

    function _commit(uint256 id, address a, bytes32[] memory v) internal {
        vm.prank(a);
        arms.commit(id, a, keccak256(abi.encode(id, a, v, _salt(a))));
    }

    function _reveal(uint256 id, address a, bytes32[] memory v) internal {
        vm.prank(a);
        arms.reveal(id, a, v, _salt(a), string.concat("ipfs://evidence/", vm.toString(a)));
    }

    /// @dev Every drawn arm commits then reveals `v`.
    function _answerAll(uint256 id, bytes32[] memory v) internal {
        address[] memory drawn = arms.armsOf(id);
        for (uint256 i; i < drawn.length; ++i) {
            _commit(id, drawn[i], v);
        }
        for (uint256 i; i < drawn.length; ++i) {
            _reveal(id, drawn[i], v);
        }
    }

    /// @dev Post, fill, agree on `_vals("truth")`, settle.
    function _settledJob() internal returns (uint256 id, bytes32[] memory v) {
        id = _post();
        _fill(id);
        v = _vals("truth");
        _answerAll(id, v);
        arms.settle(id);
        assertEq(uint8(_job(id).phase), uint8(Arms.Phase.SETTLED));
    }

    function _challenge(uint256 id, uint8 key, bytes32 claimed) internal returns (bytes32 caseId) {
        vm.prank(challenger);
        caseId = arms.challenge(id, key, claimed, COURT_FEE);
    }

    function _rule(bytes32 caseId, ICourt.Ruling r) internal {
        court.rule(address(arms), caseId, r);
    }
}
