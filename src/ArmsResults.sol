// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Arms} from "./Arms.sol";

/// @dev A public mapping getter for an all-static Arms.Job has exactly the ABI encoding of this struct.
interface IArmsResultsSource {
    function jobs(uint256 id) external view returns (Arms.Job memory);
    function armsOf(uint256 id) external view returns (address[] memory);
    function answerOf(uint256 id, address arm, uint8 key) external view returns (bytes32);
    function results(uint256 id, uint8 key) external view returns (bytes32, Arms.Status);
    function entries(uint256 id, address arm) external view returns (bytes32, bool, bool, string memory);
    function slashedIn(uint256 id, address arm) external view returns (bool);
}

/// @title Read-only verdict and payment calculation
/// @notice Stateless helper created by Arms. It reads the calling core, computes vote counts and
/// payment entitlements, and never moves funds or updates a job. All source reads are static calls
/// to its caller; when used by Arms that caller is the core itself.
contract ArmsResults {
    bytes32 private constant UNKNOWN = keccak256("ARMS_UNKNOWN");

    struct Outcome {
        bytes32[] values;
        Arms.Status[] statuses;
        uint256[] payments;
        uint256 tiePayment;
    }

    function disputes(uint256 id) external view returns (uint32 mask, uint8 count) {
        IArmsResultsSource source = IArmsResultsSource(msg.sender);
        Arms.Job memory j = source.jobs(id);
        if (j.needed != 2) return (0, 0);
        address[] memory voters = source.armsOf(id);
        for (uint8 k; k < j.keyCount; ++k) {
            (,, bool disputed) = _evaluate(source, id, voters, address(0), k);
            if (disputed) {
                mask |= uint32(1) << k;
                ++count;
            }
        }
    }

    function settlement(uint256 id, bool withTie) external view returns (Outcome memory o) {
        IArmsResultsSource source = IArmsResultsSource(msg.sender);
        Arms.Job memory j = source.jobs(id);
        address[] memory voters = source.armsOf(id);
        o.values = new bytes32[](j.keyCount);
        o.statuses = new Arms.Status[](j.keyCount);
        o.payments = new uint256[](voters.length);
        uint256 tieCorrect;
        for (uint8 k; k < j.keyCount; ++k) {
            bool disputed = j.disputedMask & (uint32(1) << k) != 0;
            (bytes32 value, Arms.Status status,) =
                _evaluate(source, id, voters, withTie && disputed ? j.tieBreaker : address(0), k);
            if (disputed && !withTie) status = Arms.Status.UNRESOLVED;
            o.values[k] = value;
            o.statuses[k] = status;
            if (status != Arms.Status.AGREED && status != Arms.Status.MAJORITY) continue;
            for (uint256 i; i < voters.length; ++i) {
                if (source.answerOf(id, voters[i], k) == value) ++o.payments[i];
            }
            if (withTie && disputed && source.answerOf(id, j.tieBreaker, k) == value) ++tieCorrect;
        }
        for (uint256 i; i < voters.length; ++i) {
            o.payments[i] = j.feePerArm * o.payments[i] / j.keyCount;
        }
        if (withTie && j.disputedCount > 0) o.tiePayment = j.feePerArm * tieCorrect / j.disputedCount;
    }

    /// @notice The voters of job `id` that gave `value` on `key` and have not been slashed in this job.
    /// The tie breaker counts only on a key it was drawn for. Used for a slash and for a stake split.
    function givers(uint256 id, uint8 key, bytes32 value) external view returns (address[] memory list) {
        IArmsResultsSource source = IArmsResultsSource(msg.sender);
        Arms.Job memory j = source.jobs(id);
        address[] memory voters = source.armsOf(id);
        uint256 n = voters.length;
        bool tie = j.tieBreaker != address(0) && j.disputedMask & (uint32(1) << key) != 0;
        list = new address[](n + (tie ? 1 : 0));
        uint256 g;
        for (uint256 i; i < list.length; ++i) {
            address a = i < n ? voters[i] : j.tieBreaker;
            if (!source.slashedIn(id, a) && source.answerOf(id, a, key) == value) list[g++] = a;
        }
        assembly ("memory-safe") {
            mstore(list, g)
        }
    }

    function verdict(uint256 id) external view returns (Arms.Verdict memory v) {
        IArmsResultsSource source = IArmsResultsSource(msg.sender);
        Arms.Job memory j = source.jobs(id);
        v.values = new bytes32[](j.keyCount);
        v.statuses = new Arms.Status[](j.keyCount);
        for (uint8 k; k < j.keyCount; ++k) {
            (v.values[k], v.statuses[k]) = source.results(id, k);
        }
        v.feePerArm = j.feePerArm;
        v.overturned = j.overturned;
        v.challengeEnd = j.challengeEnd;
        v.atBlock = j.atBlock;
        v.arms = source.armsOf(id);
        v.evidence = new string[](v.arms.length);
        for (uint256 i; i < v.arms.length; ++i) {
            (,,, v.evidence[i]) = source.entries(id, v.arms[i]);
        }
        v.tieBreaker = j.tieBreaker;
        (,,, v.tieEvidence) = source.entries(id, j.tieBreaker);
        v.phase = j.phase;
    }

    function _evaluate(IArmsResultsSource source, uint256 id, address[] memory voters, address tie, uint8 key)
        private
        view
        returns (bytes32 value, Arms.Status status, bool disputed)
    {
        bytes32[3] memory vals;
        uint256[3] memory cnt;
        uint256 m;
        uint256 n = voters.length;
        uint256 answered;
        uint256 count = n + (tie != address(0) ? 1 : 0);
        for (uint256 i; i < count; ++i) {
            bytes32 v = source.answerOf(id, i < n ? voters[i] : tie, key);
            if (v == UNKNOWN) continue;
            ++answered;
            bool found;
            for (uint256 x; x < m; ++x) {
                if (vals[x] == v) {
                    ++cnt[x];
                    found = true;
                    break;
                }
            }
            if (!found) {
                vals[m] = v;
                cnt[m] = 1;
                ++m;
            }
        }
        if (m == 1 && answered == n && tie == address(0)) return (vals[0], Arms.Status.AGREED, false);
        uint256 best;
        bool unique = true;
        for (uint256 x = 1; x < m; ++x) {
            if (cnt[x] > cnt[best]) {
                best = x;
                unique = true;
            } else if (cnt[x] == cnt[best]) {
                unique = false;
            }
        }
        if (m > 0 && cnt[best] >= 2 && unique) return (vals[best], Arms.Status.MAJORITY, false);
        if (m >= 2 && tie == address(0) && n == 2) return (bytes32(0), Arms.Status.NONE, true);
        return (bytes32(0), Arms.Status.UNRESOLVED, false);
    }
}
