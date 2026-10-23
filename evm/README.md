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
test/TakumiPayArcUpgrade.fork.t.sol  2.1.0 → 2.2.0 upgrade rehearsal on an Arc mainnet fork
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
A per-token rolling 24h cap bounds the damage instead:

```sh
# Sweeps fail closed. A fresh deploy can sweep nothing until this is set.
cast send $PROXY "queueSweepCap(address,uint256)" $USDC 50000000000 ...
cast send $PROXY "applySweepCap(address)" $USDC ...
```

**Loosening a control is never a single call.** Raising a sweep cap, or lowering
`withdrawalDelay`, must be queued and is itself subject to the delay currently in
force. Tightening (lowering a cap, raising the delay) is immediate. Without this,
the timelock would be decorative — an owner key that leaked could call
`setWithdrawalDelay(0)` and `withdraw()` in the same transaction.

| Action | Path |
|---|---|
| Raise `withdrawalDelay` | `setWithdrawalDelay` — immediate |
| Lower `withdrawalDelay` | `queueWithdrawalDelay` → wait → `applyWithdrawalDelay` |
| Lower `sweepCap` | `setSweepCap` — immediate |
| Raise `sweepCap` | `queueSweepCap` → wait → `applySweepCap` |
| Upgrade the implementation (2.2.0+) | `queueUpgrade` → wait → `upgradeToAndCall` |

`setSweepCap(token, 0)` is the emergency brake, not "no limit": 0 freezes every exit
for that token until a queued raise lands. For no limit, queue `SWEEP_CAP_UNLIMITED`.

> **Known limit.** With a single-EOA owner these controls bound the blast radius
> of a leaked key and make every loosening, upgrades included, visible on-chain for
> `withdrawalDelay` before it lands. They do not eliminate it: the same key that
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

From 2.2.0, upgrades are timelocked by `withdrawalDelay`. `UpgradeTakumiPay` deploys the
new implementation and queues it; it also applies it in the same run when nothing has
to wait (the proxy is on 2.1.0, which predates the timelock, or `withdrawalDelay` is 0).

```sh
PROXY_ADDRESS=0x... forge script script/DeployTakumiPay.s.sol:UpgradeTakumiPay \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify

# after the delay
PROXY_ADDRESS=0x... NEW_IMPLEMENTATION=0x... \
  forge script script/DeployTakumiPay.s.sol:ApplyUpgradeTakumiPay \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
```

Rehearse an Arc mainnet upgrade on a fork first (nothing is broadcast):

```sh
RUN_FORK_TESTS=true forge test --match-contract ArcUpgradeFork -vv
```

Storage layout must never be reordered — append only, and decrement `__gap` when adding
state. Verify with `forge inspect TakumiPay storageLayout` before every upgrade.
