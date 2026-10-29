# TakumiPay on Arc: our response to the Olympix scan

**Scope:** the BugPoCer Full Scan of `src/TakumiPay.sol` at commit `af071e0` (2 Medium,
28 Low, 11 distinct issues), plus the mutation run (248 mutants, 193 killed). This is
the contract we run on Arc.

**Where the fixes are:** commit `df0bb24`, on top of `af071e0`. They ship as
**TakumiPay 2.3.0**. 2.2.0 was never deployed, and our Arc proxies still run 2.1.0, so
2.3.0 is what they'll upgrade to. We bumped the version so nobody mixes up the code you
scanned with the fixed code. 2.3.0 is 24,215 bytes, 361 under the EIP-170 limit Arc
enforces.

Response date: 29 October 2026.

## At a glance

| # | Issue | Reported | What we did |
|---|---|---|---|
| 5.1.1 | Cross-flow refId double use front-run | Medium, Verified | **Already covered by your second suggested fix.** Our backend credits merchant payments against their own PaymentIntent, whichever flow used the refId first. The on-chain double use is intended. We corrected the NatSpec that gave the wrong reason. |
| 5.1.2 | Unvalidated native alias token enables uncapped rescue | Medium | **Fixed.** `rescueNativeDust` refuses an alias reporting fewer than 6 decimals, so it can never send 1e12 wei or more. |
| 5.2.1 | Pending timelock entries survive a `withdrawalDelay` increase (a–g) | Low ×7 | **Fixed.** Raising the delay restarts the clock for everything already queued. |
| 5.2.2 | Tumbling sweep-cap window allows a 2× burst (a–f) | Low ×6 | **Fixed.** No 24h span can now see more than `sweepCap` leave. |
| 5.2.3 | Unsigned refIds can be front-run and squatted (a–d) | Low ×4 | **Acknowledged.** It's griefing only: nobody loses funds, and the squatter is never credited. |
| 5.2.4 | Emergency brake bypassed by a stale pending raise | Low | **Fixed.** `setSweepCap` also cancels a queued raise for that token. |
| 5.2.5 | Non-fee exits do not reserve `platformFeeAccrued` (a–c) | Low ×3 | **Fixed.** `sweepMerchantBacking` keeps accrued fees in reserve, and any exit that takes fee-backed balance books those fees as swept. |
| 5.2.6 | Privileged loosenings bypass the timelock (a–c) | Low ×3 | **Acknowledged, by design.** We fixed the README, which promised more than the contract does. |
| 5.2.7 | `depositPoints` skips `maxTransactionAmount` | Low | **Your alternative fix:** documented that the limit is per booking. |
| 5.2.8 | Unbound booking payment amount | Low | **Disputed.** Our API checks amount, payer, token and booking against its own records. |
| 5.2.9 | Upgrade queue not bound to code | Low | **Fixed.** The implementation must have code when queued, and the queue stores its codehash. |
| — | Mutation testing: 55 surviving mutants | — | 4 were tool artifacts and 2 are equivalent. New tests kill the other 49. |

The regression tests are in `test/TakumiPayAuditFixes.t.sol`. Test names carry your
section numbers, e.g. `test_5_2_1_delayRaise_rearmsUpgradeQueuedAtZeroDelay`.

### Every finding, one by one

All 30 findings, each with the test that replays its attack path against 2.3.0, or the
reason we didn't change code. Tests are in `test/TakumiPayAuditFixes.t.sol` unless noted.

