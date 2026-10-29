# TakumiPay 2.2.0: response to the Olympix BugPoCer scan and mutation testing

Scan: BugPoCer Full Scan of `src/TakumiPay.sol` at commit `af071e0`, 23 October 2026
(2 Medium, 28 Low, 11 distinct issues). Mutation testing: 248 mutants, 193 killed.
Response date: 29 October 2026. Fixes: commit `df0bb24` (TakumiPay 2.3.0), on top of the
scanned `af071e0`.

2.2.0 was never deployed. Every live proxy still runs 2.1.0. The fixes below ship in
**2.3.0**, which replaces 2.2.0 as the next release and is the version the live proxies
will upgrade to. The version string changed so the audited bytecode (`af071e0`) and the
fixed bytecode cannot be confused. 2.3.0 is 24,215 bytes, 361 under the EIP-170 limit
that Arc enforces.

## Summary

| # | Issue | Reported | Response |
|---|---|---|---|
| 5.1.1 | Cross-flow refId double use front-run | Medium, Verified | **Resolved by the report's second remediation, which the backend already implements**: merchant payments are credited against their PaymentIntent whichever flow used the refId first. The on-chain double use is intended. NatSpec corrected. |
| 5.1.2 | Unvalidated native alias token enables uncapped rescue | Medium | **Fixed.** `rescueNativeDust` refuses an alias reporting under 6 decimals, so it can never send 1e12 wei or more on any chain. |
| 5.2.1 | Pending timelock entries survive a `withdrawalDelay` increase (a–g) | Low ×7 | **Fixed.** Raising the delay restarts the clock for everything already queued. |
| 5.2.2 | Tumbling sweep-cap window allows a 2× burst (a–f) | Low ×6 | **Fixed.** The window is replaced by an exact trailing-24h limit: no 24h span can see more than `sweepCap` leave. |
| 5.2.3 | Unsigned refIds can be front-run and squatted (a–d) | Low ×4 | **Acknowledged.** Griefing only: no funds lost, and the squatter is never credited. |
| 5.2.4 | Emergency brake bypassed by a stale pending raise | Low | **Fixed.** `setSweepCap` also cancels a queued raise for that token. |
| 5.2.5 | Non-fee exits do not reserve `platformFeeAccrued` (a–c) | Low ×3 | **Fixed.** `sweepMerchantBacking` reserves accrued fees, and any exit that takes fee-backed balance books those fees as swept, so the ledger stays backed. |
| 5.2.6 | Privileged loosenings bypass the timelock (a–c) | Low ×3 | **Acknowledged, by design.** README corrected to say exactly what is queued. |
| 5.2.7 | `depositPoints` skips `maxTransactionAmount` | Low | **Resolved by the report's alternative fix**: documented that the limit covers bookings only, as on the Solana sibling. |
| 5.2.8 | Unbound booking payment amount | Low | **Disputed.** The API checks amount, payer, token and booking against its own records. |
| 5.2.9 | Upgrade queue not bound to code | Low | **Fixed.** Code must exist at queue time, and the queue stores its codehash. |
| — | Mutation testing: 55 surviving mutants | — | 4 are tool artifacts and 2 are equivalent. New tests kill all of the other 49. |

Regression tests for the fixes are in `test/TakumiPayAuditFixes.t.sol`. Test names carry
the section numbers, e.g. `test_5_2_1_delayRaise_rearmsUpgradeQueuedAtZeroDelay`.

### Every finding, one by one

All 30 findings, each with the test that replays its attack path against 2.3.0, or the
reason no code change is made. Tests are in `test/TakumiPayAuditFixes.t.sol` unless
noted.

