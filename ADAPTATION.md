# Arms v1 launch adaptation

Base: merged `main`, `6afdcba7c3e53da390012c2e54a9b03aa6fe0f79`, from the requested
`identity-md-launches/launch-3241-build-test-deploy-sepolia` repository. Public GitHub and the
prior job API agree; the saved provenance is `docs/evidence/base-provenance.json`.

The protected compiler configuration, dependencies, lockfiles and repository metadata were not
edited. No token/pool/distributor for another launch mode was added. No live deployment or paid
oracle flow was executed by this worker. The requested launch manifest is complete for the network
deployer; it does not pretend that deployment, form registration or real oracle settlement happened.

## Imported audit findings

Four scratch proofs were run against the unchanged source before editing, using
`forge test --offline --match-contract ImportedFindingsProof --match-test test_reproduce -vv`:
all four passed by demonstrating the reported behavior. They covered the zero-based question,
same-chain future-block acceptance, a `type(uint128).max` mint, and absent signer rotation.
Those disposable proofs are replaced by the delivered passing regressions listed below.

### f0b4e00b6530e41544a2895399401a13f84991f97ce6b100527c3ff5cd80f139 — fixed

`IMDCourt.question(..., key=0, ...)` originally emitted “key number 0”; a challenge at index 12
would ask about Key 12 instead of Key 13. `src/IMDCourt.sol` now emits `uint256(key) + 1`.
The cast avoids overflowing at uint8's boundary. Arrays and challenges remain zero-based.
`test/IMDCourt.t.sol` fuzzes indices 0..31, asserts the exact body bytes, and exercises a real
13-key vector locally: index 8 asks about Key 9 and only that key is corrected/slashed.

### 878dfd192715cb1d8f36f4dbb54c74c257a2a45b06ae41edb770041484a49082 — same-chain reproduction fixed

The original `post(..., 11155111, target, 9007199254740991, ...)` succeeded with the local chain
set to Sepolia. `src/Arms.sol` now checks `atBlock + 5 <= Blocks.number(arbitrumBlocks)` for local
chain targets before any escrow pull or job state change. The number 5 is named `MIN_BLOCK_DEPTH`
and comes from the oracle's confirmed-window rule. The posting height is read once and reused.
`test/LaunchAdaptation.t.sol` tests the boundary, the originally reported input, unchanged balances
on rejection, fuzzed heights, and ArbSys's chain-local height rather than its parent EVM height.

**Remaining limitation:** the unchanged supported remote chain cannot have its head authenticated
locally. Remote-chain posters still choose a confirmed height and readers must validate it. The
adapter does not fabricate a head, silently remove a supported target chain, or claim this is a
cross-chain light client. This residual audit concern remains explicitly open for remote targets.

### 053a9da615f351bd35012896113c7b2bd10f8cdd114c8ece05cafcc196584ee5 — fixed

The original owner could mint `type(uint128).max` after deployment. Launch policy forbids that
capability. `src/mocks/MockToken.sol` now mints `INITIAL_SUPPLY = 1_000_000 ether` once to its
explicit owner constructor argument. This is a chosen test-supply budget, ten times the README's
maximum total bond. Distribution is by ordinary transfers. `mint` is removed; `ERC20Burnable`'s
`burnFrom` is also removed to meet the holder-balance launch restriction. A holder's own `burn`
is retained for Arms' existing burn accounting. The factory receives no supply or admin role.

`test/LaunchAdaptation.t.sol` tests premint beneficiary, absent mint/burnFrom even with approval,
and fuzzed transfer/burn conservation. Existing fixtures in `ArmsBase`, `ArmsInvariant` and
`OracleConformance` distribute from the constructor allocation rather than minting. The invariant
handler now separately tracks the actors' actual initial budget, so the larger premint does not
weaken the old operator-gain bound; it additionally reconciles total supply with every holder.

### a6ed4c00f90be45975bb84793cbb05e76c07cb6a0f2d74f6263c4f06b7ddb9c5 — fixed, new trust role disclosed

The original court had no `setSigner`; its existing tests reproduced rejection after a changed
signer and an unsold action. `src/IMDCourt.sol` now takes an explicit `owner_` as its first
constructor argument, assigned `$owner` in the manifest. Owner-only `setOracleConfig` atomically
changes Intake, asset and action and emits `OracleConfigSet`; `setSigner` uses the existing
canonical signer setter/event. Zero configuration is rejected. `fee()` reads the current sale
and fails clearly with `ActionNotSold` for zero rather than attempting an unpaid request.

Pending request IDs are namespaced by their original Intake address; `Case.requestIntake` records
it. Migration cannot collide two Intakes' IDs or prevent the original Intake delivering a result
or failure. Rotating the signer applies to every pending case immediately, including revocation
of an old key. No new core admin, token seizure, direct ruling setter or core withdrawal is added.
However, choosing the attester is outcome authority: a dishonest court owner can choose a dishonest
attester. That is a necessary, explicit trust tradeoff to repair the reported migration failure.

