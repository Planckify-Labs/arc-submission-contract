# TakumiPay — EVM (Foundry)

Solidity implementation of the merchant-payment contract that also exists on
[Stellar](../stellar) and [Solana](../solana/programs/takumi_pay). Owner/admin roles,
pausing, backend-signed merchant payment quotes with replay protection, a platform-fee
treasury, per-token spending limits, generic booking transactions, point deposits, and
timelocked withdrawals.

Deployed behind a UUPS (ERC-1967) proxy.

## Why this isn't a line-for-line port

- **Native and ERC-20 need separate code paths.** On Stellar, XLM is itself a token
  contract (SEP-41), so every entrypoint takes a single address. Here `address(0)`
  means native (ETH, MATIC, …) and each value-in entrypoint branches on it. Native is
  still gated by the same allowlist as any ERC-20 — there is no implicit bypass, so
  `addAllowedPaymentToken(address(0))` is a required post-deploy step if you accept it.
- **Quotes are verified with EIP-712 + `ecrecover`**, not `ed25519_verify` (Stellar) or
  an auxiliary instruction check (Solana). The EIP-712 domain separator binds a
  signature to this chain and this deployment, the same role Stellar's
  `QuoteMessage { network_id, contract, quote }` wrapper plays.
- **`refId` replay keys are `keccak256` of the string**, computed on-chain.
- **Fee-on-transfer tokens are rejected**, not accommodated: every ERC-20 pull asserts
  the received balance delta equals the requested amount (`_pullToken`). Stellar has no
  equivalent because SEP-41 transfers cannot skim.

## Layout

```
src/TakumiPay.sol          the contract — single flat implementation
src/MockAUSD.sol           TESTNET-ONLY open-mint 6-decimal AUSD stand-in (Monad testnet QRIS demo)
script/DeployTakumiPay.s.sol
                           DeployTakumiPay (fresh proxy) + UpgradeTakumiPay (new impl)
script/DeployMockAUSD.s.sol
                           deploys MockAUSD + initial mint; refuses any chain but 10143
test/TakumiPayProduction.t.sol    pause, spending limits, batching, allowlist, withdrawals, upgrades
test/TakumiPayMerchant.t.sol      processMerchantPayment, quote validation, treasury sweeps, signer rotation
test/TakumiPayPointDeposit.t.sol  depositPoints and the payment-token allowlist
test/TakumiPayNativeAlias.t.sol   native-alias chains (Arc) and sweep-cap coverage of every exit
test/TakumiPayHardening.t.sol     fixes from the 2.1.0 security review (docs/security-review-2.1.0.md)
test/TakumiPayAuditFixes.t.sol    fixes from the Olympix scan of 2.2.0 (docs/olympix-bugpocer-response-2.2.0.md)
test/TakumiPayCoverage.t.sol      tests that kill the mutants surviving the Olympix mutation run
test/TakumiPayUpgrade.t.sol       2.1.0 → 2.3.0 upgrade of a populated proxy, no fork needed
test/TakumiPayUpgrade.fork.t.sol  2.1.0 → 2.3.0 upgrade rehearsal on forks of the live mainnet proxies
test/legacy/TakumiPay210.sol      verbatim 2.1.0 source (the version live proxies run), for the upgrade test
deployments/<chainId>.json        deployment record, written by the deploy script
```

## Payment token allowlist

A single `allowedPaymentTokens` list gates **every** entrypoint that moves value in:

| Entrypoint | Gated |
|---|---|
| `createTransaction` | ✅ |
| `createTransactionBatch` | ✅ (phase 1, before any transfer) |
| `processMerchantPayment` | ✅ |
| `depositPoints` | ✅ |

This mirrors Stellar's `AllowedPaymentToken`. A freshly deployed contract accepts
**nothing** until the owner allowlists tokens:

```sh
cast send $PROXY "addAllowedPaymentToken(address)" $USDC --rpc-url $RPC_URL --private-key $PK
cast send $PROXY "addAllowedPaymentToken(address)" 0x0000000000000000000000000000000000000000 ...  # native
```

## Treasury sweep rate limit

`sweepMerchantBacking` / `sweepPlatformFees` deliberately skip the withdrawal
timelock — merchant float has to settle daily and a 7-day queue would break that.
A per-token sweep cap bounds the damage instead. Every exit (sweeps, withdrawals,
token recovery) draws on one allowance per token:

```sh
# Sweeps fail closed. A fresh deploy can sweep nothing until this is set.
cast send $PROXY "queueSweepCap(address,uint256)" $USDC 50000000000 ...
cast send $PROXY "applySweepCap(address)" $USDC ...
cast call $PROXY "sweepAllowance(address)(uint256)" $USDC   # what can leave right now
```

Since 2.3.0 the cap holds over **every** 24 hours: no 24h span can see more than
`sweepCap` leave. Each capped exit is logged with its time, an exit passes only if it
plus everything in the trailing 24 hours fits the cap, and each exit's share comes back
exactly 24 hours later. So after a full-cap exit, nothing more leaves for a day. The log
holds 16 exits per token, and a 17th within 24 hours reverts with `SweepLogFull` until
the oldest expires. (2.1.0's fixed window let 2 × `sweepCap` leave within seconds across
a window boundary.) `setSweepCap(token, 0)` still stops everything at once.

