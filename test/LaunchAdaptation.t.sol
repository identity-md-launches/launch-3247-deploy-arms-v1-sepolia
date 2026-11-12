// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ArmsBase} from "./ArmsBase.t.sol";
import {Arms} from "../src/Arms.sol";
import {IArbSys} from "../src/Blocks.sol";
import {MockToken} from "../src/mocks/MockToken.sol";

contract TokenLaunchTest is Test {
    MockToken token;
    address owner = makeAddr("launchOwner");
    address holder = makeAddr("holder");

    function setUp() public {
        token = new MockToken(owner);
    }

    function test_onlyConstructorMintsAndFactoryReceivesNothing() public {
        assertEq(token.totalSupply(), 1_000_000 ether);
        assertEq(token.balanceOf(owner), token.totalSupply());
        assertEq(token.balanceOf(address(this)), 0);
        for (uint256 i; i < 2; ++i) {
            vm.prank(i == 0 ? owner : holder);
            (bool ok,) =
                address(token).call(abi.encodeWithSignature("mint(address,uint256)", holder, type(uint128).max));
            assertFalse(ok, "no post-launch mint, even for the owner");
        }
        assertEq(token.totalSupply(), 1_000_000 ether);
    }

    function test_noBurnFromEvenWithAllowance() public {
        vm.prank(owner);
        token.approve(holder, 1 ether);
        vm.prank(holder);
        (bool ok,) = address(token).call(abi.encodeWithSignature("burnFrom(address,uint256)", owner, 1 ether));
        assertFalse(ok);
        assertEq(token.balanceOf(owner), token.INITIAL_SUPPLY());
    }

    function testFuzz_transferAndBurnConserveSupply(uint96 rawAmount, uint96 rawBurn) public {
        uint256 amount = bound(rawAmount, 0, token.INITIAL_SUPPLY());
        uint256 burn = bound(rawBurn, 0, amount);
        vm.prank(owner);
        assertTrue(token.transfer(holder, amount));
        vm.prank(holder);
        token.burn(burn);
        assertEq(token.balanceOf(holder), amount - burn);
        assertEq(token.totalSupply() + burn, token.INITIAL_SUPPLY());
        assertEq(token.balanceOf(owner) + token.balanceOf(holder), token.totalSupply());
    }
}

contract ConfirmedBlockTest is ArmsBase {
    function test_futureAndUnconfirmedLocalBlocksFailBeforeEscrowMoves() public {
        vm.chainId(CHAIN);
        vm.roll(AT_BLOCK + 10);
        uint256 balance = token.balanceOf(poster);
        uint256[4] memory invalid = [uint256(9_007_199_254_740_991), AT_BLOCK + 11, AT_BLOCK + 10, AT_BLOCK + 6];
        for (uint256 i; i < invalid.length; ++i) {
            vm.prank(poster);
            vm.expectRevert(Arms.BadTarget.selector);
            arms.post(formId, CHAIN, target, invalid[i], FEE);
        }
        assertEq(arms.jobCount(), 0);
        assertEq(arms.totalEscrow(), 0);
        assertEq(token.balanceOf(poster), balance);
        vm.prank(poster);
        uint256 id = arms.post(formId, CHAIN, target, AT_BLOCK + 5, FEE);
        assertEq(_job(id).atBlock, AT_BLOCK + 5);
    }

    function testFuzz_confirmationBoundary(uint64 rawHead, uint64 rawBlock) public {
        uint256 head = bound(rawHead, 6, 9_007_199_254_740_991);
        uint256 atBlock = bound(rawBlock, 1, 9_007_199_254_740_991);
        vm.chainId(CHAIN);
        vm.roll(head);
        vm.prank(poster);
        if (atBlock + 5 > head) vm.expectRevert(Arms.BadTarget.selector);
        arms.post(formId, CHAIN, target, atBlock, FEE);
    }

    function test_arbitrumUsesItsOwnHeightForConfirmation() public {
        vm.chainId(4663);
        vm.roll(1_000_000);
        vm.mockCall(address(100), abi.encodeCall(IArbSys.arbBlockNumber, ()), abi.encode(uint256(10_000)));
        arms = _deploy(sepoliaParams(address(token), address(court)));
        formId = arms.registerForm(keccak256("arb-confirmation"), 1, "ipfs://local-form");
        _fund(poster, 0);
        vm.startPrank(poster);
        vm.expectRevert(Arms.BadTarget.selector);
        arms.post(formId, 4663, target, 9996, FEE);
        uint256 id = arms.post(formId, 4663, target, 9995, FEE);
        vm.stopPrank();
        assertEq(_job(id).postedBlock, 10_000);
    }
}
