// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Arms} from "../src/Arms.sol";
import {IMDCourt} from "../src/IMDCourt.sol";
import {MockToken} from "../src/mocks/MockToken.sol";
import {ArmsForms} from "../src/ArmsForms.sol";

contract DeployTest is Test {
    function test_deploySepoliaConfig() public {
        vm.chainId(11155111);
        Deploy d = new Deploy();
        Deploy.Config memory c = d.sepoliaConfig();
        vm.recordLogs();
        (MockToken token, IMDCourt court, Arms arms) = d.deploy(c);
        assertEq(token.owner(), d.SEPOLIA_OWNER(), "token owner is the launch owner, not the deployer");
        assertEq(token.balanceOf(d.SEPOLIA_OWNER()), token.INITIAL_SUPPLY());
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY());
        assertEq(token.balanceOf(address(d)), 0);
        assertEq(court.owner(), d.SEPOLIA_OWNER());
        assertEq(address(court.intake()), d.SEPOLIA_INTAKE());
        assertEq(address(court.asset()), d.SEPOLIA_IMDTEST());
        assertEq(court.action(), bytes32("oracle.request@oracle-1"));
        assertEq(court.oracleSigner(), d.ORACLE_SIGNER());
        assertEq(address(arms.token()), address(token));
        assertEq(address(arms.court()), address(court));
        assertTrue(arms.chainAllowed(11155111));
        assertTrue(arms.chainAllowed(4663));
        assertFalse(arms.chainAllowed(1));
        // The Deployed event carries every parameter.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(arms) && logs[i].topics[0] == keccak256(bytes(_deployedSig()))) {
                Arms.Params memory p = abi.decode(logs[i].data, (Arms.Params));
                assertEq(p.trancheMultiple, 10);
                assertEq(p.burnBps, 1000);
                assertEq(p.challengerRewardBps, 3000);
                assertEq(p.commitWindow, 6 hours);
                assertEq(p.revealWindow, 2 hours);
                assertEq(p.challengeWindow, 7 days);
                assertEq(p.courtDeadline, 7 days);
                assertEq(p.exitDelay, 14 days);
                found = true;
            }
        }
        assertTrue(found, "Deployed event");
        // Constructors touch no other contract: the same deployment works on an empty chain too.
        assertGt(address(arms).code.length, 0);
        assertLe(address(arms).code.length, 24_576, "EIP-170");
        assertLe(address(arms.formRegistry()).code.length, 24_576);
        assertLe(address(arms.resultCalculator()).code.length, 24_576);
        assertLe(address(court).code.length, 24_576);
        assertLe(address(token).code.length, 24_576);
        _assertNoEscapeOpcodes(address(arms));
        _assertNoEscapeOpcodes(address(court));
        _assertNoEscapeOpcodes(address(token));
        _assertNoEscapeOpcodes(address(arms.formRegistry()));
        _assertNoEscapeOpcodes(address(arms.resultCalculator()));
        assertEq(arms.formRegistry().core(), address(arms));
        // Registration is usable immediately: there is no initializer, wiring or ownership transfer.
        bytes32 form = arms.registerForm(keccak256("launch form"), 1, "ipfs://launch-form");
        (uint8 keys, uint256 servers) = arms.formRegistry().info(form);
        assertEq(keys, 1);
        assertEq(servers, 0);
        ArmsForms registry = arms.formRegistry();
        vm.expectRevert(ArmsForms.OnlyArms.selector);
        registry.serve(form, address(this), 1 ether);
        vm.expectRevert(ArmsForms.OnlyArms.selector);
        registry.stop(form, address(this), 1, 0);
        vm.expectRevert(ArmsForms.OnlyArms.selector);
        registry.register(keccak256("bypass"), 1, "ipfs://bypass");
    }

    function test_deployRejectsAnotherChain() public {
        vm.chainId(1);
        Deploy d = new Deploy();
        Deploy.Config memory c = d.sepoliaConfig();
        vm.expectRevert(abi.encodeWithSelector(Deploy.WrongChain.selector, uint256(1)));
        d.deploy(c);
    }

    function _deployedSig() internal pure returns (string memory) {
        return "Deployed((address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256))";
    }

    /// @dev Same reachable-opcode walk as the supplied Contracts.protected.t.sol floor.
    function _assertNoEscapeOpcodes(address application) internal view {
        bytes memory code = application.code;
        bool reachable = true;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden application opcode");
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) reachable = false;
        }
    }
}
