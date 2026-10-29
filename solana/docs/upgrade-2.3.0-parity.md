# takumi_pay (Solana): the EVM 2.3.0 treasury fixes, and how to upgrade devnet

The Olympix scan of the EVM contract (`../../evm/docs/olympix-bugpocer-response-2.2.0.md`)
found weaknesses this program shares. They are fixed the same way here:

- **Every exit draws on the sweep cap.** Before, `withdraw_*` and `execute_withdrawal_*`
  skipped it, so a queued withdrawal could take a whole balance once its delay passed.
- **The cap holds over every 24 hours** (5.2.2). A per-token log of recent exits replaces
  the fixed window that let 2× the cap out across a boundary. The log holds 16 exits per
  token, and a 17th within 24 hours fails with `SweepLogFull`.
- **`set_withdrawal_delay` restarts the clock** on everything already queued (5.2.1): cap
  raises, delay cuts and withdrawals.
- **`set_sweep_cap` cancels a queued raise** (5.2.4), so the brake is one call.
- **The fee ledger stays backed** (5.2.5). Merchant-backing sweeps cannot take the balance
  behind accrued fees. A withdrawal that takes it books those fees as swept to its
  recipient (`PlatformFeesSwept`).

Not ported, because nothing here matches: the native-alias rescue (5.1.2, Arc only) and the
upgrade queue (5.2.9). This program has no in-program upgrade queue: upgrades go through
the loader's upgrade authority, a single key with no timelock. Moving that authority to a
multisig is the equivalent control and is still open.

Tests: `cargo test -p takumi-pay --lib` (the timing rules, including a randomized check that
no 24 hours ever see more than the cap) and `tests/takumi_pay.ts` against a local validator
(53 passing, including an "EVM 2.3.0 parity" block).

## What changes for clients

- `withdraw_sol`, `withdraw_token`, `execute_withdrawal_sol` and `execute_withdrawal_token`
  take two more accounts: `sweep_cap` and `platform_fee_account` (the mint's
  `[b"platform_fee", config, mint]` PDA, which may not exist yet). `sweep_merchant_backing_*`
  take `platform_fee_account`. Payments and deposits are unchanged.
- New instructions `migrate_config` and `migrate_sweep_cap`, and new errors `SweepLogFull`
  and `AlreadyMigrated`.
- `Config` gains `withdrawal_delay_raised_at` and `SweepCap` gains `exit_log`, both
  appended. Readers using the old IDL still decode both accounts. `SweepCap`'s
  `swept_in_window` / `window_start` are no longer written.
- `deployments/takumi_pay.idl.next.json` is this build's IDL. It becomes
  `takumi_pay.idl.json` once the program is upgraded.

## Upgrading devnet

The accounts the deployed program created are shorter than the new layout. Until they are
grown, a `SweepCap` cannot load at all, so sweeps, withdrawals and cap changes fail.
`Config` still loads while no ownership transfer is pending, but `transfer_ownership`
cannot write a pending owner. Payments and deposits keep working throughout. Run the
migration straight after the upgrade.

Every step below was rehearsed on a local validator, starting from a dump of the deployed
program (`scripts/upgrade-rehearsal.ts`; its header has the commands). State survived, and
the queued withdrawal and cap raise kept their schedules.

1. The upgrade authority (`32kGdxMAuUysd3gTiULPiSc4oFB2yaLT32Z8CtJZ3ULa`) needs enough SOL
   to extend the program data account by about 43 KB (roughly 0.3 SOL of rent), plus fees.
2. Build with `cargo-build-sbf --manifest-path programs/takumi_pay/Cargo.toml`, then:

   ```sh
   solana program deploy -u devnet \
     -k ~/.takumipay-secrets/solana-devnet-deployer.json \
     --program-id Baj91uzqwt8hRaJmke3dV8RdBwjq5MaWEtKNuUFTBBwS \
     --upgrade-authority ~/.takumipay-secrets/solana-devnet-deployer.json \
     target/deploy/takumi_pay.so
   ```

   Solana CLI 4.3 extends the program data account itself. With an older CLI, run
   `solana program extend` first.
3. Grow the accounts. The script is idempotent and finds every `SweepCap` on its own:

   ```sh
   DEPLOYER=~/.takumipay-secrets/solana-devnet-deployer.json \
   IDL=deployments/takumi_pay.idl.next.json \
   npx ts-node scripts/migrate-accounts.ts
   ```

4. Make the new IDL current. Move `deployments/takumi_pay.idl.next.json` over
   `deployments/takumi_pay.idl.json`, and replace the copies in the API
   (`src/blockchain-verification/solana/takumi-pay/idl.ts`, kept identical) and the mobile
   app (`services/chains/solana/takumiPay/idl.ts`). Record the deploy in
   `deployments/devnet-state.json`.
5. Run `scripts/devnet-smoke.ts`.

To roll back, redeploy the previous binary. It reads the grown accounts (it ignores the
extra bytes), but it brings back the uncapped withdrawals and the fixed window.