| Finding | Attack path | Now | Evidence |
|---|---|---|---|
| 5.1.1 | Booking or deposit claims a pending quote's refId first | Payment settles normally; the squat is never credited | `test_5_1_1_bookingSquat_merchantRecordStillNamesPayer`, `test_5_1_1_depositSquat_merchantRecordStillNamesPayer`; API settlement code (below) |
| 5.1.2a, b | Owner key sets a 0-decimal alias and rescues ~1 native coin | Blocked | `test_5_1_2_revert_rescueNativeDust_zeroDecimalAlias`, `…aliasLowersDecimalsLater`, `testFuzz_5_1_2_rescueNativeDust_neverReaches1e12` |
| 5.2.1a, f | Upgrade queued at delay 0, applied after the delay is raised | Waits the full new delay | `test_5_2_1_delayRaise_rearmsUpgradeQueuedAtZeroDelay` |
| 5.2.1b, d, e | Delay cut queued under a short delay, applied after a raise | Waits the full new delay | `test_5_2_1_delayRaise_rearmsPendingDelayCut` |
| 5.2.1c, g | Cap raise queued at delay 0, applied after the delay is raised | Waits the full new delay | `test_5_2_1_delayRaise_rearmsCapRaiseQueuedAtZeroDelay` |
| 5.2.1 (executeWithdrawal) | Withdrawal queued under a short delay, executed after a raise | Waits the full new delay | `test_5_2_1_delayRaise_rearmsQueuedWithdrawal` |
| 5.2.2a | Boundary burst via `sweepPlatformFees` | Blocked | `test_5_2_2a_noBoundaryBurst_sweepPlatformFees` |
| 5.2.2b | Boundary burst via `recoverToken` | Blocked | `test_5_2_2b_noBoundaryBurst_recoverToken` |
| 5.2.2c | Boundary burst via `withdraw` | Blocked | `test_5_2_2c_noBoundaryBurst_withdraw` |
| 5.2.2d | Boundary burst via `sweepMerchantBacking` (s, cap - s, cap) | Blocked | `test_5_2_2d_noBoundaryBurst_sweepMerchantBacking` |
| 5.2.2e | Boundary burst via two queued withdrawals | Blocked | `test_5_2_2e_noBoundaryBurst_executeWithdrawal` |
| 5.2.2f | Boundary burst via `withdrawAll` | Blocked | `test_5_2_2f_noBoundaryBurst_withdrawAll` |
| 5.2.2 (invariant) | Any mix of exits at any times | No 24h span above the cap | `testFuzz_5_2_2_noDaySeesMoreThanTheCap` |
| 5.2.3a–d | Front-run a booking or deposit with the same refId | The victim's call reverts with no funds moved; the squat is never credited | Acknowledged: griefing only (5.2.3 below) |
| 5.2.4 | Queued raise applied after the brake | The brake cancels the raise | `test_5_2_4_brakeCancelsQueuedRaise` |
| 5.2.5a | Fee ledger drifts across non-fee exits | Ledger stays backed | `test_5_2_5a_partialWithdraw_booksOnlyTheFeesItTook`, `…withdrawAboveFees_leavesLedgerAlone`, `…executeWithdrawalAndRecoverToken_keepLedgerBacked` |
| 5.2.5b | Backing sweep takes fee-backed balance | Blocked | `test_5_2_5b_merchantBackingCannotTakeAccruedFees`, `test_5_2_5_nativeWithdrawAll_unblocksNativeAlias` |
| 5.2.5c | `withdrawAll` leaves a stale fee ledger | Ledger cleared, fees booked as swept | `test_5_2_5c_withdrawAll_booksTheFeesItTookAsSwept` |
| 5.2.6a | Immediate ownership handover | By design (stated in scoping) | 5.2.6 below |
| 5.2.6b | Immediate signer rotation | By design; dust quotes don't settle | 5.2.6 below |
| 5.2.6c | Immediate allowlist addition | By design; junk tokens are never credited | 5.2.6 below |
| 5.2.7 | Deposits ignore `maxTransactionAmount` | Documented as booking-only (your alternative fix) | NatSpec on `maxTransactionAmount`, README |
| 5.2.8 | Dust-priced booking | Not credited: the API checks the amount | 5.2.8 below |
| 5.2.9 | Empty or later-changed implementation queued | Blocked | `test_5_2_9_revert_queueUpgrade_addressWithoutCode`, `…queueStoresCodehash`, `…revert_upgrade_whenCodeChangedAfterQueue` |

## Correction to the context we supplied

During context validation we said our API "credits by refId only, first use wins". That
was inaccurate, and several findings (5.1.1, 5.2.3, 5.2.6b/c, 5.2.8) build their impact on
it. Here's how crediting actually works:

