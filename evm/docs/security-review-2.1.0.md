# Security review of TakumiPay 2.1.0: disposition

Source: Arc Studio contract security analysis of `src/TakumiPay.sol` 2.1.0 (13 findings),
run against the public mirror of this repo. Fixes ship in **2.2.0**. Storage layout is
unchanged from 2.1.0 (no new state variables, `__gap` untouched), so live proxies upgrade
in place. Regression tests: `test/TakumiPayHardening.t.sol`.

| ID | Finding | Disposition |
|---|---|---|
| C-1 | Native alias not set at init | **Fixed.** `initialize` takes `initialNativeAliasToken` and sets it atomically. On Arc (5042, 5042002) a zero alias reverts `NativeAliasRequired`; the deploy script passes `0x3600…0000` there automatically. |
| H-1 | Upgrade has no timelock | **Fixed.** `queueUpgrade(impl)` puts the upgrade in the existing pending-change queue. `_authorizeUpgrade` accepts only the queued implementation after `withdrawalDelay`, and each queued entry works once. With one EOA owner this buys detection time, not a veto; a multisig owner is still recommended. |
| H-2 | Late alias strands native state | **Fixed.** `setNativeAliasToken` reverts on outstanding native fees (`NativeFeesOutstanding`) or a non-zero native sweep cap (`NativeSweepCapSet`). Requiring the cap to be 0 also means no queued native withdrawal could ever execute. Native *balance* was never stranded: it is the same money as the ERC-20 view. |
| M-1 | refId unique per flow, not globally | **Fixed.** refId is an idempotency key: the API claims it in one unique `ReferenceId` table for purchases and point deposits, then credits only the first use. In 2.1.0 the same refId could succeed on-chain as both a booking and a deposit, so the second payment was taken but never credited. `createTransaction`, `createTransactionBatch` and `depositPoints` now reject a refId used by **any** of the three flows (`_isRefIdUsed`; it reads the existing maps, so refIds used before the upgrade count too). `processMerchantPayment` still checks only its own map, on purpose: its refId is the backend's PaymentIntent ULID, and checking the unsigned maps would let anyone front-run a pending payment with a cheap booking and make the signed quote unpayable. The opposite direction would need someone to use a ULID before the backend mints it. |
| M-2 | Native sweep cap unit mismatch on Arc | **Resolved by C-1**, since the native path can no longer be live on Arc. `sweepCap` NatSpec now states caps use the token's own decimals. |
| M-3 | Sub-unit native dust locked | **Fixed.** `rescueNativeDust(to)` sends `balance % 10^(18 − aliasDecimals)`. By construction this never moves a whole ERC-20 unit, so it skips the cap and timelock. The amount at stake is always under $0.000001. |
| L-1 | `getTransactionsInRange` O(txCounter) | **Fixed without changing the ABI.** Ids are append-ordered and `block.timestamp` never decreases, so matches are one contiguous run found by binary search: O(log n + limit). A fuzz test checks it against a linear scan. |
| L-2 | String `require` in `createTransaction` | **Fixed, and extended to the whole contract.** No `require` with a revert string is left; every check is `if (…) revert CustomError();`. This was also needed to ship 2.2.0 at all: with the strings, the fixes pushed the runtime to 25,128 bytes, over the EIP-170 limit of 24,576 that Arc enforces. Without them it is 23,547 bytes. `test_implementationFitsUnderEip170` guards this, because forge does not apply the limit inside tests. |
| L-3 | `withdrawalId` uses `encodePacked` | **Fixed** (`abi.encode`). Not exploitable before: every field is fixed-width and `cancelWithdrawal` is owner-only. |
| L-4 | `setSweepCap(token, 0)` freezes sweeps | **Documented, not changed.** 0 is the intended emergency brake, and H-2's fix relies on it. Reverting on 0 would remove the brake. NatSpec and README now say 0 = freeze and point to `SWEEP_CAP_UNLIMITED`. |
| I-1 | `block.timestamp` reliance | Documented in the contract header. |
| I-2 | External calls in batch loop | Inline comment on why it is safe (validate-all first, `nonReentrant`). |
| I-3 | `DOMAIN_SEPARATOR` naming | No change; EIP-712 convention. |