| Finding | Attack path | Status in 2.3.0 | Evidence |
|---|---|---|---|
| 5.1.1 | Booking or deposit claims a pending quote's refId first | Payment settles normally; squat never credited | `test_5_1_1_bookingSquat_merchantRecordStillNamesPayer`, `test_5_1_1_depositSquat_merchantRecordStillNamesPayer`; API settlement code (below) |
| 5.1.2a, b | Owner key sets a 0-decimal alias, rescues ~1 native coin | Blocked | `test_5_1_2_revert_rescueNativeDust_zeroDecimalAlias`, `…aliasLowersDecimalsLater`, `testFuzz_5_1_2_rescueNativeDust_neverReaches1e12` |
| 5.2.1a, f | Upgrade queued at delay 0 applied after the delay is raised | Blocked until the full new delay | `test_5_2_1_delayRaise_rearmsUpgradeQueuedAtZeroDelay` |
| 5.2.1b, d, e | Delay cut queued under a short delay applied after a raise | Blocked until the full new delay | `test_5_2_1_delayRaise_rearmsPendingDelayCut` |
| 5.2.1c, g | Cap raise queued at delay 0 applied after the delay is raised | Blocked until the full new delay | `test_5_2_1_delayRaise_rearmsCapRaiseQueuedAtZeroDelay` |
| 5.2.1 (executeWithdrawal) | Withdrawal queued under a short delay executed after a raise | Blocked until the full new delay | `test_5_2_1_delayRaise_rearmsQueuedWithdrawal` |
| 5.2.2a | Boundary burst via `sweepPlatformFees` | Blocked | `test_5_2_2a_noBoundaryBurst_sweepPlatformFees` |
| 5.2.2b | Boundary burst via `recoverToken` | Blocked | `test_5_2_2b_noBoundaryBurst_recoverToken` |
| 5.2.2c | Boundary burst via `withdraw` | Blocked | `test_5_2_2c_noBoundaryBurst_withdraw` |
| 5.2.2d | Boundary burst via `sweepMerchantBacking` (s, cap - s, cap) | Blocked | `test_5_2_2d_noBoundaryBurst_sweepMerchantBacking` |
| 5.2.2e | Boundary burst via two queued withdrawals | Blocked | `test_5_2_2e_noBoundaryBurst_executeWithdrawal` |
| 5.2.2f | Boundary burst via `withdrawAll` | Blocked | `test_5_2_2f_noBoundaryBurst_withdrawAll` |
| 5.2.2 (invariant) | Any mix of exits at any times | No 24h span above the cap | `testFuzz_5_2_2_noDaySeesMoreThanTheCap` |
| 5.2.3a–d | Front-run a booking or deposit with the same refId | Victim's call reverts with no funds moved; squat never credited | Acknowledged: griefing only (section 5.2.3) |
| 5.2.4 | Queued raise applied after the brake | Brake cancels the raise | `test_5_2_4_brakeCancelsQueuedRaise` |
| 5.2.5a | Fee ledger desync across non-fee exits | Ledger stays backed | `test_5_2_5a_partialWithdraw_booksOnlyTheFeesItTook`, `…withdrawAboveFees_leavesLedgerAlone`, `…executeWithdrawalAndRecoverToken_keepLedgerBacked` |
| 5.2.5b | Backing sweep takes fee-backed balance | Blocked | `test_5_2_5b_merchantBackingCannotTakeAccruedFees`, `test_5_2_5_nativeWithdrawAll_unblocksNativeAlias` |
| 5.2.5c | `withdrawAll` leaves a stale fee ledger | Ledger cleared, fees booked as swept | `test_5_2_5c_withdrawAll_booksTheFeesItTookAsSwept` |
| 5.2.6a | Immediate ownership handover | By design (stated in scoping) | Section 5.2.6 |
| 5.2.6b | Immediate signer rotation | By design; dust quotes do not settle | Section 5.2.6 |
| 5.2.6c | Immediate allowlist addition | By design; junk tokens never credited | Section 5.2.6 |
| 5.2.7 | Deposits ignore `maxTransactionAmount` | Documented as booking-only (the report's alternative fix) | NatSpec on `maxTransactionAmount`, README |
| 5.2.8 | Dust-priced booking | Not credited: API checks the amount | Section 5.2.8 |
| 5.2.9 | Empty or later-changed implementation queued | Blocked | `test_5_2_9_revert_queueUpgrade_addressWithoutCode`, `…queueStoresCodehash`, `…revert_upgrade_whenCodeChangedAfterQueue` |

## Correction to the threat model we supplied

During context validation we said the off-chain API "credits by refId only, first use
wins". That was inaccurate, and several findings (5.1.1, 5.2.3, 5.2.6b/c, 5.2.8) build their
impact on it. The actual rules:

- **Bookings** (`createTransaction`, `createTransactionBatch`) are credited only after
  `getTransactionByRef(refId)` matches the server-side booking on the payer wallet (the
  session wallet), token, exact amount, `bookingId`, `productVariantId` and `exchangeRateId`.
  The global `ReferenceId` table is used only by this purchase flow.
- **Point deposits** are credited only after `getPointDepositByRef(refId)` matches the
  session wallet, token and amount. The token must be an active stablecoin in the API's
  token table. Idempotency is keyed per (user, chain, contract, refId), not by refId alone.
- **Merchant payments** settle against their PaymentIntent. The submitted transaction
  must emit `MerchantPaymentProcessed` for the intent's refId. The record from
  `getMerchantPaymentByRef(refId)` must then match the signed quote on merchant, token,
  amount, fiat amount and exchange rate. Booking and deposit records under the same string
  are never read, and PaymentIntent ULIDs never enter the `ReferenceId` table.

"First use wins" holds only as idempotency within a flow. A record is credited only if it
matches what the backend expected.

## Medium

### 5.1.1 Cross-flow refId double use front-run: Disputed

The PoC is correct on-chain. A 1-unit booking or deposit can claim a pending quote's ULID,
and the merchant payment still succeeds. This is the documented choice that
`test_merchantPayment_cannotBeBlockedByBookingFrontRun` pins: if `processMerchantPayment`
checked the unsigned maps, anyone could make a signed quote permanently unpayable with a
cheap front-run.

The claimed loss does not follow. Merchant settlement reads only the merchant record and
the intent's own `MerchantPaymentProcessed` log (see above). So the payer's payment
settles normally. The attacker's 1-unit booking cannot be credited as a purchase, because
no booking in the API matches its wallet, amount or `bookingId`. The attacker loses the
unit to the treasury, and nobody else loses anything.
`test_5_1_1_bookingSquat_merchantRecordStillNamesPayer` and
`test_5_1_1_depositSquat_merchantRecordStillNamesPayer` replay the PoC's sequence. They
show that the merchant record still names the real payer and the quoted amount, and that
the squatting record is separate.

This is the second remediation the report proposes ("have the backend credit
MerchantPaymentProcessed against its PaymentIntent no matter which flow used the refId
first"), and the backend already works this way. We did not take the first one (a
reserved refId format for unsigned flows): it would need a format change across the API
and mobile app to guard against a loss that cannot happen.

Changes:
- The `_isRefIdUsed` NatSpec gave the wrong reason. It said the open direction is safe
  because nobody can learn a ULID early, which is false once the quote is in the mempool.
  It now gives the real reason: merchant settlement never consults the unsigned maps.
  Anything that credits from on-chain records has to keep the flows apart the same way.
- `docs/security-review-2.1.0.md` (M-1) said point deposits claim the `ReferenceId`
  table. They stopped doing so on 2026-10-23, and that text is corrected.

### 5.1.2 Unvalidated native alias token enables uncapped rescue: Fixed

Agreed that this broke the stated bound. It was reachable only with the owner key, on a
chain whose proxy has no alias (any non-Arc chain), and it was limited to under one native
unit. On Arc the alias is set atomically in `initialize` and is set-once.

`rescueNativeDust` now reverts with `AliasDecimalsUnsupported` when the alias reports
fewer than 6 decimals, so the remainder it sends is always under 1e12 wei (10⁻⁶ of a
native unit) on any chain, whatever token the alias points to. The check is at the point
of use because `decimals()` is read live and a token can change what it returns. Tests:
`test_5_1_2_revert_rescueNativeDust_zeroDecimalAlias` (the report's path),
`test_5_1_2_revert_rescueNativeDust_aliasLowersDecimalsLater`, and
`testFuzz_5_1_2_rescueNativeDust_neverReaches1e12` (any decimals 0–30, any balance).

## Low

### 5.2.1 Pending timelock entries survive a `withdrawalDelay` increase (a–g): Fixed

Agreed. Raising the delay is the natural emergency response, and it did not reach
entries already queued: upgrades, cap raises, delay cuts and queued withdrawals. The
runbook case (f/g) was real too.

A new slot, `withdrawalDelayRaisedAt`, is set by `setWithdrawalDelay`. `_consumePending`
(behind `_authorizeUpgrade`, `applySweepCap` and `applyWithdrawalDelay`) and
`executeWithdrawal` now also require `block.timestamp >= withdrawalDelayRaisedAt +
withdrawalDelay`. Raising the delay, or calling `setWithdrawalDelay` again with the
current value, restarts the full current delay for every queued loosening and withdrawal.

This differs from the suggested per-entry `queuedAt` on purpose. It needs no struct
change, it covers `withdrawalRequests` with the same check, and it is at least as strict,
because the raise always comes after the queue. Entries queued after a raise are
unaffected: their own unlock time is always the later of the two. Tests: one per path
(`…rearmsUpgradeQueuedAtZeroDelay`, `…rearmsCapRaiseQueuedAtZeroDelay`,
`…rearmsPendingDelayCut`, `…rearmsQueuedWithdrawal`), plus
`test_5_2_1_reassertingDelay_restartsClock` and
`test_5_2_1_entryQueuedAfterRaise_unlocksOnItsOwnTime`.

Two parts of the report are deliberately left as they are:
- `applyWithdrawalDelay` does not re-check `value < withdrawalDelay`. A cut can now land
  only after it has been visible for the full current delay. That is the timelock working,
  and the owner can cancel it at any point in that window.
- No expiry is added. With the re-arm, an expiry would add a parameter and little else.

### 5.2.2 Tumbling sweep-cap window allows a 2× burst (a–f): Fixed

Agreed. We named this as in scope, and the README's "rolling" was wrong. The fix meets
the bar each sub-finding sets: no 24h span can see more than `sweepCap` leave.

`_consumeSweepAllowance` now keeps a small per-token log of recent capped exits (up to
16), each with its time and amount, in a new mapping `_sweepLog`. An exit passes only if
it, plus every exit in the trailing 24 hours, stays within `sweepCap`. Each exit's share
of the cap comes back exactly 24 hours after it was made. A live entry is never
overwritten: a 17th exit within 24 hours reverts with `SweepLogFull` until the oldest
expires. Today's sweeps are manual CLI runs, a few per day at most. Every capped exit
shares the one log: both sweeps, `withdraw`, `withdrawAll`, `executeWithdrawal` and
`recoverToken`. A new view, `sweepAllowance(token)`, returns what can leave right now.

The bound is exact by construction. Take any 24h span: when its last exit was checked,
every earlier exit in the span was still in the log and was counted. So the span's total
is at most `sweepCap`. `setSweepCap(token, 0)` still stops everything at once, with no
queue.

One consequence for operations, which the invariant itself requires: after a full-cap
exit, nothing more leaves for 24 hours. Daily settlement must keep each day's exits within
the cap, measured over the trailing 24 hours rather than per calendar day.

Tests replay each sub-finding's path through its own entry point:
`test_5_2_2a_…sweepPlatformFees`, `b_…recoverToken`, `c_…withdraw`,
`d_…sweepMerchantBacking`, `e_…executeWithdrawal`, `f_…withdrawAll`. Each runs the
report's sequence (s, then cap - s at W + 1 day - 1s, then a full cap at W + 1 day) and
shows the third exit is refused with exactly one cap out.
`testFuzz_5_2_2_noDaySeesMoreThanTheCap` runs random sweeps and withdrawals at random
times and checks the invariant over every 24h span. Further tests cover exact expiry,
the 16-entry log, a cap lowered below what the trailing 24 hours already hold, and a
near-maximum cap.

### 5.2.3 Unsigned refIds can be front-run and squatted (a–d): Acknowledged

The front-run works on-chain, and its effect is limited to griefing:
- The victim's call reverts atomically, so their tokens never move. Only gas is lost.
- The squatter's record is never credited, because the API matches payer wallet, token
  and amount (see the correction above). The squatter loses their 1 unit to the treasury.
- The payment has to be retried under a fresh refId. A squatted refId in a batch reverts
  that batch once.

Binding refIds to the payer was considered. Keying the maps by `keccak256(payer, refId)`
changes `getTransactionByRef` / `getPointDepositByRef`, which the API reads, and it would
undo the cross-flow idempotency that 2.2.0 introduced. Signed booking and deposit quotes
would remove the issue, but they are a redesign of the unsigned flows that we are not
taking on in this release. We will revisit both if squatting shows up in practice. On
Arbitrum One the sequencer orders transactions first-come-first-served with no public
mempool, which makes the attack harder there.

### 5.2.4 Emergency brake bypassed by a stale pending raise: Fixed

During validation we called this acceptable because the runbook cancels pending raises
alongside the brake. On reflection, an emergency brake should be one call, and the NatSpec
promised that. `setSweepCap` now cancels any queued raise for the token and emits
`PendingChangeCancelled`, so a tightening always supersedes a pending loosening. Tests:
`test_5_2_4_brakeCancelsQueuedRaise` and
`test_5_2_4_brakeWithNothingQueued_emitsOnlyTheCapUpdate`.

### 5.2.5 Non-fee exits do not reserve `platformFeeAccrued` (a–c): Fixed

Both of the report's suggested fixes are applied, each where it fits:

- **`sweepMerchantBacking` (b)** is the exit labelled non-fee, so it is bounded by
  `balance - platformFeeAccrued[token]`. It reverts with `InsufficientBalance` when the
  balance does not cover accrued fees.
- **`withdraw`, `withdrawAll`, `executeWithdrawal`, `recoverToken` (a, c)** are
  whole-treasury exits, and holding fees back would break `withdrawAll`. They take the
  report's other fix instead. After any transfer out, if the balance left is below
  `platformFeeAccrued[token]`, the ledger is lowered to the balance. The difference is
  emitted as `PlatformFeesSwept(token, recipient, amount)`, because those fees left with
  that exit. The ledger therefore never claims fees the contract no longer holds, and a
  later fee sweep cannot take merchant float.

This happens in `_sendOut`, the single path every exit uses. A stale native fee ledger
also can no longer block `setNativeAliasToken`. None of the live proxies has accrued fees
above its balance today (checked on forks, see "Upgrade readiness").

Tests: `test_5_2_5b_merchantBackingCannotTakeAccruedFees`,
`test_5_2_5c_withdrawAll_booksTheFeesItTookAsSwept`,
`test_5_2_5a_partialWithdraw_booksOnlyTheFeesItTook`,
`test_5_2_5a_withdrawAboveFees_leavesLedgerAlone`,
`test_5_2_5a_executeWithdrawalAndRecoverToken_keepLedgerBacked`, and
`test_5_2_5_nativeWithdrawAll_unblocksNativeAlias`.

### 5.2.6 Privileged loosenings bypass the timelock (a–c): Acknowledged, by design

As stated during validation, only cap raises, delay cuts and upgrades are queued. The
README's "loosening a control is never a single call" over-claimed. It now lists what is
queued, what is not, and why.

- **(a) Ownership handover.** An immediate transfer is the defender's main move when the
  key leaks: rotating to a fresh key. A timelock would delay the legitimate rotation
  exactly as much as the attacker's, and whoever transfers first wins either way. The real
  mitigation is a multisig owner, which we already recommend for mainnet volumes.
- **(b) Signer rotation.** Same reasoning: rotation is how a leaked signer key is revoked,
  so it has to be instant. Attacker-signed dust quotes do not settle PaymentIntents,
  because settlement compares the on-chain amount, merchant, token, fiat amount and rate
  with the intent. The remaining effect is griefing: the attacker can consume a pending
  intent's refId, and the intent has to be re-issued.
- **(c) Allowlist additions.** A junk token is never credited. Bookings must match the
  booking's expected token, and deposits must use an active stablecoin from the API's
  token table, matched by address.

### 5.2.7 `depositPoints` skips `maxTransactionAmount`: Resolved by documentation

The report offers two fixes: enforce the limit in `depositPoints`, or document that it
covers bookings only. We took the second. `maxTransactionAmount` is a per-booking limit,
and the Solana sibling applies its spending limit to transactions only, not to point
deposits. Enforcing it here would put the two chains out of step. The NatSpec on
`maxTransactionAmount` and the README now say it applies to bookings.

### 5.2.8 Unbound booking payment amount: Disputed

The finding depends on the API crediting a booking by refId without checking amount and
token. It does not: `verifyTransactionInContract` rejects any on-chain record whose
amount, token, wallet, `bookingId`, `productVariantId` or `exchangeRateId` differs from the
server-side booking. Bookings are priced off-chain by design, and the contract records the
payment, which the API then verifies.

### 5.2.9 Upgrade queue not bound to code: Fixed

Agreed. The timelock exists so the implementation can be reviewed, and that needs code
to review. `queueUpgrade` now reverts with `NoImplementationCode` for an address without
code. The queue stores the implementation's codehash instead of its address, and
`_authorizeUpgrade` compares the codehash of the address being upgraded to. A UUPS
implementation embeds its own address as an immutable, so the codehash pins the address
as well. Tests: `test_5_2_9_revert_queueUpgrade_addressWithoutCode`,
`test_5_2_9_queueStoresCodehash`, and
`test_5_2_9_revert_upgrade_whenCodeChangedAfterQueue`, where `vm.etch` swaps the code
after queuing.

### Also fixed: `__gap` NatSpec

The contract header said `__gap` reserves 50 slots, while the array had 45. It now
states the rule (append before `__gap`, shrink it by the same number of slots) instead
of a number that drifts.

## Mutation testing

193 of 248 mutants were killed (77.8%). We triaged the 55 survivors, re-ran the
suspicious ones against `af071e0`, and then re-ran all 55 against 2.3.0 with the new
tests (`test/TakumiPayCoverage.t.sol`). Each 2.2.0 line was mapped to its 2.3.0 position
by diff before the mutation was applied.

| Category | Mutants (2.2.0 line) | Count | Finding | Against 2.3.0 |
|---|---|---|---|---|
| Tool artifact: mutant breaks every `setUp` | 367 (`onlyOwner` inverted), 400 (`initializer` removed), 402, 403 (zero checks inverted) | 4 | Killed in practice. Each makes `initialize` or the owner's setup calls revert, so 5 of 7 suites fail in `setUp` (verified on `af071e0`). The tool appears to count only individual test failures. Explicit tests were added anyway. | 4 of 4 killed |
| Equivalent | 702, 880 (`memory` → `storage`) | 2 | Same behaviour, different gas. In `_consumePending` the value is read before the `delete`. | 2 of 2 survive, as expected |
| Instant-exit timelock guard | 772, 782, 939 (`withdrawalDelay > 0` → `< 0`) | 3 | **Real gap, the most important.** Nothing tested that `withdraw`, `withdrawAll` and `recoverToken` revert with `TimelockActive` once a delay is set. | 3 of 3 killed |
| `onlyOwner` removed | 469, 769, 780, 816, 821, 842, 848, 853, 859, 887, 912, 925, 963, 972 | 14 | Real gap. One test now calls every owner-only function (27, not just these 14) as a stranger and expects `NotOwner`. | 14 of 14 killed |
| `nonReentrant` removed | 498, 512, 633, 711, 724, 769, 780, 912, 936, 1087, 1193 | 11 | Real gap. An ERC-20 that calls back mid-transfer, and a native recipient that does, re-enter each function. For owner-only functions they re-enter as the owner, so the call reaches `nonReentrant` rather than stopping at `onlyOwner`. | 11 of 11 killed |
| Event not asserted | 472, 612, 796, 823, 845, 856, 862, 876, 922, 958, 969, 988 | 12 | Real gap. Monitoring depends on these, so each is now asserted with `vm.expectEmit`. | 12 of 12 killed |
| Batch spending limit | 534, 535 | 2 | Real gap. Items under, at and over the limit are now tested. | 2 of 2 killed |
| Pagination | 1011, 1021, 1022, 1025, 1058, 1061 | 6 | Real gap: non-zero offsets and the `getTransactionsByAddress` limit were untested. | 6 of 6 killed |
| Allowlist swap-and-pop | 1247 (`idx != lastIdx` → `==`) | 1 | Real gap: removing a token from the middle of the list was untested. | 1 of 1 killed |

Against 2.3.0, 53 of the 55 former survivors are killed. The two left are the equivalent mutants, which no test can kill because they do not change behaviour. Every one of the 248 mutants that can change behaviour is now caught by the suite.

We also mutated every line the fixes added, with 19 mutants of our own:
- an off-by-one at the exact 24h expiry;
- each new check removed;
- the 2.1.0 carry-over window shortened;
- the exit log written without its timestamp;
- the fee-ledger clamp inverted, removed or using `<=`;
- the delay re-arm dropped;
- the upgrade queue storing the address instead of the codehash.

All 19 are killed. Across the 74 mutants run against the final 2.3.0 code, the only
survivors are the two equivalent ones.

We would welcome a mutation pass of your own against 2.3.0.

## The same fixes on our other chains

TakumiPay also runs on Solana (devnet) and Stellar (testnet), with the same treasury
design. Those contracts were outside the scan, but they shared the weaknesses behind
5.2.1, 5.2.2, 5.2.4 and 5.2.5, and they have been fixed the same way. Both also had a gap
the EVM contract had already closed in 2.1.0: their withdrawals skipped the sweep cap.

- **Stellar** (commit `dd90852`): 16 new tests, each replaying one of these attack paths.
  The contract has no in-place upgrade, so the fixes ship as a fresh instance.
- **Solana** (commit `db2fd4e`): the timing rules are unit-tested, including a randomized
  24h invariant, and the fixes are exercised on a local validator. The upgrade, including
  the migration that grows the accounts the deployed program created, was rehearsed from a
  dump of the deployed devnet program.
- 5.1.2 (native alias) and 5.2.9 (upgrade queue) have no counterpart on either chain.

## Upgrade readiness

All eight live proxies (Arc mainnet and testnet, Arbitrum One and Sepolia, Monad mainnet
and testnet, Base Sepolia, Robinhood testnet) return `version() == "2.1.0"` on-chain,
checked on 29 October 2026. 2.1.0's `_authorizeUpgrade`
predates the queue, so 2.1.0 → 2.3.0 is a single owner call, with no migration call
(`upgradeToAndCall(impl, "")`).

- **Storage layout.** We diffed `forge inspect TakumiPay storageLayout` for 2.1.0 and
  2.3.0 with compiler ids normalized. Slots 0–29 and every struct's member layout are
  identical. The only changes are two new slots taken from 2.1.0's `__gap`:
  `withdrawalDelayRaisedAt` at slot 30 and the `_sweepLog` mapping at slot 31. `__gap`
  shrinks from 45 to 43 and still ends at slot 74.
- **New state starts correct.** `withdrawalDelayRaisedAt` reads 0 on an upgraded proxy,
  so entries queued under 2.1.0 keep their unlock times until the delay is next set. The
  sweep log starts empty. 2.1.0's last fixed-window total (`sweptInWindow`) is still
  counted in full until two days after that window opened, the latest any of its exits
  could still be inside a trailing 24 hours. 2.3.0 cannot see exits from the windows
  before that one, so for a clean bound across the upgrade itself, do not sweep in the
  24 hours before upgrading. No live proxy has swept recently.
- **Hermetic upgrade test** (`test/TakumiPayUpgrade.t.sol`). It starts from the verbatim
  2.1.0 source (`test/legacy/TakumiPay210.sol`) and builds a proxy with bookings, a
  batch, a deposit, a merchant payment with a fee, a sweep part-way through its window, a
  delay, a queued withdrawal and a queued cap raise. After the upgrade it checks that:
  every readable value is unchanged; all 75 contract slots are byte-identical; queued
  entries keep their schedule; the 2.1.0 sweep total carries over, so the 24 hours after
  it see exactly one cap; a quote signed before the upgrade settles after it (EIP-712 domain
  unchanged); the next upgrade is queued and timelocked; and an Arc-style aliased proxy
  keeps native closed while rescuing only dust.
- **Fork rehearsal against the live mainnet proxies** (`test/TakumiPayUpgrade.fork.t.sol`,
  Arc 5042, Arbitrum One, Monad 143). Each upgrade is made as the live owner. Every
  readable value and all 75 contract slots are unchanged, and the next upgrade is queued,
  code-bound and waits the live 1-day delay. On no live proxy does `platformFeeAccrued`
  exceed the balance, so the new reserve in `sweepMerchantBacking` blocks nothing.
- **The real upgrade script** (`UpgradeTakumiPay`, unchanged) was simulated as each
  proxy's on-chain owner against Arc, Arbitrum One and Monad mainnet. It reports
  `New version: 2.3.0` on all three.

## ABI changes in 2.3.0

Clients move from 2.1.0, so they also see the 2.2.0 changes listed in
`docs/security-review-2.1.0.md`. New in 2.3.0:

- New views: `withdrawalDelayRaisedAt()` and `sweepAllowance(address)`.
- New errors: `NoImplementationCode`, `AliasDecimalsUnsupported`, `SweepLogFull`.
- Changed meaning, same signatures:
  - `sweptInWindow(token)` and `sweepWindowStart(token)` are no longer written. On an
    upgraded proxy they keep 2.1.0's last window. Use `sweepAllowance` for what can
    leave now.
  - Whole-treasury exits can now emit `PlatformFeesSwept` (see 5.2.5).
  - `getPendingChange(keccak256("upgrade")).value` is the queued codehash, not the
    address. `UpgradeQueued` still carries the address.
  - `queueUpgrade(address(0))` reverts `NoImplementationCode` instead of `ZeroAddress`.

No off-chain client reads the changed getters: the API and the mobile app only carry
them in their ABI copies.