- **Bookings** (`createTransaction`, `createTransactionBatch`) are credited only once
  `getTransactionByRef(refId)` matches the server-side booking on payer wallet (the
  session wallet), token, exact amount, `bookingId`, `productVariantId` and
  `exchangeRateId`. The global `ReferenceId` table is only used by this purchase flow.
- **Point deposits** are credited only once `getPointDepositByRef(refId)` matches the
  session wallet, token and amount. The token has to be an active stablecoin in the API's
  token table. Idempotency is keyed per (user, chain, contract, refId), not by refId
  alone.
- **Merchant payments** settle against their PaymentIntent. The submitted transaction has
  to emit `MerchantPaymentProcessed` for the intent's refId. Then the record from
  `getMerchantPaymentByRef(refId)` has to match the signed quote on merchant, token,
  amount, fiat amount and exchange rate. Booking and deposit records under the same
  string are never read, and PaymentIntent ULIDs never go into the `ReferenceId` table.

So "first use wins" is only true as idempotency within one flow. Nothing gets credited
unless it matches what the backend expected.

## Medium

### 5.1.1 Cross-flow refId double use front-run: covered by your second fix

The PoC is right about what happens on-chain: a 1-unit booking or deposit can claim a
pending quote's ULID, and the merchant payment still goes through. That's deliberate, and
`test_merchantPayment_cannotBeBlockedByBookingFrontRun` pins it. If
`processMerchantPayment` checked the unsigned maps, anyone could make a signed quote
permanently unpayable with a cheap front-run.

The loss doesn't follow, though. Merchant settlement only reads the merchant record and
the intent's own `MerchantPaymentProcessed` log, so the payer's payment settles normally.
The attacker's 1-unit booking can't be credited as a purchase either, because no booking
in the API matches its wallet, amount or `bookingId`. The attacker just loses that unit to
the treasury. `test_5_1_1_bookingSquat_merchantRecordStillNamesPayer` and
`test_5_1_1_depositSquat_merchantRecordStillNamesPayer` replay your PoC's sequence and
show the merchant record still naming the real payer and the quoted amount.

That's your second suggested remediation ("have the backend credit
MerchantPaymentProcessed against its PaymentIntent no matter which flow used the refId
first"), and it's how the backend already works. We didn't take the first one (a reserved
refId format for unsigned flows). It would mean a format change across the API and the
mobile app to guard against a loss that can't happen.

What we did change:
- The `_isRefIdUsed` NatSpec gave the wrong reason. It claimed nobody can learn a ULID
  early, which isn't true once the quote is in the mempool. It now gives the real reason:
  merchant settlement never looks at the unsigned maps, and anything that credits from
  on-chain records has to keep the flows apart the same way.
- `docs/security-review-2.1.0.md` (M-1) still said point deposits use the `ReferenceId`
  table. They stopped on 2026-10-23, and that text is fixed.

### 5.1.2 Unvalidated native alias token enables uncapped rescue: fixed

Agreed, this broke the bound we claimed. On Arc the alias is set atomically in
`initialize` and can't change afterwards, so this path doesn't exist on our deployment.
The bound itself was still wrong, so we fixed it anyway.

`rescueNativeDust` now reverts with `AliasDecimalsUnsupported` when the alias reports
fewer than 6 decimals. The remainder it sends is therefore always under 1e12 wei (10⁻⁶ of
a native unit), whatever token the alias points to. The check sits at the point of use
because `decimals()` is read live and a token can change what it returns. Tests:
`test_5_1_2_revert_rescueNativeDust_zeroDecimalAlias` (your path),
`test_5_1_2_revert_rescueNativeDust_aliasLowersDecimalsLater`, and
`testFuzz_5_1_2_rescueNativeDust_neverReaches1e12` (any decimals 0–30, any balance).

## Low

### 5.2.1 Pending timelock entries survive a `withdrawalDelay` increase (a–g): fixed

Agreed. Raising the delay is the obvious thing to do in an emergency, and it didn't
reach anything already queued: upgrades, cap raises, delay cuts or withdrawals. The
runbook case (f/g) was real too.