## Re-audit of 2.2.0 (Arc Studio, 2026-10-23)

Arc Studio confirmed all seven fixes and accepted the reasoning for L-4. It also accepted the original per-flow reasoning for M-1, which was later reversed after checking the API's idempotency model (see M-1 above). Its new
items and how each was handled:

| Item | Handling |
|---|---|
| "High": Arc testnet chain id may not be 5042002 | False positive: `cast chain-id` against `rpc.testnet.arc.io` returns 5042002, and mainnet returns 5042. |
| Medium: no minimum upgrade delay | Accepted as a known limit. The upgrade delay *is* `withdrawalDelay`, and lowering that is itself queued under the current delay, so it can't be skipped. It is 0 only before configuration (runbook step 4), and on Arc mainnet it is 1 day. |
| Low: `upgradeToAndCall` data is not part of the queue | Accepted. `data` can only call into the queued, already-public implementation; pass `""` unless a reviewed migration exists. |
| Low: queued native withdrawals survive `setNativeAliasToken` | Accepted as an operational step. They can never execute (the native exit is closed), so they are inert; cancel them. Enforcing it on-chain needs a counter that can't account for requests queued under 2.1.0. |
| Low: monotonic-timestamp assumption is implicit | Fixed: comment on `_recordTransactionUnchecked`. |
| Low: `rescueNativeDust` forwards all gas / calls `decimals()` | No change. A revert undoes the whole call and the owner retries with another `to`; a 2300 stipend is an anti-pattern. The alias token is canonical USDC. |

## ABI changes in 2.2.0

- `initialize(address,address)` becomes `initialize(address,address,address)`. Only fresh deployments call it.
- New: `queueUpgrade(address)`, `rescueNativeDust(address)`; events `UpgradeQueued`,
  `NativeDustRescued`; errors `NativeAliasRequired`, `NativeFeesOutstanding`,
  `NativeSweepCapSet`, `NativeNotAliased`, `UpgradeNotQueued`.
- `createTransaction`, `createTransactionBatch` and `depositPoints` now reject a refId used by any flow.
- Every revert string is now a custom error. Existing errors are reused where the meaning is the same
  (`ZeroAmount`, `RefConsumed` for any already-used refId, `TimelockNotExpired`, `TokenNotAllowed`,
  `InvalidStringLength`). New ones: `EmptyBatch`, `BatchTooLarge`, `DuplicateRefInBatch`,
  `ExceedsSpendingLimit`, `DelayTooLong`, `WithdrawalDelayNotSet`, `WithdrawalNotFound`,
  `WithdrawalAlreadyExecuted`, `WithdrawalAlreadyCancelled`, `AlreadyAdmin`, `NotAdmin`,
  `IndexInconsistency`, `LimitTooLarge`, `InvalidRange`, `TransactionNotFound`,
  `PointDepositNotFound`, `TokenAlreadyAllowed`, `FeeOnTransferNotSupported`.
  No client matches on the old strings: checked against the API, the mobile app (HEAD and Play Store
  v5.25.0), agent-api, the dashboard and contract-admin. Clients whose ABI copy lacks the new errors
  see an undecoded selector instead of text.

## Upgrading the live proxies

2.1.0's `_authorizeUpgrade` predates the timelock, so the move to 2.2.0 is a single
owner call. `UpgradeTakumiPay` detects this. Every later upgrade waits out the proxy's
`withdrawalDelay` (1 day on Arc mainnet), and that includes rolling back to 2.1.0. Rehearse first with
`RUN_FORK_TESTS=true forge test --match-contract ArcUpgradeFork -vv`. Once the implementation is
deployed, add `NEW_IMPLEMENTATION=<address>` to rehearse against the exact bytecode the owner will switch to.