`sweepMerchantBacking` never touches the balance that backs accrued platform fees;
those leave through `sweepPlatformFees`. `withdraw`, `withdrawAll`,
`executeWithdrawal` and `recoverToken` are whole-treasury exits and do not hold fees
back. When one takes fee-backed balance, those fees count as swept to its recipient:
`platformFeeAccrued` drops to what is left, and `PlatformFeesSwept` is emitted.

**Raising a cap, lowering the delay and upgrading are queued.** Each must wait out the
delay currently in force. Tightening (lowering a cap, raising the delay) is immediate.
Without this the timelock would be decorative: an owner key that leaked could call
`setWithdrawalDelay(0)` and `withdraw()` in the same transaction.

| Action | Path |
|---|---|
| Raise `withdrawalDelay` | `setWithdrawalDelay` — immediate |
| Lower `withdrawalDelay` | `queueWithdrawalDelay` → wait → `applyWithdrawalDelay` |
| Lower `sweepCap` | `setSweepCap` — immediate, and cancels a queued raise for that token |
| Raise `sweepCap` | `queueSweepCap` → wait → `applySweepCap` |
| Upgrade the implementation | `queueUpgrade` → wait → `upgradeToAndCall` |

Raising the delay (or calling `setWithdrawalDelay` again with the current value)
restarts the clock on everything already queued: upgrades, cap raises, delay cuts and
withdrawals all wait the full delay from that moment. `queueUpgrade` only accepts an
address that already has code, and binds the queue to that code's hash, so what runs
is exactly what was public while the entry waited.

Some owner actions take effect in one call on purpose, because they are also how an
operator responds to a leaked key: `transferOwnership` / `acceptOwnership` (move to a
fresh key), `rotateBackendSigner` (revoke a leaked signer), `addAllowedPaymentToken`,
`setMaxTransactionAmount`, `addAdmin` and pausing. The API does not credit what these
could fake on-chain. It matches every booking, deposit and merchant payment against
the token and amount it expected, and bookings and deposits against the payer too.

`setSweepCap(token, 0)` is the emergency brake, not "no limit": 0 freezes every exit
for that token until a queued raise lands. For no limit, queue `SWEEP_CAP_UNLIMITED`.

`maxTransactionAmount` limits each booking (`createTransaction` and each item of
`createTransactionBatch`). It does not apply to point deposits or merchant payments,
the same as the Solana program's spending limit.

> **Known limit.** With a single-EOA owner these controls bound the blast radius
> of a leaked key and make cap raises, delay cuts and upgrades visible on-chain for
> `withdrawalDelay` before they land. They do not eliminate it: the same key that
> queues can also cancel, so the delay buys detection time, not a veto. A veto needs
> a multisig owner.

## Build

```sh
forge build
```

## Test

```sh
forge test
forge test --match-path test/TakumiPayMerchant.t.sol -vvv
```

## Deploy

```sh
export RPC_URL=...
export BACKEND_SIGNER=0x...        # address that signs EIP-712 quotes
export INITIAL_OWNER=0x...         # optional; defaults to the deployer

forge script script/DeployTakumiPay.s.sol:DeployTakumiPay \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify
```

`initialize(owner, backendSigner, nativeAliasToken)` runs atomically with the proxy
deployment, so there is no window in which an uninitialized proxy is live. On Arc the
script passes the USDC ERC-20 (`0x3600…0000`) as `nativeAliasToken` automatically, and
the contract refuses to initialize on Arc without one. Set `NATIVE_ALIAS_TOKEN` to
override.

## Upgrade

Every live proxy runs 2.1.0, whose `_authorizeUpgrade` predates the timelock, so the
move to 2.3.0 is a single owner call. From 2.3.0 on, upgrades are timelocked by
`withdrawalDelay` and bound to the queued code. `UpgradeTakumiPay` deploys the new
implementation and queues it; it also applies it in the same run when nothing has
to wait (the proxy is on 2.1.0, or `withdrawalDelay` is 0).

The 2.1.0 → 2.3.0 upgrade needs no migration call (`upgradeToAndCall(impl, "")`). The
two new slots take the first two of 2.1.0's `__gap`: `withdrawalDelayRaisedAt` (30)
and the `_sweepLog` mapping (31). Their zero starting values are correct. 2.1.0's last
sweep-window total keeps counting against the cap until two days after that window
opened. Don't sweep in the 24 hours before upgrading: 2.3.0 cannot see earlier windows.
The EIP-712 domain is unchanged, so quotes the API signed before the upgrade still
settle after it.

```sh
PROXY_ADDRESS=0x... forge script script/DeployTakumiPay.s.sol:UpgradeTakumiPay \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify

# after the delay
PROXY_ADDRESS=0x... NEW_IMPLEMENTATION=0x... \
  forge script script/DeployTakumiPay.s.sol:ApplyUpgradeTakumiPay \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
```

Rehearse on forks of the live mainnet proxies first (Arc, Arbitrum One, Monad;
nothing is broadcast). Set `NEW_IMPLEMENTATION_<chainId>` to rehearse against the
implementation you actually deployed:

```sh
RUN_FORK_TESTS=true forge test --match-contract UpgradeFork -vv
NEW_IMPLEMENTATION_5042=0x... RUN_FORK_TESTS=true forge test --match-test test_arcMainnet -vv
```

Storage layout must never be reordered — append only, and decrement `__gap` when adding
state. `TakumiPayUpgrade.t.sol` checks every contract slot across the upgrade from the
vendored 2.1.0 source. Also diff `forge inspect TakumiPay storageLayout` against the
live version before every upgrade.
