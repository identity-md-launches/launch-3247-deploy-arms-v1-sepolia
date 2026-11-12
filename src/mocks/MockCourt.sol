// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICourt} from "../ICourt.sol";

/// @title A court anyone can rule for: tests and local demos only
/// @notice Keeps `ICourt`'s rules (fee pulled from the asker, cases namespaced by asker, one case per
/// id) and lets any caller set a ruling with `rule`. Never deploy it as the court of a live `Arms`.
contract MockCourt is ICourt {
    using SafeERC20 for IERC20;

    struct Case {
        address asker;
        address payer;
        bytes32 formId;
        string formURI;
        uint8 key;
        uint256 targetChainId;
        address target;
        uint256 atBlock;
        bytes32 storedValue;
        bytes32 claimedValue;
        Ruling ruling;
        bool exists;
    }

    error CaseExists(bytes32 caseId);
    error FeeAboveMax(uint256 price, uint256 maxFee);

    event CaseOpened(address indexed asker, bytes32 indexed caseId, address payer);
    event Ruled(address indexed asker, bytes32 indexed caseId, Ruling ruling);

    address public immutable feeToken;
    uint256 public immutable price;

    mapping(bytes32 => Case) internal cases;

    /// @param feeToken_ The token the fee is pulled in; zero with `price_` zero for a free court.
    constructor(address feeToken_, uint256 price_) {
        feeToken = feeToken_;
        price = price_;
    }

    function feeAsset() external view returns (address) {
        return feeToken;
    }

    function fee() external view returns (uint256) {
        return price;
    }

    function supportsChain(uint256 chainId) external pure returns (bool) {
        return chainId == 11155111 || chainId == 4663;
    }

    /// @notice Unlike `IMDCourt`, which vouches for nothing until its owner publishes a head, the mock
    /// vouches for the first 2^32 blocks of every chain so local tests can post about any chain. A
    /// test that needs the real behaviour publishes a head (zero included) with `setConfirmedHead`.
    uint256 public constant DEFAULT_HEAD = type(uint32).max;

    mapping(uint256 => uint256) internal heads;
    mapping(uint256 => bool) internal headSet;

    function confirmedHead(uint256 chainId) external view returns (uint256) {
        return headSet[chainId] ? heads[chainId] : DEFAULT_HEAD;
    }

    /// @notice Anyone publishes a head, this is a mock.
    function setConfirmedHead(uint256 chainId, uint256 head) external {
        heads[chainId] = head;
        headSet[chainId] = true;
    }

    function ask(
        bytes32 caseId,
        bytes32 formId,
        string calldata formURI,
        uint8 key,
        uint256 targetChainId,
        address target,
        uint256 atBlock,
        bytes32 storedValue,
        bytes32 claimedValue,
        address payer,
        uint256 maxFee
    ) external {
        bytes32 k = keccak256(abi.encode(msg.sender, caseId));
        if (cases[k].exists) revert CaseExists(caseId);
        if (price > maxFee) revert FeeAboveMax(price, maxFee);
        if (price > 0) IERC20(feeToken).safeTransferFrom(msg.sender, address(this), price);
        cases[k] = Case(
            msg.sender,
            payer,
            formId,
            formURI,
            key,
            targetChainId,
            target,
            atBlock,
            storedValue,
            claimedValue,
            Ruling.NONE,
            true
        );
        emit CaseOpened(msg.sender, caseId, payer);
    }

    function ruling(bytes32 caseId) external view returns (Ruling) {
        return cases[keccak256(abi.encode(msg.sender, caseId))].ruling;
    }

    /// @notice Anyone rules, this is a mock.
    function rule(address asker, bytes32 caseId, Ruling r) external {
        bytes32 k = keccak256(abi.encode(asker, caseId));
        require(cases[k].exists, "no case");
        cases[k].ruling = r;
        emit Ruled(asker, caseId, r);
    }

    function rulingOf(address asker, bytes32 caseId) external view returns (Ruling) {
        return cases[keccak256(abi.encode(asker, caseId))].ruling;
    }

    function caseOf(address asker, bytes32 caseId) external view returns (Case memory) {
        return cases[keccak256(abi.encode(asker, caseId))];
    }
}
