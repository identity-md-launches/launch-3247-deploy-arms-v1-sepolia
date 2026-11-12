// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FormURI} from "./FormURI.sol";

/// @title Form identities, append-only server lists and per-job eligibility history for one Arms instance
/// @notice Created and permanently bound by Arms' constructor. No owner, setter or setup transaction.
/// Arms checks the caller's bond and passes the id of the last posted job with every change, so a
/// serve, a fee change, a stop or a bond change applies to jobs posted after it and never to a job
/// whose draw seed may already be visible: `candidate` and `bondAsOf` answer for the job's own
/// posting time.
contract ArmsForms {
    using Checkpoints for Checkpoints.Trace208;

    struct Form {
        uint8 keyCount;
        string uri;
        address[] servers;
    }

    error OnlyArms();
    error BadForm();
    error FormExists();
    error UnknownForm();
    error FeeTooLow();
    error BadParams();

    address public immutable core;
    uint256 public immutable minFee;
    mapping(bytes32 => Form) public forms;
    mapping(bytes32 => mapping(address => bool)) private listed;
    mapping(bytes32 => mapping(address => uint256)) public minFeeOf;
    mapping(bytes32 => mapping(address => uint256)) public stoppedAt;
    mapping(bytes32 => mapping(address => uint256)) public stoppedAfterJob;
    /// @dev Fee advertised for the form, keyed by the last job posted before the change; 0 = not serving.
    mapping(bytes32 => mapping(address => Checkpoints.Trace208)) private feeHistory;
    /// @dev Bond of the arm, keyed by the last job posted before the change.
    mapping(address => Checkpoints.Trace208) private bondHistory;

    constructor(address core_, uint256 minFee_) {
        if (core_ == address(0) || minFee_ == 0) revert BadParams();
        core = core_;
        minFee = minFee_;
    }

    modifier onlyArms() {
        if (msg.sender != core) revert OnlyArms();
        _;
    }

    function register(bytes32 textHash, uint8 keyCount, string calldata uri) external onlyArms returns (bytes32 id) {
        if (textHash == bytes32(0) || keyCount == 0 || keyCount > 32 || !FormURI.valid(uri)) revert BadForm();
        id = keccak256(abi.encode(textHash, keyCount, uri));
        Form storage f = forms[id];
        if (f.keyCount != 0) revert FormExists();
        f.keyCount = keyCount;
        f.uri = uri;
    }

    /// @notice Lists the arm, or changes its fee, for jobs with an id above `lastJob`.
    function serve(bytes32 id, address arm, uint256 fee, uint256 lastJob) external onlyArms {
        Form storage f = forms[id];
        if (f.keyCount == 0) revert UnknownForm();
        if (fee < minFee) revert FeeTooLow();
        if (!listed[id][arm]) {
            f.servers.push(arm);
            listed[id][arm] = true;
        }
        minFeeOf[id][arm] = fee;
        delete stoppedAt[id][arm];
        feeHistory[id][arm].push(SafeCast.toUint48(lastJob), SafeCast.toUint208(fee));
    }

    /// @notice Stops the arm for jobs with an id above `lastJob`.
    function stop(bytes32 id, address arm, uint256 atBlock, uint256 lastJob) external onlyArms {
        if (!listed[id][arm] || stoppedAt[id][arm] != 0) revert UnknownForm();
        stoppedAt[id][arm] = atBlock;
        stoppedAfterJob[id][arm] = lastJob;
        feeHistory[id][arm].push(SafeCast.toUint48(lastJob), 0);
    }

    /// @notice Records the arm's bond after a change, for jobs with an id above `lastJob`.
    function noteBond(address arm, uint256 lastJob, uint256 bond) external onlyArms {
        bondHistory[arm].push(SafeCast.toUint48(lastJob), SafeCast.toUint208(bond));
    }

    function info(bytes32 id) external view returns (uint8 keyCount, uint256 serverCount) {
        Form storage f = forms[id];
        return (f.keyCount, f.servers.length);
    }

    function serversOf(bytes32 id) external view returns (address[] memory) {
        return forms[id].servers;
    }

    /// @notice The fee the arm advertised for the form when job `jobId` was posted; 0 when it was not serving.
    function feeAsOf(bytes32 id, address arm, uint256 jobId) public view returns (uint256) {
        if (jobId == 0) return 0;
        return feeHistory[id][arm].upperLookup(SafeCast.toUint48(jobId - 1));
    }

    /// @notice The bond the arm had when job `jobId` was posted.
    function bondAsOf(address arm, uint256 jobId) external view returns (uint256) {
        if (jobId == 0) return 0;
        return bondHistory[arm].upperLookup(SafeCast.toUint48(jobId - 1));
    }

    /// @notice Index addresses never move. A serve, fee change or stop affects only jobs posted after it.
    function candidate(bytes32 id, uint256 index, uint256 jobId, uint256 fee) external view returns (address) {
        address arm = forms[id].servers[index];
        uint256 advertised = feeAsOf(id, arm, jobId);
        if (advertised == 0 || advertised > fee) return address(0);
        return arm;
    }
}