There's a new slot, `withdrawalDelayRaisedAt`, set by `setWithdrawalDelay`.
`_consumePending` (behind `_authorizeUpgrade`, `applySweepCap` and
`applyWithdrawalDelay`) and `executeWithdrawal` now also require `block.timestamp >=
withdrawalDelayRaisedAt + withdrawalDelay`. So raising the delay, or calling
`setWithdrawalDelay` again with the same value, restarts the full delay for everything
queued.

We went with this rather than a per-entry `queuedAt`. It needs no struct change, the same
check covers `withdrawalRequests`, and it's at least as strict, since the raise always
comes after the queue. Entries queued after a raise aren't affected: their own unlock time
is always the later of the two. Tests: one per path (`…rearmsUpgradeQueuedAtZeroDelay`,
`…rearmsCapRaiseQueuedAtZeroDelay`, `…rearmsPendingDelayCut`, `…rearmsQueuedWithdrawal`),
plus `test_5_2_1_reassertingDelay_restartsClock` and
`test_5_2_1_entryQueuedAfterRaise_unlocksOnItsOwnTime`.

Two parts we left alone on purpose:
- `applyWithdrawalDelay` doesn't re-check `value < withdrawalDelay`. A cut can only land
  after it's been visible for the full current delay, which is the timelock doing its
  job, and the owner can cancel it any time in that window.
- No expiry. With the re-arm in place, an expiry would add a parameter and not much else.

### 5.2.2 Tumbling sweep-cap window allows a 2× burst (a–f): fixed

Agreed. We flagged this as in scope ourselves, and the README's "rolling" was simply
wrong. The fix meets the bar every sub-finding sets: no 24h span can see more than
`sweepCap` leave.

`_consumeSweepAllowance` now keeps a small per-token log of recent capped exits (up to
16), each with its time and amount, in a new `_sweepLog` mapping. An exit only goes
through if it, plus everything in the trailing 24 hours, fits within `sweepCap`. Each
exit's share of the cap comes back exactly 24 hours later. A live entry is never
overwritten: a 17th exit within 24 hours reverts with `SweepLogFull` until the oldest one
expires. That's plenty for us, since sweeps are manual runs, a few per day at most. Every
capped exit shares the same log: both sweeps, `withdraw`, `withdrawAll`,
`executeWithdrawal` and `recoverToken`. A new view, `sweepAllowance(token)`, shows what
can leave right now.

Why the bound is exact: take any 24h span. When its last exit was checked, every earlier
exit in that span was still in the log and got counted, so the span's total is at most
`sweepCap`. `setSweepCap(token, 0)` still stops everything at once, no queue needed.

One operational consequence, which the invariant itself demands: after a full-cap exit,
nothing else leaves for 24 hours. So daily settlement has to budget against the trailing
24 hours rather than calendar days.

The tests replay each sub-finding's path through its own entry point:
`test_5_2_2a_…sweepPlatformFees`, `b_…recoverToken`, `c_…withdraw`,
`d_…sweepMerchantBacking`, `e_…executeWithdrawal`, `f_…withdrawAll`. Each runs your
sequence (s, then cap - s at W + 1 day - 1s, then a full cap at W + 1 day) and shows the
third exit refused with exactly one cap out. `testFuzz_5_2_2_noDaySeesMoreThanTheCap`
throws random sweeps and withdrawals at random times and checks the invariant over every
24h span. More tests cover exact expiry, the 16-entry log, a cap lowered below what the
last 24 hours already hold, and a near-maximum cap.

### 5.2.3 Unsigned refIds can be front-run and squatted (a–d): acknowledged

The front-run works on-chain, but the damage stops at griefing:
- The victim's call reverts atomically, so their tokens never move. They only lose gas.
- The squatter's record never gets credited, because the API matches payer wallet, token
  and amount (see the correction above). The squatter loses their 1 unit to the treasury.
- The payment is retried under a fresh refId. A squatted refId in a batch reverts that
  batch once.

We did think about binding refIds to the payer. Keying the maps by
`keccak256(payer, refId)` changes `getTransactionByRef` / `getPointDepositByRef`, which the
API reads, and it would undo the cross-flow idempotency 2.2.0 added. Signed booking and
deposit quotes would remove the issue entirely, but that's a redesign of the unsigned
flows we don't want to squeeze into this release. If squatting ever shows up in practice,
we'll revisit both.

