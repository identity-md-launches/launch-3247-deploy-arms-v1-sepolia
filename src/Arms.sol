// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICourt} from "./ICourt.sol";
import {Blocks} from "./Blocks.sol";
import {ArmsForms} from "./ArmsForms.sol";
import {ArmsResults} from "./ArmsResults.sol";

interface IBurnableToken is IERC20 {
    function burn(uint256 amount) external;
}

/// @title Arms v1: bonded agents answer a fixed form about a target contract
/// @notice No owner, admin, upgrade or pause. Parameters are immutable or fixed v1 constants. The
/// token is used through `transfer`, `transferFrom`, `balanceOf` and `burn(uint256)` only. Anyone can
/// advance any timeout.
///
/// Lifecycle of a job: `post` escrows 3 x feePerArm -> `draw` (two arms, a third one in
/// `spotCheckOneIn` cases) -> `commit` -> `reveal` -> `settle`. Keys where the arms differ go to a
/// tie break arm (`draw` again, `commit`, `reveal`, `settle`). After `settle` a `challengeWindow`
/// opens; `challenge` asks the court, `resolve` applies its ruling; `release` unlocks the arms'
/// tranches once the window has closed with nothing open.
contract Arms {
    // ---- types ----

    enum Status {
        NONE,
        AGREED,
        MAJORITY,
        UNRESOLVED,
        CORRECTED,
        OVERTURNED
    }

    enum Phase {
        NONE,
        OPEN,
        COMMIT,
        REVEAL,
        TIE_OPEN,
        TIE_COMMIT,
        TIE_REVEAL,
        SETTLED,
        CANCELLED
    }

    /// @dev Used only for the deployment event and off-chain reads; never a constructor argument.
    struct Params {
        address token;
        address court;
        uint256 minFeePerArm;
        uint256 maxBondPerArm;
        uint256 maxTotalBonded;
        uint256 trancheMultiple;
        uint256 burnBps;
        uint256 challengerRewardBps;
        uint256 commitWindow;
        uint256 revealWindow;
        uint256 challengeWindow;
        uint256 courtDeadline;
        uint256 exitDelay;
    }

    struct ArmInfo {
        uint256 bond;
        uint256 locked;
        address signer;
        bool exiting;
        uint64 exitAt;
        bool inactive;
        uint64 deactivatedAt;
        uint32 strikes;
    }

    struct Job {
        bytes32 formId;
        uint256 targetChainId;
        address target;
        uint256 atBlock;
        uint256 feePerArm;
        address poster;
        uint8 keyCount;
        uint8 needed;
        Phase phase;
        uint64 openSince;
        uint64 deadline;
        uint64 challengeEnd;
        uint256 seedBlock;
        uint256 drawNonce;
        uint256 drawSeed;
        uint256 postedBlock;
        uint256 serverCount;
        uint256 escrow;
        uint256 spent;
        bool overturned;
        bool slashedOnce;
        bool rewardPaid;
        bool released;
        uint256 reward;
        uint256 openChallenges;
        uint256 challengesOpened;
        address tieBreaker;
        uint32 disputedMask;
        uint8 disputedCount;
    }

    struct Entry {
        bytes32 commitHash;
        bool committed;
        bool revealed;
        string evidence;
    }

    struct KeyResult {
        bytes32 value;
        Status status;
    }

    struct Challenge {
        uint256 jobId;
        uint8 key;
        bytes32 claimedValue;
        address challenger;
        uint256 stake;
        uint64 openedAt;
        bool exists;
        bool resolved;
        ICourt.Ruling ruling;
    }

    struct Verdict {
        bytes32[] values;
        Status[] statuses;
        uint256 feePerArm;
        bool overturned;
        uint64 challengeEnd;
        uint256 atBlock;
        address[] arms;
        string[] evidence;
        address tieBreaker;
        string tieEvidence;
        Phase phase;
    }

    // ---- errors ----

    error BadParams();
    error ZeroAmount();
    error BondCap();
    error NotExiting();
    error AlreadyExiting();
    error ExitDelay();
    error NotInactive();
    error Cooldown();
    error InsufficientBond();
    error FormExists();
    error BadForm();
    error UnknownForm();
    error FeeTooLow();
    error ChainNotAllowed();
    error BadTarget();
    error WrongPhase();
    error TooEarly();
    error TooLate();
    error SeedExpired();
    error NotOnJob();
    error AlreadyCommitted();
    error NotCommitted();
    error AlreadyRevealed();
    error BadReveal();
    error BadLength();
    error NotPending();
    error NotChallengeable();
    error SameValue();
    error ChallengeExists();
    error UnknownChallenge();
    error AlreadyResolved();
    error CourtPending();
    error CourtFee();
    error StillLocked();
    error AlreadyReleased();
    error TokenCallFailed();

    // ---- events ----

    event Bonded(address indexed arm, uint256 amount, uint256 bond);
    event ExitRequested(address indexed arm, uint64 exitAt);
    event Withdrawn(address indexed arm, uint256 amount);
    event SignerSet(address indexed arm, address indexed signer);
    event Struck(address indexed arm, uint32 strikes, bool deactivated);
    event Reactivated(address indexed arm);
    event FormRegistered(bytes32 indexed formId, uint8 keyCount, string uri);
    event Serving(bytes32 indexed formId, address indexed arm, uint256 minFee);
    event StoppedServing(bytes32 indexed formId, address indexed arm);
    event Posted(uint256 indexed jobId, bytes32 indexed formId, address indexed poster, uint256 feePerArm);
    event Drawn(uint256 indexed jobId, address indexed arm, bool tieBreaker);
    event Replaced(uint256 indexed jobId, address indexed arm);
    event Cancelled(uint256 indexed jobId);
    event Committed(uint256 indexed jobId, address indexed arm);
    event Revealed(uint256 indexed jobId, address indexed arm);
    event TieBreakOpened(uint256 indexed jobId, uint32 disputedMask);
    event Paid(uint256 indexed jobId, address indexed arm, uint256 amount, uint256 burned);
    event Settled(uint256 indexed jobId, uint256 spent, uint256 returned);
    event Challenged(
        uint256 indexed jobId, uint8 key, bytes32 claimedValue, address indexed challenger, bytes32 caseId
    );
    event Resolved(uint256 indexed jobId, uint8 key, bytes32 claimedValue, ICourt.Ruling ruling);
    event Slashed(uint256 indexed jobId, address indexed arm, uint256 amount);
    event RewardPaid(uint256 indexed jobId, address indexed challenger, uint256 amount);
    event Released(uint256 indexed jobId);
    event NoShowCompensation(uint256 indexed jobId, address indexed arm, uint256 amount);
    /// @dev Emitted once at deploy, so every immutable parameter is readable from the logs.
    event Deployed(Params params);

    // ---- constants and immutables ----

    bytes32 public constant UNKNOWN = keccak256("ARMS_UNKNOWN");
    bytes32 public constant NOT_APPLICABLE = keccak256("ARMS_NOT_APPLICABLE");
    uint256 internal constant MAX_URI_BYTES = 200;
    uint256 internal constant BPS = 10_000;
    /// @dev `Number.MAX_SAFE_INTEGER`: the largest block number the court's question can carry.
    uint256 internal constant MAX_BLOCK = 9_007_199_254_740_991;
    /// @dev The oracle accepts an absolute window only when its closing block is five deep.
    uint256 public constant MIN_BLOCK_DEPTH = 5;

    IBurnableToken public immutable token;
    ICourt public immutable court;
    uint256 internal immutable trancheMultiple;
    uint256 public constant stakeMultiple = 2;
    uint256 public immutable minBond;
    uint256 internal immutable minFeePerArm;
    uint256 internal immutable maxBondPerArm;
    uint256 internal immutable maxTotalBonded;
    uint256 internal immutable burnBps;
    uint256 internal immutable challengerRewardBps;
    uint256 public constant spotCheckOneIn = 10;
    uint256 internal immutable commitWindow;
    uint256 internal immutable revealWindow;
    uint256 public constant fillDeadline = 1 days;
    uint256 internal immutable challengeWindow;
    uint256 internal immutable courtDeadline;
    uint256 internal immutable exitDelay;
    uint256 public constant strikesToDeactivate = 3;
    uint256 public constant strikeCooldown = 1 days;
    bool internal immutable arbitrumBlocks;

    uint256 public constant MAX_DRAW_TRIES = 32;

    // ---- storage ----

    mapping(address => ArmInfo) public arms;
    // Changes that make an arm newly eligible (first activation, a cancelled exit, reactivation) and
    // penalties (strikes, slashes) invalidate older snapshots. Everything else is prospective by job
    // id: a bond top-up, a serve, a fee change, an exit or a stop apply to jobs posted after them and
    // never to a job whose draw seed may already be visible. The registry keeps the per-job history.
    mapping(address => uint256) public lastStateChange;
    mapping(address => uint256) public exitAfterJob;
    uint256 public totalBonded;
    uint256 public totalEscrow;
    uint256 public totalStakes;
    uint256 public totalRewards;

    ArmsForms public immutable formRegistry;
    ArmsResults public immutable resultCalculator;

    uint256 public jobCount;
    mapping(uint256 => Job) public jobs;
    mapping(uint256 => address[]) internal jobArms;
    mapping(uint256 => mapping(address => Entry)) public entries;
    mapping(uint256 => mapping(address => mapping(uint8 => bytes32))) public answerOf;
    mapping(uint256 => mapping(address => bool)) public wasDrawn;
    mapping(uint256 => mapping(address => bool)) public slashedIn;
    mapping(uint256 => mapping(uint8 => KeyResult)) public results;
    mapping(bytes32 => Challenge) public challenges;
    mapping(uint256 => mapping(address => mapping(bytes32 => uint256))) public latestJob;

    constructor(
        address token_,
        address court_,
        uint256 minFeePerArm_,
        uint256 maxBondPerArm_,
        uint256 maxTotalBonded_,
        uint256 trancheMultiple_,
        uint256 burnBps_,
        uint256 challengerRewardBps_,
        uint256 commitWindow_,
        uint256 revealWindow_,
        uint256 challengeWindow_,
        uint256 courtDeadline_,
        uint256 exitDelay_
    ) {
        uint256 minimum = 2 * trancheMultiple_ * minFeePerArm_;
        if (
            token_ == address(0) || court_ == address(0) || trancheMultiple_ < 3 || minFeePerArm_ == 0
                || maxBondPerArm_ < minimum || maxTotalBonded_ < maxBondPerArm_ || burnBps_ > BPS
                || challengerRewardBps_ > BPS || commitWindow_ == 0 || revealWindow_ == 0 || challengeWindow_ == 0
                || courtDeadline_ == 0 || commitWindow_ > type(uint64).max - block.timestamp
                || revealWindow_ > type(uint64).max - block.timestamp
                || challengeWindow_ > type(uint64).max - block.timestamp
                || courtDeadline_ > type(uint64).max - block.timestamp
                || exitDelay_ > type(uint64).max - block.timestamp
        ) revert BadParams();
        token = IBurnableToken(token_);
        court = ICourt(court_);
        minFeePerArm = minFeePerArm_;
        minBond = minimum;
        maxBondPerArm = maxBondPerArm_;
        maxTotalBonded = maxTotalBonded_;
        trancheMultiple = trancheMultiple_;
        burnBps = burnBps_;
        challengerRewardBps = challengerRewardBps_;
        commitWindow = commitWindow_;
        revealWindow = revealWindow_;
        challengeWindow = challengeWindow_;
        courtDeadline = courtDeadline_;
        exitDelay = exitDelay_;
        arbitrumBlocks = Blocks.isArbitrum();
        formRegistry = new ArmsForms(address(this), minFeePerArm_);
        resultCalculator = new ArmsResults();
        emit Deployed(Params(
                token_,
                court_,
                minFeePerArm_,
                maxBondPerArm_,
                maxTotalBonded_,
                trancheMultiple_,
                burnBps_,
                challengerRewardBps_,
                commitWindow_,
                revealWindow_,
                challengeWindow_,
                courtDeadline_,
                exitDelay_
            ));
    }

    // =====================================================================
    // Arms and bonds
    // =====================================================================

    function bond(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        ArmInfo storage a = arms[msg.sender];
        if (a.bond + amount > maxBondPerArm || totalBonded + amount > maxTotalBonded) revert BondCap();
        // Only a top-up that makes the arm newly active (first bond above `minBond`) invalidates older
        // jobs. An already active arm's top-up counts for later jobs only, and so does a top-up that
        // cancels an exit: the arm stays eligible for the jobs it was drawn-eligible for when it asked to
        // exit, and the zero bond checkpointed while it was exiting keeps it out of the jobs posted in
        // between. So an arm can neither opt in to nor opt out of a job whose seed is already visible.
        bool wasActive = isActive(msg.sender);
        bool rejoin = a.exiting;
        a.bond += amount;
        if (!wasActive && !rejoin) lastStateChange[msg.sender] = Blocks.number(arbitrumBlocks);
        totalBonded += amount;
        if (rejoin) {
            a.exiting = false;
            a.exitAt = 0;
        }
        _checkpointBond(msg.sender);
        _pull(msg.sender, amount);
        emit Bonded(msg.sender, amount, a.bond);
    }

    /// @notice Stops draws for jobs posted later; `withdraw` opens after `exitDelay`. Bonding again cancels it.
    function requestExit() external {
        ArmInfo storage a = arms[msg.sender];
        if (a.exiting) revert AlreadyExiting();
        a.exiting = true;
        exitAfterJob[msg.sender] = jobCount;
        a.exitAt = uint64(block.timestamp + exitDelay);
        // Jobs posted from here until the exit is cancelled read a zero bond, permanently.
        _checkpointBond(msg.sender);
        emit ExitRequested(msg.sender, a.exitAt);
    }

    /// @notice Pays out the unlocked bond to the arm address after `exitDelay`.
    function withdraw() external {
        ArmInfo storage a = arms[msg.sender];
        if (!a.exiting) revert NotExiting();
        if (block.timestamp < a.exitAt) revert ExitDelay();
        uint256 amount = a.bond - a.locked;
        if (amount == 0) revert ZeroAmount();
        a.bond -= amount;
        lastStateChange[msg.sender] = Blocks.number(arbitrumBlocks);
        totalBonded -= amount;
        _checkpointBond(msg.sender);
        _send(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Names a signer that may only `commit` and `reveal` for this arm. Zero clears it.
    function setSigner(address signer) external {
        ArmInfo storage a = arms[msg.sender];
        a.signer = signer;
        emit SignerSet(msg.sender, signer);
    }

    function reactivate() external {
        ArmInfo storage a = arms[msg.sender];
        if (!a.inactive) revert NotInactive();
        if (block.timestamp < uint256(a.deactivatedAt) + strikeCooldown) revert Cooldown();
        a.inactive = false;
        lastStateChange[msg.sender] = Blocks.number(arbitrumBlocks);
        a.strikes = 0;
        emit Reactivated(msg.sender);
    }

    function unlockedBond(address arm) public view returns (uint256) {
        ArmInfo storage a = arms[arm];
        return a.bond - a.locked;
    }

    function isActive(address arm) public view returns (bool) {
        ArmInfo storage a = arms[arm];
        return a.bond >= minBond && !a.exiting && !a.inactive;
    }

    // =====================================================================
    // Forms
    // =====================================================================

    /// @notice The id commits to the text hash, key count and URI together.
    function registerForm(bytes32 textHash, uint8 keyCount, string calldata uri) external returns (bytes32 formId) {
        formId = formRegistry.register(textHash, keyCount, uri);
        emit FormRegistered(formId, keyCount, uri);
    }

    /// @notice Lists the arm for the form, or changes its fee, for jobs posted from now on. Jobs already
    /// posted keep seeing the fee (or the absence) the arm advertised when they were posted.
    function serve(bytes32 formId, uint256 minFee) external {
        if (arms[msg.sender].bond < minBond) revert InsufficientBond();
        formRegistry.serve(formId, msg.sender, minFee, jobCount);
        emit Serving(formId, msg.sender, minFee);
    }

    function stopServing(bytes32 formId) external {
        formRegistry.stop(formId, msg.sender, Blocks.number(arbitrumBlocks), jobCount);
        emit StoppedServing(formId, msg.sender);
    }

    // =====================================================================
    // Jobs
    // =====================================================================

    function post(bytes32 formId, uint256 targetChainId, address target, uint256 atBlock, uint256 feePerArm)
        external
        returns (uint256 jobId)
    {
        (uint8 keyCount, uint256 serverCount) = formRegistry.info(formId);
        if (keyCount == 0) revert UnknownForm();
        if (feePerArm < minFeePerArm) revert FeeTooLow();
        if (!chainAllowed(targetChainId)) revert ChainNotAllowed();
        if (target == address(0) || atBlock == 0 || atBlock > MAX_BLOCK) revert BadTarget();
        uint256 postedBlock = Blocks.number(arbitrumBlocks);
        // `atBlock` must be at least MIN_BLOCK_DEPTH below a head this chain can vouch for: its own
        // height for a local target, the court's published confirmed head for a remote one (zero until
        // the court publishes one, so a remote target without a head is refused).
        uint256 head = targetChainId == block.chainid ? postedBlock : court.confirmedHead(targetChainId);
        if (atBlock + MIN_BLOCK_DEPTH > head) revert BadTarget();
        jobId = ++jobCount;
        Job storage j = jobs[jobId];
        j.formId = formId;
        j.targetChainId = targetChainId;
        j.target = target;
        j.atBlock = atBlock;
        j.feePerArm = feePerArm;
        j.poster = msg.sender;
        j.keyCount = keyCount;
        j.escrow = 3 * feePerArm;
        j.postedBlock = postedBlock;
        j.serverCount = serverCount;
        _reopen(j, Phase.OPEN);
        totalEscrow += j.escrow;
        _pull(msg.sender, j.escrow);
        emit Posted(jobId, formId, msg.sender, feePerArm);
    }

    /// @notice At most MAX_DRAW_TRIES attempts over the posting-time list length, with stable indices.
    /// Skips ineligible entries without rebuilding the list. Repeated calls continue the same sequence.
    /// @dev One opening has one seed: the hash of `seedBlock`, fixed when the job was posted or
    /// reopened and saved by the first call. If nobody draws while the chain still serves that hash
    /// (256 blocks), the opening can no longer be drawn: no other block is ever substituted, because
    /// the caller would know its hash before sending. An OPEN job is then refunded by `cancel`, and a
    /// tie break is closed by `settle`, both after `fillDeadline`.
    function draw(uint256 jobId) external {
        Job storage j = jobs[jobId];
        if (j.phase != Phase.OPEN && j.phase != Phase.TIE_OPEN) revert WrongPhase();
        if (block.timestamp > uint256(j.openSince) + fillDeadline) revert TooLate();
        if (j.drawSeed == 0) {
            uint256 n = Blocks.number(arbitrumBlocks);
            if (n <= j.seedBlock) revert TooEarly();
            bytes32 h = Blocks.hash(j.seedBlock, arbitrumBlocks);
            if (h == bytes32(0)) revert SeedExpired();
            j.drawSeed = uint256(keccak256(abi.encode(h, jobId, uint256(0))));
        }
        bool tie = j.phase == Phase.TIE_OPEN;
        if (!tie && j.needed == 0) j.needed = j.drawSeed % spotCheckOneIn == 0 ? 3 : 2;
        if (j.serverCount == 0) return;
        for (uint256 i; i < MAX_DRAW_TRIES; ++i) {
            uint256 idx = uint256(keccak256(abi.encode(j.drawSeed, j.drawNonce++))) % j.serverCount;
            address a = formRegistry.candidate(j.formId, idx, jobId, j.feePerArm);
            if (!_eligible(jobId, j, a)) continue;
            _assign(jobId, j, a, tie);
            if (tie) {
                j.tieBreaker = a;
                j.phase = Phase.TIE_COMMIT;
            } else {
                jobArms[jobId].push(a);
                if (jobArms[jobId].length != j.needed) continue;
                j.phase = Phase.COMMIT;
            }
            j.deadline = uint64(block.timestamp + commitWindow);
            return;
        }
    }

    /// @notice Refunds a job that was not filled by `fillDeadline`, including one whose seed expired
    /// before anyone drew. Arms already drawn for it are unlocked.
    function cancel(uint256 jobId) external {
        Job storage j = jobs[jobId];
        if (j.phase != Phase.OPEN) revert WrongPhase();
        if (block.timestamp <= uint256(j.openSince) + fillDeadline) revert TooEarly();
        uint256 tranche = trancheMultiple * j.feePerArm;
        for (uint256 i; i < jobArms[jobId].length; ++i) {
            arms[jobArms[jobId][i]].locked -= tranche;
        }
        delete jobArms[jobId];
        j.phase = Phase.CANCELLED;
        uint256 refund = j.escrow;
        j.escrow = 0;
        totalEscrow -= refund;
        _send(j.poster, refund);
        emit Cancelled(jobId);
    }

    /// @notice `hash = keccak256(abi.encode(jobId, arm, values, salt))`, by the arm or its signer.
    function commit(uint256 jobId, address arm, bytes32 hash) external {
        Job storage j = jobs[jobId];
        _checkActor(jobId, j, arm);
        bool tie = arm == j.tieBreaker;
        if (tie ? j.phase != Phase.TIE_COMMIT : j.phase != Phase.COMMIT) revert WrongPhase();
        if (block.timestamp > j.deadline) revert TooLate();
        Entry storage e = entries[jobId][arm];
        if (e.committed) revert AlreadyCommitted();
        e.committed = true;
        e.commitHash = hash;
        emit Committed(jobId, arm);
        if (tie) {
            j.phase = Phase.TIE_REVEAL;
            j.deadline = uint64(block.timestamp + revealWindow);
        } else if (_count(jobId, false) == jobArms[jobId].length) {
            j.phase = Phase.REVEAL;
            j.deadline = uint64(block.timestamp + revealWindow);
        }
    }

    /// @notice One value per key (a tie break arm: one per disputed key, in key order).
    function reveal(uint256 jobId, address arm, bytes32[] calldata values, bytes32 salt, string calldata evidenceURI)
        external
    {
        Job storage j = jobs[jobId];
        _checkActor(jobId, j, arm);
        bool tie = arm == j.tieBreaker;
        if (tie ? j.phase != Phase.TIE_REVEAL : j.phase != Phase.REVEAL) revert WrongPhase();
        if (block.timestamp > j.deadline) revert TooLate();
        Entry storage e = entries[jobId][arm];
        if (!e.committed) revert NotCommitted();
        if (e.revealed) revert AlreadyRevealed();
        if (keccak256(abi.encode(jobId, arm, values, salt)) != e.commitHash) revert BadReveal();
        if (bytes(evidenceURI).length > MAX_URI_BYTES) revert BadLength();
        if (tie) {
            if (values.length != j.disputedCount) revert BadLength();
            uint256 v;
            for (uint8 k; k < j.keyCount; ++k) {
                if (j.disputedMask & (uint32(1) << k) != 0) answerOf[jobId][arm][k] = values[v++];
            }
        } else {
            if (values.length != j.keyCount) revert BadLength();
            for (uint8 k; k < j.keyCount; ++k) {
                answerOf[jobId][arm][k] = values[k];
            }
        }
        e.revealed = true;
        e.evidence = evidenceURI;
        emit Revealed(jobId, arm);
    }

    /// @notice Replace no-shows only while every answer remains sealed. Once an answer is public,
    /// close the job and compensate timely revealers from the no-shows' locked tranches.
    function timeout(uint256 jobId) external {
        Job storage j = jobs[jobId];
        if (block.timestamp <= j.deadline) revert TooEarly();
        if (j.phase == Phase.COMMIT || j.phase == Phase.REVEAL) {
            bool needReveal = j.phase == Phase.REVEAL;
            if (needReveal) {
                uint256 revealed = _count(jobId, true);
                if (revealed == jobArms[jobId].length) revert NotPending();
                if (revealed != 0) {
                    _closeNoShow(jobId, j);
                    return;
                }
            }
            uint256 tranche = trancheMultiple * j.feePerArm;
            uint256 removed;
            uint256 i;
            while (i < jobArms[jobId].length) {
                address a = jobArms[jobId][i];
                Entry storage e = entries[jobId][a];
                if (needReveal ? e.revealed : e.committed) {
                    ++i;
                    continue;
                }
                arms[a].locked -= tranche;
                _strike(a);
                jobArms[jobId][i] = jobArms[jobId][jobArms[jobId].length - 1];
                jobArms[jobId].pop();
                ++removed;
                emit Replaced(jobId, a);
            }
            if (removed == 0) revert NotPending();
            _reopen(j, Phase.OPEN);
        } else if (j.phase == Phase.TIE_COMMIT || j.phase == Phase.TIE_REVEAL) {
            if (entries[jobId][j.tieBreaker].revealed) revert NotPending();
            // Main answers are already public, so a missing tie breaker cannot be replaced either.
            _closeNoShow(jobId, j);
        } else {
            revert WrongPhase();
        }
    }

    /// @dev Voter `i` of a job: a main arm, then the tie breaker if one was drawn.
    function _voter(uint256 jobId, Job storage j, uint256 i) internal view returns (address) {
        return i < jobArms[jobId].length ? jobArms[jobId][i] : j.tieBreaker;
    }

    function _closeNoShow(uint256 jobId, Job storage j) internal {
        uint256 voters = jobArms[jobId].length + (j.tieBreaker != address(0) ? 1 : 0);
        uint256 revealed;
        for (uint256 i; i < voters; ++i) {
            if (entries[jobId][_voter(jobId, j, i)].revealed) ++revealed;
        }
        uint256 missing = voters - revealed;
        uint256 compensation = revealed * j.feePerArm;
        uint256 share = compensation / missing;
        uint256 dust = compensation % missing;
        uint256 tranche = trancheMultiple * j.feePerArm;
        for (uint256 i; i < voters; ++i) {
            address a = _voter(jobId, j, i);
            arms[a].locked -= tranche;
            if (!entries[jobId][a].revealed) {
                uint256 loss = share + dust;
                dust = 0;
                arms[a].bond -= loss;
                totalBonded -= loss;
                _checkpointBond(a);
                _strike(a);
                emit NoShowCompensation(jobId, a, loss);
            }
        }
        for (uint8 k; k < j.keyCount; ++k) {
            results[jobId][k] = KeyResult(bytes32(0), Status.UNRESOLVED);
        }
        j.phase = Phase.SETTLED;
        j.released = true;
        j.challengeEnd = uint64(block.timestamp);
        // Not recorded as the target's latest verdict: this job carries no answer, and one arm that
        // stays silent must not be able to replace an earlier verdict with nothing.
        uint256 refund = j.escrow;
        j.escrow = 0;
        totalEscrow -= refund;
        // Compensation is one full fee, without a burn: it is not an adjudicated answer payment.
        for (uint256 i; i < voters; ++i) {
            address a = _voter(jobId, j, i);
            if (entries[jobId][a].revealed) {
                _send(a, j.feePerArm);
                emit Paid(jobId, a, j.feePerArm, 0);
            }
        }
        _send(j.poster, refund);
        emit Settled(jobId, 0, refund);
    }

    /// @notice Settles a job whose arms have all revealed: pays, burns, returns the rest of the escrow,
    /// or opens a tie break where two arms differ. A tie break nobody could be drawn for by
    /// `fillDeadline` settles with its disputed keys UNRESOLVED.
    function settle(uint256 jobId) external {
        Job storage j = jobs[jobId];
        if (j.phase == Phase.REVEAL) {
            if (_count(jobId, true) != jobArms[jobId].length) revert NotPending();
            (uint32 mask, uint8 count) = resultCalculator.disputes(jobId);
            if (mask != 0 && j.needed == 2) {
                j.disputedMask = mask;
                j.disputedCount = count;
                _reopen(j, Phase.TIE_OPEN);
                emit TieBreakOpened(jobId, mask);
                return;
            }
            _finalize(jobId, j, false);
        } else if (j.phase == Phase.TIE_REVEAL) {
            if (!entries[jobId][j.tieBreaker].revealed) revert NotPending();
            _finalize(jobId, j, true);
        } else if (j.phase == Phase.TIE_OPEN) {
            if (block.timestamp <= uint256(j.openSince) + fillDeadline) revert TooEarly();
            _finalize(jobId, j, false);
        } else {
            revert WrongPhase();
        }
    }

    /// @notice Unlocks the tranches of a settled job once its challenge window has closed with no
    /// challenge open, and burns a reward nobody earned.
    function release(uint256 jobId) external {
        Job storage j = jobs[jobId];
        if (j.phase != Phase.SETTLED) revert WrongPhase();
        if (j.released) revert AlreadyReleased();
        if (block.timestamp <= j.challengeEnd || j.openChallenges != 0) revert StillLocked();
        j.released = true;
        uint256 tranche = trancheMultiple * j.feePerArm;
        uint256 voters = jobArms[jobId].length + (j.tieBreaker != address(0) ? 1 : 0);
        for (uint256 i; i < voters; ++i) {
            address a = _voter(jobId, j, i);
            if (!slashedIn[jobId][a]) arms[a].locked -= tranche;
        }
        if (!j.rewardPaid && j.reward > 0) _burnReward(j);
        emit Released(jobId);
    }

    // =====================================================================
    // Challenges
    // =====================================================================

    function caseIdOf(uint256 jobId, uint8 key, bytes32 claimedValue) public pure returns (bytes32) {
        return keccak256(abi.encode(jobId, key, claimedValue));
    }

    /// @notice Disputes an AGREED or MAJORITY key inside the challenge window. Pulls the stake (in the
    /// bond token) and the court's fee (in the court's asset) from the caller and opens a court case.
    function challenge(uint256 jobId, uint8 key, bytes32 claimedValue, uint256 maxCourtFee)
        external
        returns (bytes32 caseId)
    {
        Job storage j = jobs[jobId];
        if (j.phase != Phase.SETTLED) revert WrongPhase();
        if (block.timestamp > j.challengeEnd) revert TooLate();
        if (key >= j.keyCount) revert BadLength();
        KeyResult storage r = results[jobId][key];
        if (r.status != Status.AGREED && r.status != Status.MAJORITY) revert NotChallengeable();
        if (claimedValue == r.value || claimedValue == UNKNOWN) revert SameValue();
        caseId = caseIdOf(jobId, key, claimedValue);
        if (challenges[caseId].exists) revert ChallengeExists();

        uint256 stake = stakeMultiple * j.feePerArm;
        challenges[caseId] = Challenge({
            jobId: jobId,
            key: key,
            claimedValue: claimedValue,
            challenger: msg.sender,
            stake: stake,
            openedAt: uint64(block.timestamp),
            exists: true,
            resolved: false,
            ruling: ICourt.Ruling.NONE
        });
        ++j.openChallenges;
        ++j.challengesOpened;
        totalStakes += stake;
        _pull(msg.sender, stake);

        uint256 courtFee = court.fee();
        if (courtFee > maxCourtFee) revert CourtFee();
        if (courtFee > 0) {
            IERC20 asset = IERC20(court.feeAsset());
            if (!asset.transferFrom(msg.sender, address(this), courtFee)) revert TokenCallFailed();
            if (!asset.approve(address(court), courtFee)) revert TokenCallFailed();
        }
        (, string memory formURI) = formRegistry.forms(j.formId);
        court.ask(
            caseId,
            j.formId,
            formURI,
            key,
            j.targetChainId,
            j.target,
            j.atBlock,
            r.value,
            claimedValue,
            msg.sender,
            maxCourtFee
        );
        emit Challenged(jobId, key, claimedValue, msg.sender, caseId);
    }

    /// @notice Applies the court's ruling, or closes the case with no ruling after `courtDeadline`.
    function resolve(uint256 jobId, uint8 key, bytes32 claimedValue) external {
        bytes32 caseId = caseIdOf(jobId, key, claimedValue);
        Challenge storage c = challenges[caseId];
        if (!c.exists) revert UnknownChallenge();
        if (c.resolved) revert AlreadyResolved();
        Job storage j = jobs[jobId];
        ICourt.Ruling r = court.ruling(caseId);
        if (r == ICourt.Ruling.NONE && block.timestamp <= uint256(c.openedAt) + courtDeadline) revert CourtPending();
        c.resolved = true;
        c.ruling = r;
        --j.openChallenges;

        KeyResult storage kr = results[jobId][key];
        bool standing = kr.status == Status.AGREED || kr.status == Status.MAJORITY;
        bool stakeBack = true;
        if (r == ICourt.Ruling.CLAIMED || r == ICourt.Ruling.NEITHER) {
            // A CLAIMED ruling also corrects a key an earlier NEITHER ruling overturned: the court has
            // now attested a value for it. `_slash` is idempotent, so the arms are not slashed twice.
            if (standing || (r == ICourt.Ruling.CLAIMED && kr.status == Status.OVERTURNED)) {
                bytes32 stored = kr.value;
                if (r == ICourt.Ruling.CLAIMED) {
                    kr.status = Status.CORRECTED;
                    kr.value = claimedValue;
                } else {
                    kr.status = Status.OVERTURNED;
                }
                j.overturned = true;
                _slash(jobId, j, key, stored);
            }
            if (r == ICourt.Ruling.CLAIMED && !j.rewardPaid && j.reward > 0) {
                uint256 reward = j.reward;
                j.rewardPaid = true;
                j.reward = 0;
                totalRewards -= reward;
                _send(c.challenger, reward);
                emit RewardPaid(jobId, c.challenger, reward);
            }
        } else if (r == ICourt.Ruling.STORED && standing) {
            // Gated on this key, not on the job: a challenger ruled wrong forfeits the stake whatever
            // happened on other keys and in whatever order the cases are resolved. The stake goes to
            // the arms that gave the value and were not slashed on another key; with none left it burns.
            stakeBack = false;
            _splitStake(jobId, j, key, kr.value, c.stake);
        }
        totalStakes -= c.stake;
        if (stakeBack) _send(c.challenger, c.stake);
        if (j.openChallenges == 0 && block.timestamp > j.challengeEnd && !j.rewardPaid && j.reward > 0) {
            _burnReward(j);
        }
        emit Resolved(jobId, key, claimedValue, r);
    }

    // =====================================================================
    // Reads
    // =====================================================================

    function verdict(uint256 jobId) public view returns (Verdict memory) {
        return resultCalculator.verdict(jobId);
    }

    /// @notice The last job for a target under a form that settled with at least one AGREED or MAJORITY
    /// key and whose `atBlock` is not below the previous one's. A job with no answer, or one about an
    /// older block than the verdict already recorded, never replaces it. `jobId` zero means none.
    function latest(uint256 targetChainId, address target, bytes32 formId)
        external
        view
        returns (uint256 jobId, Verdict memory v)
    {
        jobId = latestJob[targetChainId][target][formId];
        if (jobId != 0) v = verdict(jobId);
    }

    function armsOf(uint256 jobId) external view returns (address[] memory) {
        return jobArms[jobId];
    }

    function chainAllowed(uint256 chainId) public view returns (bool) {
        return court.supportsChain(chainId);
    }

    // =====================================================================
    // Internals
    // =====================================================================

    function _pull(address from, uint256 amount) internal {
        if (!token.transferFrom(from, address(this), amount)) revert TokenCallFailed();
    }

    function _send(address to, uint256 amount) internal {
        if (!token.transfer(to, amount)) revert TokenCallFailed();
    }

    function _reopen(Job storage j, Phase phase) internal {
        j.phase = phase;
        j.openSince = uint64(block.timestamp);
        j.seedBlock = Blocks.number(arbitrumBlocks) + 1;
        j.deadline = 0;
        j.drawSeed = 0;
        j.drawNonce = 0;
    }

    function _assign(uint256 jobId, Job storage j, address a, bool tie) internal {
        wasDrawn[jobId][a] = true;
        arms[a].locked += trancheMultiple * j.feePerArm;
        emit Drawn(jobId, a, tie);
    }

    /// @dev Records the arm's bond for jobs posted after this change; `_eligible` reads the bond an arm
    /// had when the job was posted. An exiting arm records zero, whatever it holds, so every job posted
    /// while it was exiting stays closed to it after a rejoin, however many exits it goes through.
    function _checkpointBond(address a) internal {
        ArmInfo storage s = arms[a];
        formRegistry.noteBond(a, jobCount, s.exiting ? 0 : s.bond);
    }

    function _eligible(uint256 jobId, Job storage j, address a) internal view returns (bool) {
        // The zero address (`candidate` returned none) fails the bond check below like any stranger.
        if (a == j.poster || wasDrawn[jobId][a] || lastStateChange[a] >= j.postedBlock) return false;
        ArmInfo storage s = arms[a];
        if (s.inactive || (s.exiting && exitAfterJob[a] < jobId)) return false;
        // The bond counted is the smaller of the bond at posting time and the bond now: a top-up after
        // the post does not count, a loss after it does.
        uint256 b = formRegistry.bondAsOf(a, jobId);
        if (s.bond < b) b = s.bond;
        return b >= minBond && b >= s.locked + trancheMultiple * j.feePerArm;
    }

    function _checkActor(uint256 jobId, Job storage j, address arm) internal view {
        if (!_onJob(jobId, j, arm) || (msg.sender != arm && msg.sender != arms[arm].signer)) revert NotOnJob();
    }

    function _onJob(uint256 jobId, Job storage j, address a) internal view returns (bool) {
        if (a == address(0) || !wasDrawn[jobId][a]) return false;
        if (a == j.tieBreaker) return true;
        for (uint256 i; i < jobArms[jobId].length; ++i) {
            if (jobArms[jobId][i] == a) return true;
        }
        return false;
    }

    /// @dev How many main arms have revealed (`revealed`) or committed.
    function _count(uint256 jobId, bool revealed) internal view returns (uint256 n) {
        for (uint256 i; i < jobArms[jobId].length; ++i) {
            Entry storage e = entries[jobId][jobArms[jobId][i]];
            if (revealed ? e.revealed : e.committed) ++n;
        }
    }

    /// @dev Burns the job's unearned challenger reward.
    function _burnReward(Job storage j) internal {
        uint256 r = j.reward;
        j.reward = 0;
        totalRewards -= r;
        token.burn(r);
    }

    function _strike(address a) internal {
        ArmInfo storage s = arms[a];
        ++s.strikes;
        lastStateChange[a] = Blocks.number(arbitrumBlocks);
        bool deactivated = !s.inactive && s.strikes >= strikesToDeactivate;
        if (deactivated) {
            s.inactive = true;
            s.deactivatedAt = uint64(block.timestamp);
        }
        emit Struck(a, s.strikes, deactivated);
    }

    function _finalize(uint256 jobId, Job storage j, bool withTie) internal {
        ArmsResults.Outcome memory o = resultCalculator.settlement(jobId, withTie);
        bool answered;
        for (uint8 k; k < j.keyCount; ++k) {
            results[jobId][k] = KeyResult(o.values[k], o.statuses[k]);
            if (o.statuses[k] == Status.AGREED || o.statuses[k] == Status.MAJORITY) answered = true;
        }
        for (uint256 i; i < jobArms[jobId].length; ++i) {
            _pay(jobId, j, jobArms[jobId][i], o.payments[i]);
        }
        if (withTie) _pay(jobId, j, j.tieBreaker, o.tiePayment);
        uint256 back = j.escrow;
        j.escrow = 0;
        totalEscrow -= back;
        j.phase = Phase.SETTLED;
        j.challengeEnd = uint64(block.timestamp + challengeWindow);
        // Only a job that carries an answer, about a block no older than the recorded verdict's,
        // becomes the target's latest: an arm answering UNKNOWN everywhere, an unfilled tie break or
        // a reading at an old block cannot erase what readers already have.
        uint256 prev = latestJob[j.targetChainId][j.target][j.formId];
        if (answered && (prev == 0 || jobs[prev].atBlock <= j.atBlock)) {
            latestJob[j.targetChainId][j.target][j.formId] = jobId;
        }
        if (back > 0) _send(j.poster, back);
        emit Settled(jobId, j.spent, back);
    }

    function _pay(uint256 jobId, Job storage j, address arm, uint256 amount) internal {
        if (amount == 0) return;
        uint256 burned = amount * burnBps / BPS;
        j.escrow -= amount;
        j.spent += amount;
        totalEscrow -= amount;
        if (burned > 0) token.burn(burned);
        if (amount > burned) _send(arm, amount - burned);
        emit Paid(jobId, arm, amount, burned);
    }

    /// @dev Slashes every voter that gave `stored` on `key` and was not slashed in this job before.
    function _slash(uint256 jobId, Job storage j, uint8 key, bytes32 stored) internal {
        uint256 tranche = trancheMultiple * j.feePerArm;
        address[] memory givers = resultCalculator.givers(jobId, key, stored);
        for (uint256 i; i < givers.length; ++i) {
            address a = givers[i];
            slashedIn[jobId][a] = true;
            arms[a].bond -= tranche;
            lastStateChange[a] = Blocks.number(arbitrumBlocks);
            arms[a].locked -= tranche;
            _checkpointBond(a);
            emit Slashed(jobId, a, tranche);
        }
        uint256 total = givers.length * tranche;
        if (total == 0) return;
        totalBonded -= total;
        if (!j.slashedOnce) {
            j.slashedOnce = true;
            uint256 refund = total < j.spent ? total : j.spent;
            uint256 rest = total - refund;
            uint256 reward = rest * challengerRewardBps / BPS;
            j.reward += reward;
            totalRewards += reward;
            if (rest - reward > 0) token.burn(rest - reward);
            if (refund > 0) _send(j.poster, refund);
        } else {
            token.burn(total);
        }
    }

    /// @dev Splits a forfeited stake among the unslashed voters that gave `stored`; burns it with none.
    function _splitStake(uint256 jobId, Job storage, uint8 key, bytes32 stored, uint256 stake) internal {
        address[] memory givers = resultCalculator.givers(jobId, key, stored);
        uint256 g = givers.length;
        if (g == 0) {
            token.burn(stake);
            return;
        }
        uint256 share = stake / g;
        uint256 dust = stake - share * g;
        for (uint256 i; i < g; ++i) {
            _send(givers[i], share + (i == 0 ? dust : 0));
        }
    }
}
