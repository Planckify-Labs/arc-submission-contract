# TakumiPay — Stellar (Soroban)

Soroban port of the merchant-payment contract that also exists on
[EVM](../evm/src/TakumiPay.sol) and [Solana](../solana/programs/takumi_pay).
Feature parity with the Solana program: owner/admin roles, pausing, backend-signed
merchant payment quotes with replay protection, platform fee treasury, per-token
spending limits, generic transactions, point deposits, and timelocked withdrawals.

## Why this isn't a line-for-line port

- **No native/token split.** On Solana and EVM, SOL/ETH and SPL/ERC-20 tokens need
  separate code paths (`_sol` vs `_token` instructions). On Stellar, XLM is itself a
  token contract (the Stellar Asset Contract, SEP-41), so every entrypoint here takes
  a single `token: Address` — no native-asset special case.
- **Backend-signed quotes use `ed25519_verify` directly**, not an auxiliary
  instruction check (Solana) or `ecrecover` (EVM). The quote is wrapped in a
  `QuoteMessage { network_id, contract, quote }` (see `src/merchant.rs`) before
  hashing — the Soroban analogue of an EIP-712 domain separator, binding a signature
  to this specific network and contract deployment.
- **`ref_id` replay keys are hashed on-chain** (`sha256` of the value's XDR
  encoding) instead of requiring the caller to pass a pre-computed hash like the
  Solana program does — removes a whole class of "hash doesn't match the string"
  bugs.

## Layout

```
contracts/takumi_pay/src/
  lib.rs        contract entrypoints (thin wrappers over the modules below)
  admin.rs      init, owner/admin roles, two-step ownership transfer, shared auth helpers
  config.rs     pause flags, spending limits, backend signer rotation, allowed payment tokens
  transaction.rs  generic create_transaction (with spending-limit + replay checks)
  merchant.rs   process_merchant_payment — the backend-signed quote flow
  point.rs      deposit_points
  treasury.rs   sweep_platform_fees / sweep_merchant_backing
  withdraw.rs   immediate + timelocked (queue/execute/cancel) withdrawals
  events.rs     #[contractevent] definitions
  types.rs      storage keys, records, constants
  test.rs       unit tests (soroban-sdk testutils)
```

## Treasury controls

The same rules as the EVM contract since 2.3.0 (see
`../evm/docs/olympix-bugpocer-response-2.2.0.md`; the Olympix scan was of the EVM
contract, and every finding that applies here is fixed the same way):

- **One sweep cap per token bounds every exit**: both sweeps, `withdraw` and
  `execute_withdrawal`. No 24-hour span can see more than the cap leave: each exit is
  logged with its time and frees its share exactly 24 hours later
  (`get_sweep_allowance` shows what can leave now). The log holds 16 exits per token,
  and a 17th within 24 hours fails with `SweepLogFull`. An unset cap fails closed, and
  `set_sweep_cap(token, 0)` is the emergency brake: it also cancels any queued raise.
- **Raising a cap and lowering the delay are queued** behind `withdrawal_delay`.
  Raising the delay, or calling `set_withdrawal_delay` again with the current value,
  restarts the clock on everything already queued: cap raises, delay cuts and
  withdrawals.
- **The fee ledger stays backed.** `sweep_merchant_backing` cannot take the balance
  behind accrued platform fees. When a withdrawal takes it, those fees are booked as
  swept to its recipient (`PlatformFeesSwept`).
- **No in-place upgrade.** The contract has no `update_current_contract_wasm` entry
  point, so each version is a fresh instance (`deployments/<network>/vN.json`). Clients
  then move to the new contract id.

## Build

```sh
rustup target add wasm32v1-none
cargo build -p takumi-pay --target wasm32v1-none --release
# or, with the stellar CLI installed:
./scripts/build.sh
```

## Test

```sh
cargo test -p takumi-pay
```

### Known upstream issue: pin `ed25519-dalek` to 2.2.0

`soroban-env-host` declares `ed25519-dalek = ">=2.0.0"` (an unbounded lower
bound) for its own test-PRNG glue. Since `ed25519-dalek` 3.0.0 changed its
`rand_core` trait bounds, that glue code (`with_test_prng` /
`SigningKey::generate`) fails to compile against 3.0.0 — this breaks
`cargo test` on **any** crate that enables `soroban-sdk`'s `testutils`
feature with soroban-sdk 27.0.0 / 26.1.x, not just this one. `Cargo.lock`
in this workspace pins the resolution back to 2.2.0:

```sh
cargo update -p ed25519-dalek@3.0.0 --precise 2.2.0
```

If `cargo test` starts failing with a `ChaCha20Rng: ed25519_dalek::rand_core::CryptoRng`
trait-bound error after a routine `cargo update`, re-run the command above.
Check upstream (`soroban-env-host`) for a fix before removing this workaround.

## Deploy

Requires the [`stellar` CLI](https://developers.stellar.org/docs/build/smart-contracts/getting-started/setup).

```sh
stellar keys generate my-key --network testnet
stellar keys fund my-key --network testnet

./scripts/deploy.sh testnet my-key
./scripts/initialize.sh testnet my-key <contract-id> <owner-address> <backend-signer-pubkey-hex>
```

Deployment records are written to `deployments/<network>/vN.json`, matching the
convention used in `../sui/deployments`.