### 5.2.4 Emergency brake bypassed by a stale pending raise: fixed

During validation we called this acceptable, because our runbook cancels pending raises
along with the brake. Thinking about it more, an emergency brake should be one call, and
the NatSpec promised exactly that. `setSweepCap` now cancels any queued raise for the
token and emits `PendingChangeCancelled`, so tightening always beats a pending loosening.
Tests: `test_5_2_4_brakeCancelsQueuedRaise` and
`test_5_2_4_brakeWithNothingQueued_emitsOnlyTheCapUpdate`.

### 5.2.5 Non-fee exits do not reserve `platformFeeAccrued` (a–c): fixed

We used both of your suggested fixes, each where it fits:

- **`sweepMerchantBacking` (b)** is the exit meant for non-fee money, so it's now bounded
  by `balance - platformFeeAccrued[token]`. If the balance doesn't cover accrued fees, it
  reverts with `InsufficientBalance`.
- **`withdraw`, `withdrawAll`, `executeWithdrawal`, `recoverToken` (a, c)** move the whole
  treasury, and holding fees back would break `withdrawAll`. These take your other fix:
  after any transfer out, if the balance left is below `platformFeeAccrued[token]`, the
  ledger drops to the balance. The difference is emitted as
  `PlatformFeesSwept(token, recipient, amount)`, since those fees left with that exit. The
  ledger never claims fees the contract no longer holds, and a later fee sweep can't eat
  into merchant float.

This all happens in `_sendOut`, the one path every exit goes through. Side benefit: a
stale native fee ledger can no longer block `setNativeAliasToken`. Our live Arc proxy has
no accrued fees above its balance today (checked on a fork; see "Upgrade readiness").

Tests: `test_5_2_5b_merchantBackingCannotTakeAccruedFees`,
`test_5_2_5c_withdrawAll_booksTheFeesItTookAsSwept`,
`test_5_2_5a_partialWithdraw_booksOnlyTheFeesItTook`,
`test_5_2_5a_withdrawAboveFees_leavesLedgerAlone`,
`test_5_2_5a_executeWithdrawalAndRecoverToken_keepLedgerBacked`, and
`test_5_2_5_nativeWithdrawAll_unblocksNativeAlias`.

### 5.2.6 Privileged loosenings bypass the timelock (a–c): acknowledged, by design

As we said during validation, only cap raises, delay cuts and upgrades are queued. You're
right that the README oversold it ("loosening a control is never a single call"). It now
says exactly what's queued, what isn't, and why.

- **(a) Ownership handover.** When a key leaks, an immediate transfer to a fresh key is
  the main way to recover. A timelock would slow the legitimate rotation exactly as much
  as the attacker's, and whoever moves first wins either way. The real answer is a
  multisig owner, which we already recommend once volumes grow.
- **(b) Signer rotation.** Same idea: rotating is how we revoke a leaked signer key, so it
  has to be instant. Attacker-signed dust quotes don't settle PaymentIntents, because
  settlement compares the on-chain amount, merchant, token, fiat amount and rate with the
  intent. What's left is griefing: the attacker can burn a pending intent's refId, and we
  re-issue the intent.
- **(c) Allowlist additions.** A junk token never gets credited. Bookings have to match the
  booking's expected token, and deposits have to use an active stablecoin from the API's
  token table, matched by address.

### 5.2.7 `depositPoints` skips `maxTransactionAmount`: documented

You offered two options, enforcing the limit in `depositPoints` or documenting that it
only covers bookings, and we took the second. That's intentional: `maxTransactionAmount`
is a per-booking limit, and point deposits aren't bookings. The NatSpec on
`maxTransactionAmount` and the README now spell that out.

### 5.2.8 Unbound booking payment amount: disputed

This one assumes the API credits a booking by refId without checking amount and token. It
doesn't: `verifyTransactionInContract` rejects any on-chain record whose amount, token,
wallet, `bookingId`, `productVariantId` or `exchangeRateId` differs from the server-side
booking. Bookings are priced off-chain by design; the contract records the payment and
the API verifies it.

