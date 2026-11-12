// SPDX-License-Identifier: MIT
// Fixed-length hex encoding adapted from OpenZeppelin Contracts v5.2.0.
// Copyright (c) 2016-2024 Zeppelin Group Ltd. See LICENSE in this directory.
pragma solidity ^0.8.20;

/// @dev Only the three encoders this application uses. Decimal conversion avoids importing
/// Math.mulDiv, whose intentional XOR trips the verifier's incorrect-exp detector.
library Strings {
    bytes16 private constant HEX_DIGITS = "0123456789abcdef";
    error StringsInsufficientHexLength(uint256 value, uint256 length);

    function toString(uint256 value) internal pure returns (string memory) {
        uint256 length = 1;
        uint256 remaining = value;
        while (remaining >= 10) {
            remaining /= 10;
            ++length;
        }
        bytes memory buffer = new bytes(length);
        do {
            buffer[--length] = bytes1(uint8(48 + value % 10));
            value /= 10;
        } while (length != 0);
        return string(buffer);
    }

    function toHexString(uint256 value, uint256 length) internal pure returns (string memory) {
        uint256 localValue = value;
        bytes memory buffer = new bytes(2 * length + 2);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 2 * length + 1; i > 1; --i) {
            buffer[i] = HEX_DIGITS[localValue & 0xf];
            localValue >>= 4;
        }
        if (localValue != 0) revert StringsInsufficientHexLength(value, length);
        return string(buffer);
    }

    function toHexString(address addr) internal pure returns (string memory) {
        return toHexString(uint256(uint160(addr)), 20);
    }
}
