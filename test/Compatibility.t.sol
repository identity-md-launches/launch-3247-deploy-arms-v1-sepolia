// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Strings as OriginalStrings} from "@openzeppelin/contracts/utils/Strings.sol";
import {EIP712 as OriginalDomain} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Strings} from "../src/compat/Strings.sol";
import {EIP712} from "../src/compat/EIP712.sol";

contract LocalDomainHarness is EIP712 {
    constructor(string memory name, string memory version) EIP712(name, version) {}

    function digest(bytes32 value) external view returns (bytes32) {
        return _hashTypedDataV4(value);
    }
}

contract OriginalDomainHarness is OriginalDomain {
    constructor(string memory name, string memory version) OriginalDomain(name, version) {}

    function digest(bytes32 value) external view returns (bytes32) {
        return _hashTypedDataV4(value);
    }
}

contract CompatibilityTest is Test {
    function testFuzz_stringsMatchProtectedDependency(uint256 value, address account) public pure {
        assertEq(Strings.toString(value), OriginalStrings.toString(value));
        assertEq(Strings.toHexString(value, 32), OriginalStrings.toHexString(value, 32));
        assertEq(Strings.toHexString(account), OriginalStrings.toHexString(account));
    }

    function test_decimalBoundariesAndHexPadding() public pure {
        assertEq(Strings.toString(0), "0");
        assertEq(Strings.toString(type(uint256).max), OriginalStrings.toString(type(uint256).max));
        for (uint256 power = 1; power <= 10 ** 77; power *= 10) {
            assertEq(Strings.toString(power - 1), OriginalStrings.toString(power - 1));
            assertEq(Strings.toString(power), OriginalStrings.toString(power));
            assertEq(Strings.toString(power + 1), OriginalStrings.toString(power + 1));
            if (power == 10 ** 77) break;
        }
        assertEq(Strings.toHexString(uint256(0), 0), "0x");
    }

    function encodeTooShort() external pure returns (string memory) {
        return Strings.toHexString(256, 1);
    }

    function test_hexOverflowKeepsOriginalError() public {
        vm.expectRevert(abi.encodeWithSelector(Strings.StringsInsufficientHexLength.selector, uint256(256), uint256(1)));
        this.encodeTooShort();
    }

    function testFuzz_domainDigestAndIntrospectionMatch(bytes32 value, uint64 nextChain) public {
        _domainPair("IdentityMD Oracle", "2", value, nextChain);
        _domainPair(
            "A domain name longer than thirty one bytes for fallback storage",
            "a version longer than thirty one bytes",
            value,
            nextChain
        );
    }

    function _domainPair(string memory name, string memory version, bytes32 value, uint64 nextChain) internal {
        // Deploy both at the same address in isolated snapshots, including the forked chain-id path.
        uint256 snapshot = vm.snapshotState();
        LocalDomainHarness local = new LocalDomainHarness(name, version);
        address at = address(local);
        vm.chainId(nextChain);
        bytes32 localDigest = local.digest(value);
        (, bytes memory localDomain) = at.staticcall(abi.encodeWithSignature("eip712Domain()"));
        assertTrue(vm.revertToState(snapshot));
        OriginalDomainHarness original = new OriginalDomainHarness(name, version);
        assertEq(address(original), at);
        vm.chainId(nextChain);
        assertEq(localDigest, original.digest(value));
        (, bytes memory originalDomain) = at.staticcall(abi.encodeWithSignature("eip712Domain()"));
        assertEq(localDomain, originalDomain);
    }
}
