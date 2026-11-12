// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Arms} from "../src/Arms.sol";
import {ICourt} from "../src/ICourt.sol";
import {MockCourt} from "../src/mocks/MockCourt.sol";
import {MockToken} from "../src/mocks/MockToken.sol";

/// @dev One operator controls every actor (eight addresses that bond, post, answer, challenge). The
/// handler performs any protocol action, records ghost facts, and flips `violated` when a property it
/// can only check at the moment of an action fails.
contract ArmsHandler is Test {
    uint256 constant FEE = 1 ether;
    uint256 constant TRANCHE = 10 ether;
    uint8 constant KEYS = 3;

    Arms public arms;
    MockToken public token;
    MockCourt public court;
    bytes32 public formId = keccak256(abi.encode(keccak256("invariant form"), uint8(3), "ipfs://form"));
    address[] public actors;
    uint256[] public jobIds;
    uint256 public initialSupply;
    uint256 public initialActorFunds;
    bool public violated;
    string public violation;

    mapping(uint256 => uint256) public posterGot;
    mapping(uint256 => mapping(address => uint256)) public lostInJob;
    mapping(uint256 => mapping(address => bool)) public allUnknown;
    mapping(uint256 => mapping(uint8 => Arms.Status)) public finalStatus;
    bytes32[] public openCases;

    constructor(Arms arms_, MockToken token_, MockCourt court_) {
        arms = arms_;
        token = token_;
        court = court_;
        for (uint256 i; i < 8; ++i) {
            address actor = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(actor);
            (uint256 bonded,,,,,,,) = arms.arms(actor);
            initialActorFunds += token.balanceOf(actor) + bonded;
        }
        initialSupply = token.totalSupply();
    }

    function _fail(string memory why) internal {
        violated = true;
        violation = why;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _job(uint256 id) internal view returns (Arms.Job memory j) {
        (, bytes memory d) = address(arms).staticcall(abi.encodeWithSelector(arms.jobs.selector, id));
        j = abi.decode(d, (Arms.Job));
    }

    function _arm(address a) internal view returns (Arms.ArmInfo memory s) {
        (, bytes memory d) = address(arms).staticcall(abi.encodeWithSelector(arms.arms.selector, a));
        s = abi.decode(d, (Arms.ArmInfo));
    }

    function _pick(uint256 seed) internal view returns (uint256 id) {
        if (jobIds.length == 0) return 0;
        return jobIds[seed % jobIds.length];
    }

    // ---- actions ----

    function bond(uint256 who, uint256 amount) external {
        address a = _actor(who);
        amount = bound(amount, 1, 200 ether);
        uint256 bal = token.balanceOf(a);
        if (bal < amount) return;
        vm.prank(a);
        arms.bond(amount);
        vm.prank(a);
        arms.serve(formId, FEE);
    }

    function requestExit(uint256 who) external {
        address a = _actor(who);
        if (_arm(a).exiting) return;
        vm.prank(a);
        arms.requestExit();
    }

    /// @dev Property: unlocked bond can always be withdrawn after exitDelay.
    function exitAndWithdraw(uint256 who) external {
        address a = _actor(who);
        Arms.ArmInfo memory s = _arm(a);
        if (!s.exiting) {
            vm.prank(a);
            arms.requestExit();
            s = _arm(a);
        }
        if (vm.getBlockTimestamp() < s.exitAt) vm.warp(s.exitAt);
        uint256 unlocked = s.bond - s.locked;
        if (unlocked == 0) return;
        uint256 before = token.balanceOf(a);
        vm.prank(a);
        (bool ok,) = address(arms).call(abi.encodeWithSelector(arms.withdraw.selector));
        if (!ok || token.balanceOf(a) - before != unlocked) _fail("withdraw after exitDelay");
    }

    function reactivate(uint256 who) external {
        address a = _actor(who);
        Arms.ArmInfo memory s = _arm(a);
        if (!s.inactive) return;
        if (vm.getBlockTimestamp() < uint256(s.deactivatedAt) + 1 days) vm.warp(uint256(s.deactivatedAt) + 1 days);
        vm.prank(a);
        arms.reactivate();
    }

    function post(uint256 who) external {
        address p = _actor(who);
        if (token.balanceOf(p) < 3 * FEE) return;
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(p);
        uint256 id = arms.post(formId, 11155111, address(0xBEEF), 100, FEE);
        jobIds.push(id);
    }

    function draw(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id == 0) return;
        Arms.Job memory j = _job(id);
        if (j.phase != Arms.Phase.OPEN && j.phase != Arms.Phase.TIE_OPEN) return;
        vm.roll(vm.getBlockNumber() + 2);
        (bool ok,) = address(arms).call(abi.encodeWithSelector(arms.draw.selector, id));
        if (!ok) return;
        address[] memory drawn = arms.armsOf(id);
        for (uint256 i; i < drawn.length; ++i) {
            if (drawn[i] == j.poster) _fail("poster drawn");
            for (uint256 k = i + 1; k < drawn.length; ++k) {
                if (drawn[i] == drawn[k]) _fail("arm drawn twice");
            }
        }
        Arms.Job memory post_ = _job(id);
        if (post_.tieBreaker != address(0)) {
            if (post_.tieBreaker == j.poster) _fail("poster drawn as tie breaker");
            for (uint256 i; i < drawn.length; ++i) {
                if (drawn[i] == post_.tieBreaker) _fail("tie breaker already on job");
            }
        }
    }

    /// @dev Every arm commits and reveals. `mode` 0: all agree; 1: one arm differs on key 0;
    /// 2: one arm answers all UNKNOWN; 3: one arm never reveals (timeout path).
    function answer(uint256 seed, uint8 mode) external {
        uint256 id = _pick(seed);
        if (id == 0) return;
        Arms.Job memory j = _job(id);
        mode = mode % 4;
        if (j.phase == Arms.Phase.COMMIT) {
            address[] memory drawn = arms.armsOf(id);
            for (uint256 i; i < drawn.length; ++i) {
                bytes32[] memory v = _values(i, mode, KEYS);
                if (mode == 2 && i == 0) allUnknown[id][drawn[i]] = true;
                vm.prank(drawn[i]);
                arms.commit(id, drawn[i], keccak256(abi.encode(id, drawn[i], v, bytes32(uint256(i)))));
            }
            for (uint256 i; i < drawn.length; ++i) {
                if (mode == 3 && i == 0) continue;
                bytes32[] memory v = _values(i, mode, KEYS);
                vm.prank(drawn[i]);
                arms.reveal(id, drawn[i], v, bytes32(uint256(i)), "ipfs://e");
            }
        } else if (j.phase == Arms.Phase.TIE_COMMIT) {
            bytes32[] memory v = _values(mode % 2, mode == 2 ? 0 : mode, j.disputedCount);
            vm.prank(j.tieBreaker);
            arms.commit(id, j.tieBreaker, keccak256(abi.encode(id, j.tieBreaker, v, bytes32(0))));
            if (mode == 3) return;
            vm.prank(j.tieBreaker);
            arms.reveal(id, j.tieBreaker, v, bytes32(0), "ipfs://tb");
        }
    }

    function _values(uint256 armIndex, uint8 mode, uint256 n) internal view returns (bytes32[] memory v) {
        v = new bytes32[](n);
        for (uint256 k; k < n; ++k) {
            v[k] = keccak256(abi.encode("truth", k));
        }
        if (mode == 1 && armIndex == 0) v[0] = keccak256("differs");
        if (mode == 2 && armIndex == 0) {
            for (uint256 k; k < n; ++k) {
                v[k] = arms.UNKNOWN();
            }
        }
    }

    function timeout(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id == 0) return;
        Arms.Job memory j = _job(id);
        if (j.deadline == 0) return;
        if (vm.getBlockTimestamp() <= j.deadline) vm.warp(uint256(j.deadline) + 1);
        (bool ok,) = address(arms).call(abi.encodeWithSelector(arms.timeout.selector, id));
        ok;
    }

    function cancel(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id == 0) return;
        Arms.Job memory j = _job(id);
        if (j.phase != Arms.Phase.OPEN) return;
        if (vm.getBlockTimestamp() <= uint256(j.openSince) + 1 days) vm.warp(uint256(j.openSince) + 1 days + 1);
        uint256 before = token.balanceOf(j.poster);
        arms.cancel(id);
        posterGot[id] += token.balanceOf(j.poster) - before;
    }

    function settle(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id == 0) return;
        Arms.Job memory j = _job(id);
        if (j.phase == Arms.Phase.TIE_OPEN && vm.getBlockTimestamp() <= uint256(j.openSince) + 1 days) {
            vm.warp(uint256(j.openSince) + 1 days + 1);
        }
        address[] memory drawn = arms.armsOf(id);
        uint256[] memory before = new uint256[](drawn.length);
        for (uint256 i; i < drawn.length; ++i) {
            before[i] = token.balanceOf(drawn[i]);
        }
        uint256 posterBefore = token.balanceOf(j.poster);
        (bool ok,) = address(arms).call(abi.encodeWithSelector(arms.settle.selector, id));
        if (!ok) return;
        posterGot[id] += token.balanceOf(j.poster) - posterBefore;
        for (uint256 i; i < drawn.length; ++i) {
            if (allUnknown[id][drawn[i]] && token.balanceOf(drawn[i]) != before[i]) _fail("UNKNOWN paid");
        }
    }

    function challenge(uint256 seed, uint8 key, uint256 who) external {
        uint256 id = _pick(seed);
        if (id == 0) return;
        Arms.Job memory j = _job(id);
        if (j.phase != Arms.Phase.SETTLED || vm.getBlockTimestamp() > j.challengeEnd) return;
        key = key % KEYS;
        (bytes32 value, Arms.Status st) = arms.results(id, key);
        if (st != Arms.Status.AGREED && st != Arms.Status.MAJORITY) return;
        address c = _actor(who);
        if (token.balanceOf(c) < 3 ether) return;
        bytes32 claimed = keccak256(abi.encode("claim", id, key, who % 3));
        if (claimed == value) return;
        bytes32 caseId = arms.caseIdOf(id, key, claimed);
        (,,,,,, bool exists,,) = arms.challenges(caseId);
        if (exists) return;
        vm.prank(c);
        arms.challenge(id, key, claimed, 0.5 ether);
        openCases.push(caseId);
    }

    function rule(uint256 seed, uint8 r) external {
        if (openCases.length == 0) return;
        bytes32 caseId = openCases[seed % openCases.length];
        court.rule(address(arms), caseId, ICourt.Ruling(r % 4));
    }

    function resolve(uint256 seed) external {
        if (openCases.length == 0) return;
        bytes32 caseId = openCases[seed % openCases.length];
        (uint256 id, uint8 key, bytes32 claimed,,, uint64 openedAt, bool exists, bool resolved,) =
            arms.challenges(caseId);
        if (!exists || resolved) return;
        Arms.Job memory j = _job(id);
        if (
            court.rulingOf(address(arms), caseId) == ICourt.Ruling.NONE
                && vm.getBlockTimestamp() <= uint256(openedAt) + 7 days
        ) vm.warp(uint256(openedAt) + 7 days + 1);
        address[] memory drawn = arms.armsOf(id);
        uint256[] memory bondBefore = new uint256[](drawn.length + 1);
        for (uint256 i; i < drawn.length; ++i) {
            bondBefore[i] = _arm(drawn[i]).bond;
        }
        if (j.tieBreaker != address(0)) bondBefore[drawn.length] = _arm(j.tieBreaker).bond;
        uint256 posterBefore = token.balanceOf(j.poster);
        arms.resolve(id, key, claimed);
        uint256 got = token.balanceOf(j.poster) - posterBefore;
        posterGot[id] += got;
        Arms.Job memory post_ = _job(id);
        if (!j.slashedOnce && post_.slashedOnce && got != j.spent) _fail("first slash did not cover the refund");
        if (j.slashedOnce && got != 0) _fail("poster refunded twice");
        for (uint256 i; i <= drawn.length; ++i) {
            address a = i < drawn.length ? drawn[i] : j.tieBreaker;
            if (a == address(0)) continue;
            uint256 lost = bondBefore[i] - _arm(a).bond;
            lostInJob[id][a] += lost;
            if (lostInJob[id][a] > TRANCHE) _fail("more than one tranche lost in a job");
            if (allUnknown[id][a] && lost != 0) _fail("UNKNOWN slashed");
        }
        (, Arms.Status st) = arms.results(id, key);
        Arms.Status recorded = finalStatus[id][key];
        if (recorded == Arms.Status.CORRECTED || recorded == Arms.Status.OVERTURNED) {
            if (st != recorded) _fail("ruling applied twice");
        } else if (st == Arms.Status.CORRECTED || st == Arms.Status.OVERTURNED) {
            finalStatus[id][key] = st;
        }
    }

    function release(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id == 0) return;
        Arms.Job memory j = _job(id);
        if (j.phase != Arms.Phase.SETTLED || j.openChallenges != 0 || j.released) return;
        if (vm.getBlockTimestamp() <= j.challengeEnd) vm.warp(uint256(j.challengeEnd) + 1);
        arms.release(id);
    }

    function warp(uint32 by) external {
        vm.warp(vm.getBlockTimestamp() + bound(by, 1, 3 days));
        vm.roll(vm.getBlockNumber() + 1);
    }

    function jobCount() external view returns (uint256) {
        return jobIds.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

contract ArmsInvariantTest is Test {
    uint256 constant FEE = 1 ether;
    MockToken token;
    MockCourt court;
    Arms arms;
    ArmsHandler handler;
    address tokenOwner = makeAddr("tokenOwner");

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(1000);
        token = new MockToken(tokenOwner);
        court = new MockCourt(address(token), 0.5 ether);
        Arms.Params memory p;
        p.token = address(token);
        p.court = address(court);
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
        arms = new Arms(
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
        bytes32 formId = keccak256("invariant form");
        formId = arms.registerForm(formId, 3, "ipfs://form");
        address[] memory actors = new address[](8);
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
            vm.prank(tokenOwner);
            token.transfer(actors[i], 1000 ether);
            vm.startPrank(actors[i]);
            token.approve(address(arms), type(uint256).max);
            arms.bond(100 ether);
            arms.serve(formId, FEE);
            vm.stopPrank();
        }
        handler = new ArmsHandler(arms, token, court);
        targetContract(address(handler));
    }

    function invariant_balanceEqualsBondsEscrowStakesRewards() public view {
        assertEq(
            token.balanceOf(address(arms)),
            arms.totalBonded() + arms.totalEscrow() + arms.totalStakes() + arms.totalRewards(),
            "balance equation"
        );
    }

    function invariant_bondsSumAndLockedWithinBond() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            (uint256 bondOf, uint256 locked,,,,,,) = arms.arms(handler.actors(i));
            assertLe(locked, bondOf, "locked within bond");
            sum += bondOf;
        }
        assertEq(sum, arms.totalBonded(), "bonds sum");
    }

    function invariant_posterNeverGetsMoreThanEscrowPlusOneRefund() public view {
        for (uint256 i; i < handler.jobCount(); ++i) {
            uint256 id = handler.jobIds(i);
            (, bytes memory d) = address(arms).staticcall(abi.encodeWithSelector(arms.jobs.selector, id));
            Arms.Job memory j = abi.decode(d, (Arms.Job));
            // Escrow returned (3 fees minus what was spent) plus at most one refund of what was spent.
            assertLe(handler.posterGot(id), 3 * FEE, "poster over-refunded");
            if (!j.slashedOnce) assertLe(handler.posterGot(id), 3 * FEE - j.spent, "refund without a slash");
        }
    }

    function invariant_operatorNeverGains() public view {
        uint256 held;
        for (uint256 i; i < handler.actorCount(); ++i) {
            held += token.balanceOf(handler.actors(i));
        }
        assertLe(held, handler.initialActorFunds(), "operator ended with more than it began with");
        assertLe(token.totalSupply(), handler.initialSupply(), "supply only burns");
    }

    function invariant_supplyEqualsAllHolders() public view {
        uint256 held = token.balanceOf(tokenOwner) + token.balanceOf(address(arms)) + token.balanceOf(address(court));
        for (uint256 i; i < handler.actorCount(); ++i) {
            held += token.balanceOf(handler.actors(i));
        }
        assertEq(held, token.totalSupply(), "all unburned tokens are accounted for");
        assertLe(held, token.INITIAL_SUPPLY());
    }

    function invariant_handlerPropertiesHeld() public view {
        assertFalse(handler.violated(), handler.violation());
    }
}