`test/IMDCourt.t.sol` covers unauthorized and zero changes, pending-case signer rotation with old
signature rejection, equal request IDs across Intake migration, old-Intake failure delivery,
asset/action replacement, live pricing, and zero residual fee balance/allowance. Deployment and
canonical conformance fixtures pass the additional owner argument. `script/Deploy.s.sol` takes
the owner from its existing supplied Sepolia configuration and now guards chain 11155111.

### c90120c2d2cba4d0cb9d80d7382d630db53bcbecf55f7e33b47a5326a62e9c09 — informational, addressed with evidence

This is coverage/tooling disclosure, not a reproducible contract defect. Public Sepolia reads now
confirm the live Intake sale, callback limit and imdTEST ABI behavior; saved verified source and
runtime comparisons support the dependency assumptions. The audit judge was absent from exposed
tools, and invoking `audit-judge` returned `command not found` (exit 127). No independent judge
approval is claimed. Retained operational/security limitations are listed in `REVIEW.md`.

## Additional reproduced launch blockers

- **Invalid consumer JSON:** `IMDCourt.bodyOf` originally used a string for `consumer`. An unpaid
  live quote returned HTTP 400 `invalid_request` with that shape and HTTP 201 `created: true`
  after changing only that field to `{chainId,verifyingContract}`. `src/IMDCourt.sol` now emits
  the documented object, with the execution chain as the EIP-712 consumer chain. The exact-body
  regression in `test/IMDCourt.t.sol` covers it. Saved input/result pairs are in
  `docs/evidence/consumer-schema-preflight.json`; this was a validation quote, not a paid ruling.
- **Protected dependency scanner false positive:** unfiltered Slither reported HIGH `incorrect-exp`
  on the intentional `(3 * denominator) ^ 2` in protected OpenZeppelin `Math.mulDiv`, transitively
  imported by Strings and EIP712. No library/configuration file was changed or suppression added.
  `src/compat/Strings.sol` supplies only the three encoders actually used; `src/compat/EIP712.sol`
  preserves the existing OpenZeppelin implementation with remapped imports and the equivalent
  66-byte typed-data preimage hash, avoiding unused MessageHashUtils/Math imports. Original license
  text is retained. `src/OracleQuestion.sol`, `src/OracleAttestation.sol` and `src/IMDCourt.sol`
  change only the relevant import paths. `test/Compatibility.t.sol` differentially fuzzes decimal,
  hex, address encodings, domain hashes and EIP-5267 introspection against the untouched dependency,
  including long-string fallback and chain-ID changes. Canonical protocol digest/question vectors
  and actual callback signature tests still pass. The production Slither HIGH scan now has zero results.

## Other requested deliverables

| Files | Purpose and verification |
| --- | --- |
| `launch.json`, `script/check_launch.py`, `test/Deploy.t.sol` | Requested three-contract order, five-word court/13-word core constructor configuration, backward dependencies, explicit owner, static ABI types, size/link checks and empty-chain rehearsal. This assignment's explicit manifest request overrides the generic adapter background that normally defers the manifest. |
| `forms/control-map-v1.txt` | All 13 facts, checked proxy patterns, precise owner/admin walks and bytes32 encoding, including both sentinels for every key. |
| `docs/evidence/` | Public target readings, verified external sources, one file per key, real APIs, immutable base provenance and unpaid preflight results. No mock result is labeled as live. |
| `script/read_sepolia.py` | Reproducible public read-only capture, separately run from offline builds. |
| `script/prepare_control_map.py` | After publication/deployment, verifies the raw commit-pinned form bytes and actual deployed contracts, then prepares unsigned calldata. It sends no transaction. |
| `test/test_deliverables.py` | Offline checks of key numbering, exact sentinel/word lengths, coherent block evidence and registration hash inputs. |
| `test/IMDCourt.t.sol` | Two full local 13-key rounds through the real IMDCourt implementation, different bond/fee tokens, local signed callback, exact slash/refund/reward/stake/burn logs; both ordinary and spot-check rosters. |
| `README.md`, `REVIEW.md` | Current parameters, changed trust model, honest live-execution status, source verification/open tasks, reproduction commands and review disposition. `AUDIT.md` is preserved as the prior release's historical record. |

The raw form URI must contain the commit that actually publishes this new file; that commit does
not exist until network delivery. The helper deliberately refuses unpublished/mismatching bytes.
Actual deployment/source verification, registration, funding/serving, the honest live check and
the intentional real-oracle challenge remain for the network deployer/operator. Their missing
addresses, transaction hashes, callback gas and elapsed time are reported as not executed, never
invented or substituted with mock-court evidence. No input-blocker file is appropriate for a worker
that is expressly not to request a deployment key; this task's useful launch preparation is complete.