### 5.2.9 Upgrade queue not bound to code: fixed

Agreed. The timelock exists so people can review the new implementation, and that
requires there to be code to review. `queueUpgrade` now reverts with `NoImplementationCode`
for an address without code, and the queue stores the implementation's codehash instead
of its address. `_authorizeUpgrade` compares the codehash of the address being upgraded
to. A UUPS implementation embeds its own address as an immutable, so the codehash pins the
address too. Tests: `test_5_2_9_revert_queueUpgrade_addressWithoutCode`,
`test_5_2_9_queueStoresCodehash`, and
`test_5_2_9_revert_upgrade_whenCodeChangedAfterQueue`, where `vm.etch` swaps the code
after queuing.

### Also fixed: the `__gap` NatSpec

The contract header said `__gap` reserves 50 slots when the array actually had 45. It now
states the rule (append before `__gap`, shrink it by the same number of slots) instead of a
number that can drift.

## Mutation testing

193 of 248 mutants were killed (77.8%). We went through the 55 survivors, re-ran the
suspicious ones against `af071e0`, and then re-ran all 55 against 2.3.0 with the new tests
(`test/TakumiPayCoverage.t.sol`). Line numbers shifted between versions, so each 2.2.0
line was mapped to its 2.3.0 position by diff before applying the mutation.

| Category | Mutants (2.2.0 line) | Count | What we found | Against 2.3.0 |
|---|---|---|---|---|
| Tool artifact: mutant breaks every `setUp` | 367 (`onlyOwner` inverted), 400 (`initializer` removed), 402, 403 (zero checks inverted) | 4 | Killed in practice. Each one makes `initialize` or the owner's setup calls revert, so 5 of 7 suites fail in `setUp` (checked on `af071e0`). It looks like the tool only counts individual test failures. We added explicit tests anyway. | 4 of 4 killed |
| Equivalent | 702, 880 (`memory` → `storage`) | 2 | Same behaviour, different gas. In `_consumePending` the value is read before the `delete`. | 2 of 2 survive, as expected |
| Instant-exit timelock guard | 772, 782, 939 (`withdrawalDelay > 0` → `< 0`) | 3 | **Real gap, and the most important one.** Nothing tested that `withdraw`, `withdrawAll` and `recoverToken` revert with `TimelockActive` once a delay is set. | 3 of 3 killed |
| `onlyOwner` removed | 469, 769, 780, 816, 821, 842, 848, 853, 859, 887, 912, 925, 963, 972 | 14 | Real gap. One test now calls every owner-only function (all 27, not just these 14) as a stranger and expects `NotOwner`. | 14 of 14 killed |
| `nonReentrant` removed | 498, 512, 633, 711, 724, 769, 780, 912, 936, 1087, 1193 | 11 | Real gap. An ERC-20 that calls back mid-transfer, and a native recipient that does the same, now re-enter each function. For owner-only functions they re-enter as the owner, so the call actually reaches `nonReentrant` instead of stopping at `onlyOwner`. | 11 of 11 killed |
| Event not asserted | 472, 612, 796, 823, 845, 856, 862, 876, 922, 958, 969, 988 | 12 | Real gap. Our monitoring relies on these, so each is now checked with `vm.expectEmit`. | 12 of 12 killed |
| Batch spending limit | 534, 535 | 2 | Real gap. Items under, at and over the limit are now tested. | 2 of 2 killed |
| Pagination | 1011, 1021, 1022, 1025, 1058, 1061 | 6 | Real gap: non-zero offsets and the `getTransactionsByAddress` limit weren't tested. | 6 of 6 killed |
| Allowlist swap-and-pop | 1247 (`idx != lastIdx` → `==`) | 1 | Real gap: removing a token from the middle of the list wasn't tested. | 1 of 1 killed |

Against 2.3.0, 53 of the 55 former survivors are killed. The two left are the equivalent
mutants, which no test can kill since they don't change behaviour. So every one of the
248 mutants that can change behaviour is now caught.

