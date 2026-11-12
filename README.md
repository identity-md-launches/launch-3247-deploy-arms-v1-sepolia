# Arms v1

Bonded agents (*arms*) answer an immutable form about a target contract. A job escrows three fees,
normally draws two arms, compares sealed answers key by key, and uses one tie breaker when necessary.
One job in ten instead draws a blind third arm. Challenges go to an IdentityMD oracle panel.

This adaptation starts from merged `main` commit
`6afdcba7c3e53da390012c2e54a9b03aa6fe0f79` of
[launch-3241-build-test-deploy-sepolia](https://github.com/identity-md-launches/launch-3241-build-test-deploy-sepolia).
It prepares the three-contract Sepolia launch, fixes reproduced audit/launch blockers, and adds
Control Map v1 with real public-state evidence. **No release contract has been deployed, no form
has been registered on Sepolia, and no paid oracle challenge has run in this worker task.** The
end-to-end tests below are offline simulations, not live oracle evidence. Deployment belongs to
IMD's network deployer after review; no signer/key was requested or used.

The core remains ownerless, without upgrade or pause. The court now has a narrowly scoped oracle
configuration owner to survive protocol migrations; that owner is a trust authority over oracle
answers. [ADAPTATION.md](ADAPTATION.md) maps every change to its reproduced finding or launch rule.
[REVIEW.md](REVIEW.md) records current checks; [AUDIT.md](AUDIT.md) is historical.

## Contracts and boundaries

| Contract | Responsibility |
| --- | --- |
| `Arms` | Holds all bonds, escrow, stakes and rewards; enforces eligibility, deadlines, authorization, payments and challenges. |
| `ArmsForms` | Form identity, URI validation and permanent server indices. Only its permanently bound Arms instance can write. |
| `ArmsResults` | Stateless vote counting, payment calculation and verdict reads. Only performs static reads of its caller. |
| `ICourt` | `supportsChain`, `feeAsset`, `fee`, `ask`, `ruling`. |
| `IMDCourt` | Keeps the fixed target-chain list and asks the configured Intake for signed, question-bound rulings. |
| `MockCourt` | Constructor-configured fee; anyone can rule. Local demonstrations/tests only. |
| `MockToken` | Fixed initial supply of 1,000,000 ARMT to the explicit launch owner; holder self-burn only. |
| `Blocks` | Internal block-number/hash adapter; uses ArbSys on recognized Arbitrum chains. |
| `FormURI` | Internal URI-character validation shared by the registry and court. |
| `OracleAttestation`, `OracleQuestion` | Protocol attestation and canonical question encoding, with the existing `bodyWith` helper and equivalent local encoding/domain compatibility helpers. |

Arms creates `ArmsForms` and `ArmsResults` in its constructor and stores their immutable addresses.
They have no initializer or replacement path. There is no delegatecall, proxy, external library link,
manual storage packing, or deployment-time call to a configured token, court, Intake or precompile.
Only the registry stores forms; all funds and job state remain in Arms. Form reads are now on
`Arms.formRegistry()`: `forms(id)`, `info(id)`, `serversOf(id)`, `minFeeOf(id, arm)`, `stoppedAt(id, arm)`, `stoppedAfterJob(id, arm)`.
The mutating entry points `registerForm`, `serve` and `stopServing` remain on Arms.

Existing dependencies and compiler configuration are unchanged. Foundry pins Solidity **0.8.26**,
Cancun, via-IR, optimizer runs 1. Dependencies are ordinary files under `lib/`. `src/compat/`
contains only the encoding/domain helpers needed to avoid an unrelated `Math.mulDiv` static-analysis
false positive; differential fuzz tests and the protocol's fixed signature/hash vectors check them.

## Launch manifest and constructor order

Every constructor below is nonpayable, accepts at most 16 entries, and takes only addresses, unsigned
integers or bytes32. No array, tuple/struct, string, bytes or ETH is required. No setup transaction is
needed to connect or activate the contracts. Token distribution, form registration, bonding and posting
are ordinary user operations, not contract initialization.

The complete requested [launch.json](launch.json) has kind `evm_contracts`, the following three entries,
and backward references only. The explicit manifest request in this assignment takes precedence over
the generic adapter background that normally leaves this file to a later step. `script/Deploy.s.sol`
rehearses the same configuration. `deploy(Config)` can be tested without an RPC, environment variables
or any broadcast, and refuses execution outside chain 11155111. Its old `Params` constructor has been removed: `Params`
is now only a convenient data type for the `Deployed` event and the rehearsal helpers.

1. **Token.** This launch deploys the requested burnable `MockToken(address owner_)` with the
   launch's `$owner`, never the deployment factory.
   The retained rehearsal's owner is `0xcc4e8639884d08033597def041f966e8be5bc514` from the accepted project.
   `MockToken.INITIAL_SUPPLY` is **1,000,000 ARMT** (`1000000000000000000000000` minor units),
   minted once to that owner in the constructor. This chosen test-supply budget is ten times the
   100,000 ARMT total bond cap. Distribution uses `transfer`; `mint` and `burnFrom` are absent.
   Existing deployed tokens, if any, must not be silently substituted for this manifest entry.
2. **Court.** Deploy `IMDCourt(owner_, intake_, asset_, action_, oracleSigner_)` with these five entries in order:

   | Argument | Sepolia parameter |
   | --- | --- |
   | `owner_` (address) | `$owner`, resolving to `0xcc4e8639884d08033597def041f966e8be5bc514` |
   | `intake_` (address) | `0xa43e6f75ee006411f79ac1c84120606c2330de82`, Intake v2 |
   | `asset_` (address) | `0x56bcf2a5f47710649a4091219ef0b56e2d1b58bf`, imdTEST |
   | `action_` (bytes32) | `0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000`, ASCII `oracle.request@oracle-1`, padded rather than hashed |
   | `oracleSigner_` (address) | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` |

   These values were checked against current IMD docs/API and public Sepolia state; see the live-read
   report below. The deployer must recheck them at launch. The oracle price is read on each ask;
   it is not a constructor argument. No deployment-time external call is needed.
3. **Core.** Deploy `Arms` with exactly these **13 flat entries**, in this order:

   | # | Argument | Sepolia parameter |
   | --- | --- | --- |
   | 1 | `token_` address | `$contract:MockToken`, deployed in step 1 |
   | 2 | `court_` address | IMDCourt from step 2 |
   | 3 | `minFeePerArm_` uint256 | `1000000000000000000` (1 ARMT) |
   | 4 | `maxBondPerArm_` uint256 | `1000000000000000000000` (1,000 ARMT) |
   | 5 | `maxTotalBonded_` uint256 | `100000000000000000000000` (100,000 ARMT) |
   | 6 | `trancheMultiple_` uint256 | `10` |
   | 7 | `burnBps_` uint256 | `1000` |
   | 8 | `challengerRewardBps_` uint256 | `3000` |
   | 9 | `commitWindow_` uint256 | `21600` (6 hours) |
   | 10 | `revealWindow_` uint256 | `7200` (2 hours) |
   | 11 | `challengeWindow_` uint256 | `604800` (7 days) |
   | 12 | `courtDeadline_` uint256 | `604800` (7 days) |
   | 13 | `exitDelay_` uint256 | `1209600` (14 days) |

   During step 3, Arms first creates `ArmsForms(address core_, uint256 minFee_)` with its own address
   and argument 3, then `ArmsResults()` with no arguments. These children are automatically deployed;
   a launch does not deploy or wire separate instances. Their addresses are available from
   `formRegistry()` and `resultCalculator()` immediately. All creation code is fully linked.

For local demonstrations, `MockCourt(address feeToken_, uint256 price_)` can replace IMDCourt; its
fee token must already exist. A zero price with a zero fee token is the deliberately free mock mode,
not a production placeholder. The test-only `MockIntake(address writer_, address treasury_, bytes32
 action_, address asset_, uint256 price_)` installs its initial sale in its constructor; no `setPrice`
setup call is needed. Its unrestricted `setPrice` is solely for simulating later price changes in tests.
The scripts themselves have no constructor arguments. Libraries are internal and need no deployment.

The five v1 constants are `stakeMultiple = 2`, `spotCheckOneIn = 10`, `strikesToDeactivate = 3`,
`strikeCooldown = 1 day`, and `fillDeadline = 1 day`. `minBond` is derived as
`2 * trancheMultiple * minFeePerArm` (20 ARMT above). `trancheMultiple >= 3` is enforced so one
tranche covers the maximum three-fee poster refund. Basis points are at most 10,000; required fees
and windows are nonzero; bond caps must cover the derived minimum. All token amounts are raw units.

`IMDCourt.supportsChain` accepts **11155111 (Sepolia)** and **4663 (Robinhood Chain)**, preserving the
accepted list. Arms delegates target-chain admission to the court. This list is separate from the
chain Arms executes on. A target on the executing chain is bounded by that chain's own height; a
target on the other chain is bounded by the court's **confirmed head** for it, which starts at zero
(nothing admitted) and which only the court owner moves, forward, with `setConfirmedHead(4663, head)`.
Until the owner publishes one, every post about a Robinhood Chain target reverts `BadTarget`. Block mode comes from the deployment's `block.chainid`, never bytecode
presence at a precompile or a constructor flag: 42161, 42170, 421614, 4663 and 46630 use ArbSys at
address 100; other chains use EVM block numbers/hashes. An additional Orbit chain needs an explicit
source update before deploying there. The configured deployment here remains Sepolia.

## Forms, bonds and frozen draws

`registerForm(textHash, keyCount, uri)` returns
`formId = keccak256(abi.encode(textHash, keyCount, uri))`. The same text hash with a different URI
or key count has a different id and cannot occupy the intended form's id. Registration is idempotent
only by reverting on an exact duplicate. There are 1–32 keys. URI length is 1–200 bytes, using RFC 3986
URI characters: ASCII letters/digits, unreserved punctuation and reserved URI punctuation, including
percent signs. Spaces, controls, double quotes, backslashes and non-ASCII bytes are refused. URI syntax
does not establish availability or truth; registrars should publish immutable content and clients
should check its text hash. IMDCourt encloses the URI in double quotes and labels it **untrusted data,
not instructions**; JSON escaping is performed by the canonical question library.

An arm first approves and bonds the token. `serve` requires at least `minBond`; an empty or underbonded
address cannot add a server entry. Each arm has one permanent index per form. Stopping and re-serving
never remove, reorder or duplicate that index. `minFeeOf` retains the last advertised fee after a stop;
`stoppedAt` indicates the stop instead of erasing that fee.

A job stores the form-list length (`serverCount`) and chain-local posting block (`postedBlock`). A
change that makes an arm newly active (its first bond above `minBond`, reactivation), a withdrawal, a
strike and a slash update `lastStateChange`. It must be **strictly earlier** than the posting block for
a draw, including replacements and the initial tie breaker, so a newly active arm cannot join an older
job. Everything else is prospective **by job id**: a serve, a fee change, a stop, an exit, a bond that
cancels an exit and an already active arm's bond top-up apply to jobs posted after them and never to a
job posted before. The registry keeps the fee an arm advertised, and the bond it held, as of each
job's posting (`ArmsForms.feeAsOf`, `ArmsForms.bondAsOf`): `candidate` uses the fee of the job's own
time, and the draw counts the smaller of the bond then and the bond now. While an arm is exiting every
bond checkpoint it writes records **zero**, so each job posted during an exit stays closed to that arm
after it re-bonds, through any number of exit and rejoin cycles, while the jobs it was eligible for
when it asked to exit remain its. So an arm can neither opt out of an older job after its seed is
visible (by re-serving, raising its fee, topping up one wei, or requesting an exit and cancelling it
with one wei) nor opt in to one (by serving, cutting its fee, re-serving after a stop, topping up or
cancelling an exit).
An already selected arm retains its duties and locked tranche regardless of these later changes.
Signer rotation does not change eligibility.

The draw seed uses the block after posting/reopening and the job id. At the first draw it is saved.
**One opening has one seed.** `draw` reverts `TooEarly` until that block is mined and `SeedExpired`
once the chain no longer serves its hash (256 blocks later) with no seed saved. No other block is
ever substituted: a caller would know that block's hash before sending, and could pick the arms, or
a two-arm job instead of a spot check, by picking the block. A job posted and never drawn in that
time is refunded by `cancel` after the fill deadline and can be posted again; a tie break never drawn
is closed by `settle` after the fill deadline with its disputed keys UNRESOLVED. A seed that was
saved never expires, so a partly filled job keeps drawing from it.
Each attempt selects `keccak256(abi.encode(seed, attempt)) % serverCount`; the counter advances even
when that index is ineligible. Calls take at most **32 attempts** and retain the same seed/counter
between calls. There is no scan over the full form list, candidate compaction or modulo-zero path.
A poster, a previously drawn arm, or an arm without a currently available tranche is never selected.
Other jobs' locks still affect available capacity. No draw is allowed after the fill deadline.

`requestExit` stops eligibility for later jobs and opens withdrawal after `exitDelay`. Only unlocked
bond is withdrawable; bonding again cancels exit. Three strikes deactivate an arm; it can reactivate
after one day. The core does not enforce one human/operator per arm.

## Answers, settlement and no-shows

`post(formId, targetChainId, target, atBlock, feePerArm)` pulls `3 * feePerArm`. The target and block
must be nonzero and the block must fit the oracle's exact JSON integer range. For this same chain,
`atBlock + MIN_BLOCK_DEPTH <= Blocks.number(...)`, with `MIN_BLOCK_DEPTH = 5`, is enforced before
escrow moves. Arbitrum uses its own ArbSys height. For the other supported target chain the same
rule applies against `court.confirmedHead(targetChainId)`, the head the court owner last published
for it; with none published (zero) no remote post is admitted. Every job Arms records can therefore
be asked about with a window the oracle can read.
Anyone may `draw`, `timeout`, `cancel`, `settle`, `resolve` or `release`.

- `commit(jobId, arm, hash)` and `reveal(jobId, arm, values, salt, evidenceURI)` require the caller to be
  that named arm or its current signer. The commitment is `keccak256(abi.encode(jobId, arm, values, salt))`.
  One signer may serve several arms, including being an arm itself. No reverse signer lookup exists.
  Delegation authorizes no bonding, exit, withdrawal or payment redirection. Revocation affects only
  the arm changing its own signer; money always goes to arm addresses.
- All main arms commit before any main reveal. Reveals at the deadline are timely; timeouts require
  a strictly later timestamp. Evidence is limited to 200 bytes. A timeout never strikes an entry
  that completed its required action in time.
- All matching non-UNKNOWN answers are AGREED; two matching votes give MAJORITY. UNKNOWN is an
  abstention; NOT_APPLICABLE is an ordinary value. With two arms, distinct non-UNKNOWN answers open
  one tie breaker for disputed keys only. With three initial arms, there is **never a fourth arm**:
  each key settles by agreement/majority or becomes UNRESOLVED.
- Normal payments are proportional to correct final keys, rounded down, with `burnBps` burned. The
  tie breaker's denominator is the number of disputed keys. Each of at most three arms can earn at
  most one fee, so the escrow always suffices without capping an earned tie payment. Unused escrow
  returns to the poster. If the initial tie breaker cannot be drawn by the fill deadline, disputed
  keys become UNRESOLVED and any agreed keys still settle normally.
- A commit no-show before any reveal is struck, unlocked and replaced. A reveal round in which nobody
  reveals also replaces the nonresponders without reducing bonds. A replaced arm cannot be drawn
  again for that job. Commitments from timely committers survive a commit-timeout replacement.
- **Once any answer has been revealed, a no-show is never replaced.** All keys become UNRESOLVED,
  the poster gets the **entire escrow**, and each timely revealer receives **one full fee without a
  burn**, including a timely UNKNOWN answer. Compensation comes only from the missing arms' locked
  tranches. When multiple arms miss, they share this debit equally, with integer dust assigned to
  the first missing arm in the job roster. At most two fees are taken in total, below one tranche.
  Each missing arm receives a strike; timely revealers do not. Every tranche is unlocked, the job is
  SETTLED and already released, and no key is challengeable. A job closed this way carries no
  answer, so it is **not** recorded as the target's latest verdict: `latest()` keeps returning the
  last job that settled with answers, and one silent arm cannot erase it. The same rule holds for a
  normal settlement: `_finalize` records a job as the target's latest only when at least one key is
  AGREED or MAJORITY (an arm answering UNKNOWN on every key, or an unfilled tie break with every key
  disputed, leaves `latest()` alone) **and** its `atBlock` is not below the recorded verdict's, so a
  truthful reading at an old block does not replace a newer one. Escrow `spent` stays zero; the separate
  `NoShowCompensation` event records each bond debit. This is the only bond reduction besides a ruled
  challenge (apart from an arm withdrawing its own unlocked bond).
- The same closure applies when an assigned tie breaker misses commit or reveal, because the main
  answers are already public. A timely tie revealer is settled normally and cannot be struck by
  `timeout` while waiting for `settle`.
- `cancel` only applies to an OPEN, unfilled job after the fill deadline. Such a phase cannot contain
  revealed answers. It unlocks any selected tranches and refunds the entire escrow. Revealed work
  cannot be discarded through cancellation.

Normal settlement retains tranches until the challenge window closes and every challenge is resolved.
`release` then unlocks remaining tranches and burns any unearned challenger reward.

## Court rulings and v1 trust assumptions

Challenges are allowed only for AGREED/MAJORITY keys, inside the window, for a different non-UNKNOWN
value. One stake is `2 * feePerArm`, plus the live oracle price in the court's asset. Both are pulled
from the challenger; the court pulls its fee from Arms, never an arbitrary `payer`. Cases are
namespaced by asker to prevent an outsider occupying another core's case id.

IMDCourt asks for a panel of 5, quorum 4, with a one-day attestation validity. It translates zero-based
Arms indices to the form's one-based key numbers. The body has
`consumer: {chainId: block.chainid, verifyingContract: address(this)}`. It pins the canonical
question hash and verifies the protocol's full 15-field EIP-712 attestation in its own domain, the
sender, the pending request, panel minimums, freshness and replay protection. The callback only stores
a ruling within its 200,000 gas allowance; `resolve` performs transfers separately.

CLAIMED corrects a key; NEITHER overturns it. Several cases may be open on one key (one per claimed
value), and a CLAIMED ruling also corrects a key that an earlier NEITHER ruling on it overturned, so
the court-attested value is recorded whichever case is resolved first. Arms that gave the stored
wrong value each lose at most one locked tranche per job. The first slash refunds the job's actual
escrow expenditure, sets aside the configured reward fraction of the remainder, and burns the rest.
The first CLAIMED ruling earns the reward; later slashes burn their proceeds. STORED on a key that
still stands as the arms gave it (AGREED or MAJORITY) forfeits the stake, whatever happened on other
keys and in whatever order the cases are resolved: it is split among the arms that gave the value
and were not slashed in this job, and burned when none remains. STORED on a key another case has
already corrected or overturned returns the stake. A pending reward from NEITHER remains available
for a later CLAIMED ruling inside the window.

**Accepted for v1: a challenge with no ruling returns the full stake after `courtDeadline`.** The
stored verdict is unchanged and the Intake fee remains spent. Failure callbacks are unsigned and do
not pay anyone. This permits challenges to prolong tranche locks for their bounded court deadline
without losing a stake when the oracle fails. This economic choice has not been redesigned.

Other retained assumptions and operational responsibilities:

- The token is a conventional, exact-transfer, non-rebasing, bool-returning burnable ERC-20 with no
  transfer callbacks. Fee-on-transfer, hook-bearing and malicious tokens are unsupported. MockToken
  has no post-launch mint. The court and fee token must match
  their documented interfaces. Core token calls remain transfer, transferFrom, balanceOf and burn;
  exact court-fee approval is the separate fee-asset path.
- Block-hash randomness is **not VRF randomness**. A proposer/sequencer can bias the one seed block.
  Nobody else can: an expired seed is never replaced, and later calls cannot change a saved seed.
  Fixed indices remove list reshaping, but cannot remove proposer bias, sybil ownership or
  competition from other jobs for unlocked capacity.
- **Somebody must call `draw` within 256 blocks of the seed block**, which is the block after
  `post`, after a commit no-show replacement (`timeout`) and after `settle` opens a tie break. That
  is about 51 minutes on Ethereum or Sepolia and about one minute on an Arbitrum Orbit chain with
  250 ms blocks (the chain's own block numbers are read from ArbSys there). The poster, any arm or
  any keeper may call it; a poster should send `draw` right after `post`. Missing the window costs
  time, never funds: the escrow comes back through `cancel` one day after posting. A poster can
  still post several jobs and prefer one; every posted job can be drawn by anyone and then costs
  its fees.
- With two arms, a key where one arm answers UNKNOWN and the other a value has one vote: it is
  UNRESOLVED without a tie break, the abstaining arm is not struck and the answering arm earns
  nothing for that key. UNKNOWN is an abstention by design; accepted for v1. Readers should treat an
  UNRESOLVED key as "no answer", not as a negative answer.
- Registering forms and holding a lifetime server index do not prove identity. Stale server entries
  can make filling sparse pools expensive across many bounded calls. Keepers must progress jobs or
  cancel/settle at deadlines. Posting and then timing out can temporarily lock capacity for gas cost.
- The court owner may set the Intake/asset/action together with `setOracleConfig` and rotate the
  attester with `setSigner`; both emit events and reject zero configuration. New requests use the
  new configuration; old requests remain authenticated by their original Intake, namespaced by
  Intake address plus request ID. Signer rotation immediately revokes the old signer for every
  pending case. The owner cannot call `rule`, move core funds or change core parameters, but can
  choose a dishonest attester, so the owner is explicitly trusted for verdict integrity. Price
  changes are read live under the challenger's ceiling, and an unsold action fails with
  `ActionNotSold`. Renouncing court ownership also renounces future migration recovery.
  No-result requests still consume their oracle price permanently.
- Forms and evidence must remain publicly available. URI character validation and quoting protect the
  question boundary; they do not make a remote document trusted or immutable.
- Operational calls need transactions and gas; there is no paid keeper or protocol treasury. No live
  oracle smoke request was sent by this job. A later operator must check a real form question before
  paying and record the eventual ask/request/callback identifiers separately.

## Public Sepolia readings and execution status

Read on 2026-11-12 through [PublicNode](https://ethereum.publicnode.com/?sepolia), using
`https://ethereum-sepolia-rpc.publicnode.com`. The closing block was **12,121,156**,
hash **0x86bdfba226ef1b0847d1ba569407291985629896f3b91afb2cc7e2abbcae3da8**, eight blocks
behind the observed head. A second read confirmed the same block hash.
[The saved readback](docs/evidence/sepolia-readback.json) contains the RPC inputs/results and
live API fields. It contains public chain state only.

| Address / parameter | Observed value and source |
| --- | --- |
| Launch owner | `0xcc4e8639884d08033597def041f966e8be5bc514`, supplied by this assignment |
| Intake v2 | `0xa43e6f75ee006411f79ac1c84120606c2330de82` |
| imdTEST / chosen real check target | `0x56bcf2a5f47710649a4091219ef0b56e2d1b58bf` |
| Oracle attester | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` |
| Target owner root | `0x047f606fd5b2baa5f5c6c4ab8958e45cb6b054b7`, `owner()` then empty code at the pinned block |
| Oracle action price | `500000000000000000` imdTEST minor units (0.5), API and `priceOf` agree |
| Intake callback limit | **1,000,000 gas**, live `callbackGas()` |

Addresses and price were sourced from [IMD on-chain docs](https://imd.fun/skill/onchain.md),
[capabilities](https://api.imd.fun/requests/capabilities), and the live
[oracle attester API](https://api.imd.fun/oracle/requests?limit=1), not inferred from a remembered deployment.
The existing [ImdTest](https://eth-sepolia.blockscout.com/address/0x56bcf2a5f47710649a4091219ef0b56e2d1b58bf?tab=contract)
and [Intake](https://eth-sepolia.blockscout.com/address/0xa43e6f75ee006411f79ac1c84120606c2330de82?tab=contract)
have verified sources on Blockscout; full responses are saved beside the readback. ImdTest's explorer
status is a **partial compilation match**, not full metadata verification; its returned deployed
runtime exactly matches the pinned-block RPC bytes. `approve` and `transferFrom` return ABI `true`
in zero-value `eth_call` simulations, and the verified ERC-20 source confirms their normal return types.
No simulation sent a transaction.

| Requested live step | Address / transaction hashes / outcome |
| --- | --- |
| Deploy MockToken, IMDCourt, Arms | **Not executed**. No release addresses or transaction hashes exist in this task. |
| Verify those sources and the ArmsForms/ArmsResults children | **Pending network deployment**. Existing Intake/imdTEST verification does not verify these new contracts. |
| Register form; fund/bond/serve three test wallets | **Not executed**. No registration hash or wallet transaction hashes. |
| Post/draw/commit/reveal/settle the honest check | **Not executed on Sepolia**; exercised by the offline integration tests. |
| Post the deliberate wrong Key 9; challenge; oracle callback; resolve | **Not executed on Sepolia**. No paid request ID, ruling, slash/refund/reward/burn transaction logs or ruling duration. |
| Gas used by a real oracle callback | **Not measured**, because no live callback occurred. The local trace used **57,622 gas** under a 200,000 stipend; this is not a live receipt measurement. |

The [prior job API](https://api.imd.fun/jobs/4b3cfe61-1fc8-4a42-a97d-c31245fe3f52) reports
`launch.requested: false` and delivered commit `6afdcba7c3e53da390012c2e54a9b03aa6fe0f79`.
This assignment is a worker build/adaptation step; the network deployer runs the launch after
acceptance. No mock-court ruling is represented as a real oracle decision.

## Control Map v1 and evidence

[forms/control-map-v1.txt](forms/control-map-v1.txt) defines all 13 facts, the proxy patterns,
three-hop owner/admin walks, encoding, and the distinction between NO, NOT_APPLICABLE and UNKNOWN.
The two sentinel values are exactly Arms' hash constants; other enums are right-padded ASCII,
and addresses are left-padded 20-byte values. Human Key 9 is Arms index **8**.

[control-map-answers.json](docs/evidence/control-map-answers.json) contains the 13 actual readings,
with one independently identified evidence file per key (`docs/evidence/key-01.json` through
`key-13.json`). For the pinned ImdTest target the facts are:

| Key | Fact |
| --- | --- |
| 1 | NO standard proxy |
| 2, 3 | NOT_APPLICABLE: no separate implementation/admin/beacon |
| 4 | Owner root `0x047f606fd5b2baa5f5c6c4ab8958e45cb6b054b7` |
| 5 | NO_CODE |
| 6, 7 | NOT_APPLICABLE: no admin root/type |
| 8 | NO replaceable logic |
| 9 | YES: owner/minter-authorized mint and mintBatch |
| 10 | NONE: no explicit mint cap |
| 11, 12 | NO transfer restriction/tax power |
| 13 | NONE: the existing mint power has no enforced wait |

The second check intentionally submits `bytes32("NO")` for Key 9 from two arms. The correct
challenge is `bytes32("YES")`. Evidence files always retain the correct reading. If a third arm
is drawn, it submits the true vector and is not slashed. Both the two-arm case and three-arm
spot-check case pass the local integration tests through **IMDCourt**, with MockIntake and an
explicitly local test attester. Those signatures have no live oracle authority.

## After launch

1. The network deployer uses `launch.json`; the independent reviewer verifies the new court
   configuration role. The owner needs no initialization call. Preserve the compiler/settings and
   publish this accepted tree. Verify all five created contracts: MockToken, IMDCourt, Arms,
   ArmsForms (constructor arguments: the real Arms address and `1000000000000000000`), ArmsResults
   (no arguments). Record the actual addresses, receipt hashes and explorer verification results.
   Operator-only verification can use `forge verify-contract` with chain `11155111`, verifier
   `blockscout`, URL `https://eth-sepolia.blockscout.com/api/`, the exact built source identifier,
   and the ABI-encoded constructor arguments. No worker deployment/broadcast is part of this tree's checks.
2. Resolve the accepted **published commit**, not the base commit and not `main`. Run
   `python3 -B script/prepare_control_map.py --commit <published-40-hex-commit> --arms <confirmed-Arms-address>`.
   This read-only helper fetches the raw file and compares its exact bytes, checks Sepolia and deployed
   code, verifies the oracle signer and the evidence block hash, then prints unsigned registration,
   serve and post calldata. Its URI is
   `https://raw.githubusercontent.com/identity-md-launches/launch-3241-build-test-deploy-sepolia/<commit>/forms/control-map-v1.txt`.
   The final URI/formId cannot be truthfully fixed before the worker publishes the commit. Submit
   `registerForm(textHash,13,uri)` once and retain the receipt. Check the returned formId against the helper.
   Targets on Robinhood Chain (4663) are admitted only after the court owner publishes a confirmed
   head for it with `IMDCourt.setConfirmedHead(4663, head)`, using a height it has itself confirmed
   as final; the Sepolia check and challenge below need no head, since Sepolia is the executing chain.
3. The owner transfers at least 500 ARMT to each of three test wallets, plus poster escrow and
   challenger stake funds. Each arm approves Arms for its intended bond, bonds (500 ARMT in the
   test plan), and calls `serve(formId,1e18)`. The poster and challenger are distinct from the arms.
   Obtain 0.5 imdTEST for the challenger from its authorized issuer; this is the live oracle payment
   asset, not the newly deployed ARMT. Record every funding, approval, bond and serve receipt.
4. Post the honest job in a block after enrollment; escrow is 3 ARMT. Draw as soon as the block
   following the posting block is mined and within the 256-block hash availability window. All
   drawn arms first commit `keccak256(abi.encode(jobId,arm,values,salt))`; only then reveal the true
   13-word vector with each arm's salt and the immutable evidence URI. Settle immediately when
   all responses arrive; the six/two-hour windows are upper deadlines, not mandatory waits.
5. Repeat for the deliberate wrong Key 9 job. Exactly two drawn arms use the wrong value; a third,
   if drawn, answers truthfully. Challenge index 8 with YES, with separate ARMT stake approval and
   exact imdTEST fee approval to Arms. Before paying, obtain the exact `question` and `bodyOf`
   from IMDCourt using the actual immutable form URI and values. Run both the short
   `/requests/check` and full unpaid `/requests/quote`; the final form must be reachable and
   blockers absent. `script/AskSepolia.s.sol` is an old direct-court diagnostic fixture, **not** this
   Arms challenge flow; its hard-coded fixture form must not be used to spend the oracle fee.
6. Follow `CaseOpened`/Intake `Requested`, `/intake/11155111/<challenge-tx-hash>` and the returned
   oracle request URL. Record refusal/failure responses exactly if they occur. Do not replace a
   missing real answer with MockCourt. On a real signed ruling, call `resolve(jobId,8,YES)` and
   retain receipt logs. In the two-arm wrong-agreement case, expected ARMT amounts are:
   **20 slashed**, **2 poster refund**, **5.4 reward**, **2 stake returned**, **12.6 burned** at
   resolve; the earlier settlement separately burned 0.2 ARMT. For a spot check, compute these
   from `job.spent`, since the honest third arm earns its correct-key fraction. The test asserts
   exact accounting and logs for both cases. Record callback gas from the call trace, separately
   from total receipt gas; record ask-to-callback block timestamp difference and API attestation time.
7. A refusal/no quorum/missing callback does not produce a ruling. Preserve status, reason,
   `agreed`/`answered` and `Completed.delivered`, and report what failed. After the unchanged
   seven-day court deadline, `resolve` returns the ARMT stake with NONE; the imdTEST price is spent.
   That wait and the seven-day tranche release are later operator actions, not waits performed
   in this worker run. Do not shorten the accepted windows to manufacture a successful demo.
8. For later protocol migration, the owner calls `IMDCourt.setOracleConfig(intake,asset,action)`
   using current IMD docs/capabilities, or `setSigner(attester)` using the attester API. Configuration
   is already complete at launch. Price comes from `priceOf`; no owner price override exists.

## Observed documentation differences

- The pinned oracle guide/example allowed a string-valued `consumer`. The current HTTP schema
  requires `{chainId,verifyingContract}`: the string probe returned **HTTP 400, invalid_request**;
  the corrected identical unpaid body returned **HTTP 201, created: true**.
  [Saved preflight](docs/evidence/consumer-schema-preflight.json). The live wording check returned
  **HTTP 200, judged: true, blockers: []**, with an evidence suggestion; it checked a real-target
  sample, not the unpublished form's final question.
- The pinned guide says 200,000 callback gas. Current docs say Sepolia has 1,000,000, and the
  pinned-block `callbackGas()` read confirmed it. The local mock deliberately retains the stricter
  200,000 allowance; the recorded local callback used **57,622 gas**. See
  [offline-rehearsal.json](docs/evidence/offline-rehearsal.json).
- The checker suggests chain evidence for the source-based mint question. Existing reproducible
  chain recipes do not encode arbitrary source/control-flow judgments or a three-way form ruling;
  the court retains panel evidence. The unpaid full-body quote accepted that choice. This is not
  proof the final paid panel will reach quorum.
- The supplied Intake, imdTEST, oracle action, attester and 0.5 price did match current data.
  Nothing here claims an observed paid refusal, quorum result or callback failure.

## Offline verification

Run at the repository root. The protected Foundry configuration is unchanged.

```sh
forge build --offline
forge test --offline --fuzz-seed 0xbb9bca8deff02f9da71b5d08331d93944cee71e7ae2814ed12bf442e09ee76df
forge test --offline --fuzz-seed 0x123456 --fuzz-runs 1000
forge fmt --check
python3 script/check_launch.py
python3 -B test/test_deliverables.py
slither . --exclude-informational --exclude-optimization --exclude-low --exclude-medium
```

`forge script script/Deploy.s.sol:Deploy --offline --chain 11155111` is a local dry run, with no
RPC or broadcast. `DeployTest` calls `deploy(Config)` directly, including the empty-chain constructor
rehearsal and wrong-chain rejection. Tests read no files/environment and require no RPC.
`script/read_sepolia.py` is a separate manual public-read evidence collector; it is never run by the
Solidity build/tests. Recollecting a different block also requires updating all per-key evidence and
answers consistently; the structural tests reject mixed snapshots.

See [REVIEW.md](REVIEW.md) for final counts, size margin, gas trace and static-analysis disposition.
The audit-judge tool was not exposed and `audit-judge` returned `command not found` (exit 127).
Independent review and the actual deployment/registration/two paid workflows remain open.
