// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Rulings on disputed answers
/// @notice `Arms` opens a case per challenge and later reads its ruling. Cases are namespaced by the
/// asking contract (`msg.sender`), so a stranger cannot pre-occupy a case id and block a challenge.
///
/// Difference from the brief: the court pulls its fee from `msg.sender` (the asking contract), never
/// from an arbitrary `payer`. `Arms` pulls the fee from the challenger itself and approves the court in
/// the same call, so every `transferFrom` moves tokens from the caller that approved them. `payer` is
/// kept in `ask` for the record (events) and `feeAsset`/`fee` let the asker quote the fee first.
interface ICourt {
    enum Ruling {
        NONE,
        STORED,
        CLAIMED,
        NEITHER
    }

    /// @notice The token the court is paid in (zero when it charges nothing).
    function feeAsset() external view returns (address);

    /// @notice The fee the court will pull from `msg.sender` on the next `ask`.
    function fee() external view returns (uint256);

    /// @notice Whether this court accepts questions about the target chain.
    function supportsChain(uint256 chainId) external view returns (bool);

    /// @notice The highest block of a remote target chain the court can vouch for as confirmed; zero
    /// when it has published none. `Arms` only admits a remote `atBlock` at least five blocks below it,
    /// so every question it later asks names a window the oracle can read.
    function confirmedHead(uint256 chainId) external view returns (uint256);

    /// @notice Opens a case. Reverts if the fee is above `maxFee` or the case exists for this asker.
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
    ) external;

    /// @notice The ruling on `msg.sender`'s case `caseId`; `NONE` until the court has ruled.
    function ruling(bytes32 caseId) external view returns (Ruling);
}
