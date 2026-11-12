# Implementer verification and open items

This is a local verification record, not independent audit approval. The imported findings and
all implementation changes are mapped in [ADAPTATION.md](ADAPTATION.md). The previous release's
`AUDIT.md` is historical; its counts, ownership description and deployment status are not current.

## Checks

The workspace suite passed **96 reported tests/groups**, with zero failures/skips. Foundry groups
all six invariant properties as one reported test; those properties used 64 runs x 40 handler
calls. The task seed and the project-configured default seed both passed; a second seed `0x123456`
passed at **1,000 fuzz runs**. The additional three Python deliverable checks passed. A clean
export of the submitted file set also passed offline build, all 96 test groups with the task seed,
formatting, manifest/ABI/size checks, the three Python checks and the unfiltered Slither HIGH scan
(exit 0, zero results). That export contained no build cache, broadcast output, scratch tests or
pinned inputs. The selected source bundle is under 3 MiB (limit 8 MiB). Git staging was not used:
the task forbids changing repository metadata, and the network worker commits after this step. The project
keeps its existing Solidity 0.8.26, Cancun, via-IR, optimizer-runs-1 configuration. All builds and
Solidity tests run offline, with no file or environment access from the tests. Both deployment
order and constructor-created children are exercised from a contract caller on an empty chain.

The regression suite covers all four actionable imported findings, the live consumer JSON schema
repair, separate bond/fee assets, pending requests across oracle migration, local/Arbitrum block
confirmation, fixed-supply transfers/burns, and string/domain equivalence with the original
dependency. The canonical protocol digest/question-hash vectors are unchanged.

| Deployable | Constructor words | Runtime bytes | Initcode including constructor words |
| --- | ---: | ---: | ---: |
| MockToken | 1 | 2,014 | 3,121 |
| IMDCourt | 5 | 13,269 | 14,954 |
| Arms | 13 | 24,251 | 35,618 |
| ArmsForms (created by Arms) | 2 | 3,356 | 3,625 |
| ArmsResults (created by Arms) | 0 | 5,743 | 5,769 |

Arms has **325 bytes** of EIP-170 margin. All constructors are nonpayable/static, have at most
16 words, fit EIP-3860 including arguments and have no link placeholders. The exact reachable
opcode walk from the supplied protected floor passes for all five created contracts. The manifest
checker validates the supplied textual reference's exact field set, types, order, static values,
backward dependencies and actual ABIs; no separate JSON schema was supplied or invented.

## Static analysis disposition

The initial HIGH scan reproduced one `incorrect-exp` result inside protected OpenZeppelin Math:
its modular-inverse seed deliberately uses XOR. The minimal project compatibility helpers remove
that unused dependency path without modifying `lib/`, changing the intended arithmetic, or using
detector suppression comments. The updated production tree's unfiltered HIGH scan reports
**0 results**, exit 0.

The Medium-or-higher scan reports **22 Medium results**, no High:

| Detector | Count | Disposition |
| --- | ---: | --- |
| `divide-before-multiply` | 1 | `Arms._splitStake` computes quotient then exact remainder (`stake - share*g`) to assign integer dust. Reordering would change the intended remainder computation. Existing split tests and custody invariants cover conservation. |
| `reentrancy-no-eth` | 4 | `_finalize`, `resolve` (two paths), `IMDCourt.ask` call the configured tokens/Intake before all bookkeeping is complete. The declared launch uses a fixed, non-callback ARMT and verified ordinary imdTEST/Intake; these dependencies do not reenter. This is a retained dependency assumption, not a proof for arbitrary malicious/hook tokens. Court owner configuration is explicitly trusted; changing it to hostile code is outside that assumption and already grants control of oracle trust. No broad core redesign was made. |
| `uninitialized-local` | 13 | Solidity value locals and fixed-size memory arrays in `Arms`/`ArmsResults` are zero-initialized by language semantics. These are counters, vote masks, arrays and booleans, not uninitialized storage references. No behavior change needed. |
| `unused-return` | 4 | The protected SignatureChecker checks recovered address and error enum while intentionally discarding the error-detail word; form reads intentionally select URI and verdict reads select evidence. No token success boolean or signature validity result is discarded. |