We also mutated every line the fixes added, 19 mutants of our own:
- an off-by-one at the exact 24h expiry;
- each new check removed;
- the 2.1.0 carry-over window shortened;
- the exit log written without its timestamp;
- the fee-ledger clamp inverted, removed, or using `<=`;
- the delay re-arm dropped;
- the upgrade queue storing the address instead of the codehash.

All 19 are killed. Across the 74 mutants run against the final 2.3.0 code, the only
survivors are the two equivalent ones. A mutation pass of your own against 2.3.0 is
welcome.

## Upgrade readiness

Our Arc proxies (mainnet and testnet) both return `version() == "2.1.0"` on-chain (checked
29 October 2026). 2.1.0's `_authorizeUpgrade` predates the queue, so 2.1.0 → 2.3.0 is a
single owner call with no migration call (`upgradeToAndCall(impl, "")`).

- **Storage layout.** We diffed `forge inspect TakumiPay storageLayout` for 2.1.0 and
  2.3.0, with compiler ids normalized. Slots 0–29 and every struct's member layout are
  identical. The only change is two new slots taken from 2.1.0's `__gap`:
  `withdrawalDelayRaisedAt` at slot 30 and the `_sweepLog` mapping at slot 31. `__gap`
  shrinks from 45 to 43 and still ends at slot 74.
- **New state starts out right.** `withdrawalDelayRaisedAt` reads 0 after the upgrade, so
  anything queued under 2.1.0 keeps its unlock time until the delay is next set. The sweep
  log starts empty. 2.1.0's last fixed-window total (`sweptInWindow`) keeps counting in
  full until two days after that window opened, which is the latest any of its exits could
  still sit inside a trailing 24 hours. 2.3.0 can't see the windows before that one, so
  sweeping in the 24 hours before the upgrade is best avoided. The Arc proxy hasn't swept
  recently anyway.
- **Upgrade test without a fork** (`test/TakumiPayUpgrade.t.sol`). It starts from the exact
  2.1.0 source (`test/legacy/TakumiPay210.sol`) and builds a proxy with bookings, a batch,
  a deposit, a merchant payment with a fee, a sweep part-way through its window, a delay, a
  queued withdrawal and a queued cap raise. After the upgrade it checks:
  - every readable value is unchanged, and all 75 contract slots are byte-identical;
  - queued entries keep their schedule;
  - the 2.1.0 sweep total carries over, so the 24 hours after it see exactly one cap;
  - a quote signed before the upgrade settles after it (the EIP-712 domain is unchanged);
  - the next upgrade is queued and timelocked;
  - an aliased proxy (like ours on Arc) keeps native closed and rescues only dust.
- **Rehearsal on a fork of the live Arc mainnet proxy** (`test/TakumiPayUpgrade.fork.t.sol`).
  The upgrade is made as the live owner. Every readable value and all 75 contract slots stay
  the same, and the next upgrade is queued, code-bound and waits the live 1-day delay.
  `platformFeeAccrued` doesn't exceed the balance, so the new reserve in
  `sweepMerchantBacking` doesn't block anything.
- **The actual upgrade script** (`UpgradeTakumiPay`, unchanged), simulated as the proxy's
  on-chain owner against Arc mainnet, reports `New version: 2.3.0`.

## ABI changes in 2.3.0

Clients move straight from 2.1.0, so they also pick up the 2.2.0 changes listed in
`docs/security-review-2.1.0.md`. New in 2.3.0:

- New views: `withdrawalDelayRaisedAt()` and `sweepAllowance(address)`.
- New errors: `NoImplementationCode`, `AliasDecimalsUnsupported`, `SweepLogFull`.
- Same signatures, different meaning:
  - `sweptInWindow(token)` and `sweepWindowStart(token)` are no longer written. After the
    upgrade they keep 2.1.0's last window. Use `sweepAllowance` for what can leave now.
  - Whole-treasury exits can now emit `PlatformFeesSwept` (see 5.2.5).
  - `getPendingChange(keccak256("upgrade")).value` is the queued codehash, not the
    address. `UpgradeQueued` still carries the address.
  - `queueUpgrade(address(0))` reverts with `NoImplementationCode` instead of
    `ZeroAddress`.

None of our off-chain clients read the changed getters. The API and the mobile app only
carry them in their ABI copies.
