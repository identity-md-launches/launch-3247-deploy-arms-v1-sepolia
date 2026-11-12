// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Arms} from "../src/Arms.sol";
import {IIntake} from "../src/IIntake.sol";
import {IMDCourt} from "../src/IMDCourt.sol";
import {MockToken} from "../src/mocks/MockToken.sol";

/// @title The Sepolia deployment, as one function the tests call directly
/// @notice IMD's launch deploys the three contracts from their bytecode with the arguments below
/// (see README "Launch"). This script rehearses the same deployment on a local node: `run()` reads
/// no environment and takes its configuration from `sepoliaConfig()`.
contract Deploy is Script {
    error WrongChain(uint256 chainId);

    struct Config {
        address tokenOwner;
        address intake;
        address imd;
        bytes32 action;
        address oracleSigner;
        uint256 minFeePerArm;
        uint256 maxBondPerArm;
        uint256 maxTotalBonded;
    }

    /// @dev The launch's owner for the token distribution and oracle configuration.
    address public constant SEPOLIA_OWNER = 0xCC4E8639884d08033597DeF041f966E8bE5BC514;
    address public constant SEPOLIA_INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address public constant SEPOLIA_IMDTEST = 0x56bcf2a5F47710649A4091219Ef0b56e2d1B58BF;
    bytes32 public constant ORACLE_ACTION = 0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000;
    address public constant ORACLE_SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;

    function sepoliaConfig() public pure returns (Config memory c) {
        c.tokenOwner = SEPOLIA_OWNER;
        c.intake = SEPOLIA_INTAKE;
        c.imd = SEPOLIA_IMDTEST;
        c.action = ORACLE_ACTION;
        c.oracleSigner = ORACLE_SIGNER;
        c.minFeePerArm = 1 ether;
        c.maxBondPerArm = 1000 ether;
        c.maxTotalBonded = 100_000 ether;
    }

    function armsParams(Config memory c, address token, address court) public pure returns (Arms.Params memory p) {
        p.token = token;
        p.court = court;
        p.trancheMultiple = 10;
        p.minFeePerArm = c.minFeePerArm;
        p.maxBondPerArm = c.maxBondPerArm;
        p.maxTotalBonded = c.maxTotalBonded;
        p.burnBps = 1000;
        p.challengerRewardBps = 3000;
        p.commitWindow = 6 hours;
        p.revealWindow = 2 hours;
        p.challengeWindow = 7 days;
        p.courtDeadline = 7 days;
        p.exitDelay = 14 days;
    }

    function deploy(Config memory c) public returns (MockToken token, IMDCourt court, Arms arms) {
        if (block.chainid != 11155111) revert WrongChain(block.chainid);
        token = new MockToken(c.tokenOwner);
        court = new IMDCourt(c.tokenOwner, IIntake(c.intake), IERC20(c.imd), c.action, c.oracleSigner);
        Arms.Params memory p = armsParams(c, address(token), address(court));
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
    }

    function run() external {
        vm.startBroadcast();
        deploy(sepoliaConfig());
        vm.stopBroadcast();
    }
}