The Medium scan exits 255 because findings are present; it is not reported as a clean scan. No
suppression file, protected configuration change or library edit was used. Lower-severity lint
warnings are not independent audit verdicts. The audit-judge tool is not exposed; a direct attempt
returned `audit-judge: command not found` (exit 127). Independent review remains open.

## Public evidence versus simulations

The public Sepolia readback pins block 12,121,156 and its hash, checks the oracle price and callback
limit, records owner/storage/code/ABI calls, and saves the existing external contracts' verified
source responses. Every form key has an evidence file. These are real public reads, not an oracle
attestation. The existing target has a partial compilation match on Blockscout and matching runtime
bytes at the pinned block; it is not described as a full metadata verification.

The API quote comparison genuinely returned HTTP 400 for the old consumer string and HTTP 201 for
the documented object. The free short-form check returned no blockers and an evidence-mode
suggestion. These are unpaid validation results for a real-target sample; the final immutable form
question must be checked after publication. They do not establish panel participation or quorum.

`test_controlMapTwoRoundsAndChallengeAccounting` and
`test_controlMapSpotCheckSlashesOnlyTheTwoWrongArms` run two complete local rounds through the
production IMDCourt implementation. A local MockIntake and test signing key supply the simulated
attestation. They assert exact slash/refund/reward/stake/burn logs and custody, including that an
honest third arm is not slashed. They are not the requested live checks, and no transaction hash
or oracle ruling is fabricated from them. Every local callback also passes the stricter 200,000
gas limit; the public Sepolia Intake was observed configured for 1,000,000. The local two-round
call trace reports **57,622 gas** for `IMDCourt.onOracleResult`. This is a fixture measurement,
not a live oracle receipt or a promised upper gas bound. The script deployment dry run on local
chain ID 11155111 succeeded with **11,167,495 gas** and no RPC/broadcast. Both measurements are
informational; no test asserts an exact gas value.

## Still open

1. Network deployment of this release and source verification of MockToken, IMDCourt, Arms and
   the automatically created ArmsForms/ArmsResults. Constructors and sizes are locally checked;
   actual deployment receipts are not available yet.
2. Commit-pinned form publication/registration, three funded test wallets serving it, the honest
   real check, and the deliberate wrong-Key-9 real oracle challenge. Consequently live callback
   gas, elapsed ruling time, transaction hashes and actual slash/refund/reward/burn logs are absent.
   The README gives the exact operator handoff and expected accounting; it does not mark these done.
3. Imported future-block finding: fixed for local-chain targets, including ArbSys heights, and in
   this revision for remote targets too: `Arms.post` bounds a remote `atBlock` by the court's
   `confirmedHead`, which is zero (nothing admitted) until the court owner publishes one with
   `setConfirmedHead`. The head is the owner's word, not a light client: a stale head delays remote
   posts, and a head set above the real chain would readmit the original problem, so the owner must
   publish only heights it has confirmed. Publishing one for 4663 is an operator step after launch.
4. The new court owner can change oracle trust anchors. A dishonest owner can select a dishonest
   attester, so this is explicitly trusted administration outside the ownerless core. Immediate
   signer revocation can invalidate signatures already produced but not yet delivered. Existing
   bounded NONE/refund behavior handles a missing ruling; the oracle price is never refunded.
5. Independent audit judge unavailable. Retained v1 risks include proposer-biased block hashes,
   sybil arms, sparse append-only service lists, keeper requirements, missed draw windows and
   unchanged challenge/exit deadlines. No attempt was made to redesign them in this adaptation.

The deployment service performs the real launch after independent acceptance. This worker did
not access a signer, send a transaction, request a key, or wait for a seven-day timeout.
