// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIntake} from "../src/IIntake.sol";
import {IMDCourt} from "../src/IMDCourt.sol";
import {ICourt} from "../src/ICourt.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {OracleQuestion} from "../src/OracleQuestion.sol";
import {MockToken} from "../src/mocks/MockToken.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

/// @title The protocol's conformance test, with IMDCourt as the consumer
/// @notice Ties the court to what the oracle actually signs: the protocol's vector values and digest.
/// IMDCourt only takes uint256 answers to its own pinned questions, so the vector's bytes32[] answer
/// is checked by digest, and a fresh signature from the vector key settles a real case.
contract OracleConsumerConformanceTest is Test {
    // ---- the protocol's vector: do not change these ----
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    /// @dev anvil's second account: the vector's attester. A test key, never a real one.
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint64 constant ISSUED_AT = 1800000000;
    uint64 constant EXPIRES_AT = 1800003600;
    string constant CALLBACK =
        "onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)";
    bytes32 constant ACTION = 0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000;
    address constant WRITER = address(0x717E);

    MockIntake intake;
    MockToken token;
    IMDCourt consumer;

    function setUp() public {
        vm.chainId(VECTOR_CHAIN);
        vm.warp(ISSUED_AT);
        token = new MockToken(address(this));
        intake = new MockIntake(WRITER, makeAddr("treasury"), ACTION, address(token), 0.5 ether);
        deployCodeTo(
            "IMDCourt.sol:IMDCourt",
            abi.encode(address(this), address(intake), address(token), ACTION, SIGNER),
            VECTOR_CONSUMER
        );
        consumer = IMDCourt(VECTOR_CONSUMER);
    }

    function vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: ISSUED_AT,
            expiresAt: EXPIRES_AT
        });
    }

    /// @notice The digest the court verifies is the one the oracle signs.
    function test_digestMatchesTheProtocol() public view {
        assertEq(
            consumer.attestationDigest(vector()),
            VECTOR_DIGEST,
            "struct, type string or domain differs from the protocol's"
        );
    }

    /// @notice The callback's selector is the one the intake calls.
    function test_callbackSelectorIsCanonical() public view {
        assertEq(
            consumer.onOracleResult.selector,
            bytes4(keccak256(bytes(CALLBACK))),
            "callback parameters differ from the protocol's"
        );
    }

    /// @notice The protocol's question vector hashes the same way in this copy of OracleQuestion.
    function test_questionHashMatchesTheProtocolVector() public pure {
        OracleQuestion.Question memory q;
        q.question = "Which Uniswap v4 pool did the most WETH volume in the last day?";
        q.chainId = 1;
        q.fromBlock = 100;
        q.toBlock = 200;
        q.answerType = OracleAttestation.ANSWER_BYTES32_LIST;
        q.head = 1;
        q.definitions = new OracleQuestion.Definition[](1);
        q.definitions[0] =
            OracleQuestion.Definition("denomination", "WETH, summed as the absolute swapped amount on the WETH side");
        assertEq(OracleQuestion.hash(q), 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb);
    }

    /// @notice A fresh signature from the vector key, over the court's own question, settles a case
    /// delivered the way the writer delivers it.
    function test_acceptsAFreshSignatureFromTheVectorKey() public {
        token.approve(address(consumer), 0.5 ether);
        consumer.ask(
            keccak256("case"),
            keccak256("form"),
            "ipfs://form",
            1,
            VECTOR_CHAIN,
            address(0xBEEF),
            150,
            bytes32(0),
            bytes32(uint256(1)),
            address(this),
            0.5 ether
        );
        bytes32 requestId = intake.lastRequestId();
        IMDCourt.Case memory c = consumer.caseOf(address(this), keccak256("case"));
        OracleAttestation.Attestation memory a = vector();
        a.requestId = keccak256("another request");
        a.chainId = VECTOR_CHAIN;
        a.questionHash = c.questionHash;
        a.answerType = OracleAttestation.ANSWER_UINT256;
        a.answer = abi.encode(uint256(1));
        a.fromBlock = 150;
        a.toBlock = 150;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, consumer.attestationDigest(a));
        vm.prank(WRITER);
        assertTrue(intake.complete(requestId, a, abi.encodePacked(r, s, v)), "ran to the end under 200 000 gas");
        assertTrue(consumer.consumed(a.requestId));
        assertEq(uint8(consumer.rulingOf(address(this), keccak256("case"))), uint8(ICourt.Ruling.STORED));
    }
}
