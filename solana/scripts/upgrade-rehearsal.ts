// Rehearses upgrading a live takumi_pay to the 2.3.0-parity build on a local
// validator: state created by the deployed program must survive the upgrade and
// the account migration, and the new rules must apply from then on.
//
//   solana program dump Baj91uzqwt8hRaJmke3dV8RdBwjq5MaWEtKNuUFTBBwS old.so -u devnet
//   solana-test-validator --reset --mint <WALLET pubkey> \
//     --upgradeable-program Baj91uzqwt8hRaJmke3dV8RdBwjq5MaWEtKNuUFTBBwS old.so <WALLET pubkey>
//   WALLET=... OLD_IDL=<deployed IDL> NEW_IDL=target/idl/takumi_pay.json \
//     npx ts-node scripts/upgrade-rehearsal.ts before
//   solana program deploy -u localhost -k <WALLET> --program-id Baj91… target/deploy/takumi_pay.so
//   WALLET=... NEW_IDL=... npx ts-node scripts/upgrade-rehearsal.ts unmigrated
//   RPC_URL=http://127.0.0.1:8899 DEPLOYER=<WALLET> IDL=<NEW_IDL> npx ts-node scripts/migrate-accounts.ts
//   WALLET=... NEW_IDL=... npx ts-node scripts/upgrade-rehearsal.ts after
//
// Throws on the first mismatch. Localnet only; it creates its own mint.
import * as anchor from "@coral-xyz/anchor";
import { Program, AnchorProvider, Wallet, BN } from "@coral-xyz/anchor";
import { Connection, Keypair, PublicKey, SystemProgram } from "@solana/web3.js";
import {
  createMint,
  getOrCreateAssociatedTokenAccount,
  mintTo,
  TOKEN_PROGRAM_ID,
} from "@solana/spl-token";
import * as assert from "assert";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";

const RPC_URL = process.env.RPC_URL || "http://127.0.0.1:8899";
const STATE = process.env.STATE || path.join(os.tmpdir(), "takumi-pay-upgrade-rehearsal.json");
const UNLIMITED = new BN("18446744073709551615");
const CAP = new BN(1_000_000);

function loadKeypair(p: string): Keypair {
  const file = p.replace(/^~/, os.homedir());
  return Keypair.fromSecretKey(new Uint8Array(JSON.parse(fs.readFileSync(file, "utf-8"))));
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function errorCode(p: Promise<unknown>): Promise<string | undefined> {
  try {
    await p;
    return undefined;
  } catch (err: any) {
    return err.error?.errorCode?.code ?? err.message;
  }
}

async function main() {
  const phase = process.argv[2];
  const wallet = loadKeypair(process.env.WALLET!);
  const connection = new Connection(RPC_URL, "confirmed");
  const provider = new AnchorProvider(connection, new Wallet(wallet), { commitment: "confirmed" });
  const idlPath = phase === "before" ? process.env.OLD_IDL! : process.env.NEW_IDL!;
  const program = new Program(JSON.parse(fs.readFileSync(idlPath, "utf-8")), provider);
  const accounts = program.account as any;
  const pid = program.programId;
  const pda = (...seeds: Buffer[]) => PublicKey.findProgramAddressSync(seeds, pid)[0];
  const configPda = pda(Buffer.from("config"));
  const sweepCapPda = (mint: PublicKey) => pda(Buffer.from("sweep_cap"), configPda.toBuffer(), mint.toBuffer());
  const feePda = (mint: PublicKey) => pda(Buffer.from("platform_fee"), configPda.toBuffer(), mint.toBuffer());
  const withdrawalPda = (nonce: number) =>
    pda(Buffer.from("withdrawal"), configPda.toBuffer(), new BN(nonce).toArrayLike(Buffer, "le", 8));
  const owner = wallet.publicKey;

  if (phase === "before") {
    // State the deployed program would hold: a configured mint, a sweep that
    // filled part of the old fixed window, a queued cap raise, a delay, and a
    // queued withdrawal.
    await program.methods
      .initialize(Keypair.generate().publicKey)
      .accounts({ owner, config: configPda, systemProgram: SystemProgram.programId } as any)
      .rpc();
    const mint = await createMint(connection, wallet, owner, null, 6);
    const vault = (await getOrCreateAssociatedTokenAccount(connection, wallet, mint, configPda, true)).address;
    await mintTo(connection, wallet, mint, vault, wallet, 5_000_000);
    const to = (await getOrCreateAssociatedTokenAccount(connection, wallet, mint, owner)).address;

    const capAccounts = { owner, config: configPda, sweepCap: sweepCapPda(mint), systemProgram: SystemProgram.programId };
    await program.methods.queueSweepCap(mint, CAP).accounts(capAccounts as any).rpc();
    await program.methods.applySweepCap(mint).accounts({ owner, config: configPda, sweepCap: sweepCapPda(mint) } as any).rpc();
    await program.methods
      .sweepMerchantBackingToken(new BN(300_000))
      .accounts({
        owner,
        config: configPda,
        sweepCap: sweepCapPda(mint),
        tokenMint: mint,
        vaultTokenAccount: vault,
        recipientTokenAccount: to,
        tokenProgram: TOKEN_PROGRAM_ID,
      } as any)
      .rpc();
    await program.methods.queueSweepCap(mint, UNLIMITED).accounts(capAccounts as any).rpc();
    await program.methods.setWithdrawalDelay(new BN(3)).accounts({ owner, config: configPda } as any).rpc();
    await program.methods
      .queueWithdrawal(mint, to, new BN(100_000), false)
      .accounts({ owner, config: configPda, withdrawalRequest: withdrawalPda(1), systemProgram: SystemProgram.programId } as any)
      .rpc();

    const config = await accounts.config.fetch(configPda);
    const sweepCap = await accounts.sweepCap.fetch(sweepCapPda(mint));
    fs.writeFileSync(
      STATE,
      JSON.stringify({
        mint: mint.toBase58(),
        vault: vault.toBase58(),
        to: to.toBase58(),
        config: {
          owner: config.owner.toBase58(),
          backendSigner: config.backendSigner.toBase58(),
          withdrawalDelay: config.withdrawalDelay.toString(),
          withdrawalNonce: config.withdrawalNonce.toString(),
          txCounter: config.txCounter.toString(),
          bump: config.bump,
        },
        sweepCap: {
          cap: sweepCap.cap.toString(),
          sweptInWindow: sweepCap.sweptInWindow.toString(),
          windowStart: sweepCap.windowStart.toString(),
          pendingCap: sweepCap.pendingCap.toString(),
          pendingUnlockTime: sweepCap.pendingUnlockTime.toString(),
        },
        configLength: (await connection.getAccountInfo(configPda))!.data.length,
        sweepCapLength: (await connection.getAccountInfo(sweepCapPda(mint)))!.data.length,
      })
    );
    console.log("before: state written to", STATE);
    return;
  }

  const saved = JSON.parse(fs.readFileSync(STATE, "utf-8"));
  const mint = new PublicKey(saved.mint);
  const vault = new PublicKey(saved.vault);
  const to = new PublicKey(saved.to);
  const exitAccounts = {
    owner,
    config: configPda,
    sweepCap: sweepCapPda(mint),
    platformFeeAccount: feePda(mint),
    tokenMint: mint,
    vaultTokenAccount: vault,
    recipientTokenAccount: to,
    tokenProgram: TOKEN_PROGRAM_ID,
  };

  if (phase === "unmigrated") {
    // A SweepCap at the old length cannot load at all: it has no slack.
    const sweep = await errorCode(
      program.methods.sweepMerchantBackingToken(new BN(1)).accounts(exitAccounts as any).rpc()
    );
    assert.strictEqual(sweep, "AccountDidNotDeserialize", `old sweep cap: got ${sweep}`);

    // The old Config still loads while no ownership transfer is pending:
    // `pending_owner` reserves 33 bytes but None serialises to 1, and the new
    // field reads from that slack as 0. Writing Some(..) needs the full length,
    // so transfer_ownership fails until the account is grown. That is why the
    // migration has to run straight after the upgrade.
    await program.methods.setPaused(false).accounts({ authority: owner, config: configPda, adminRecord: null } as any).rpc();
    const transfer = await errorCode(
      program.methods.transferOwnership(Keypair.generate().publicKey).accounts({ owner, config: configPda } as any).rpc()
    );
    assert.strictEqual(transfer, "AccountDidNotSerialize", `old config: got ${transfer}`);
    console.log("unmigrated: old sweep cap refused, old config cannot take a pending owner");
    return;
  }

  if (phase === "after") {
    const configInfo = (await connection.getAccountInfo(configPda))!;
    const sweepCapInfo = (await connection.getAccountInfo(sweepCapPda(mint)))!;
    assert.strictEqual(configInfo.data.length, accounts.config.size, "config grown to the new size");
    assert.strictEqual(sweepCapInfo.data.length, accounts.sweepCap.size, "sweep cap grown to the new size");
    assert.ok(configInfo.data.length > saved.configLength && sweepCapInfo.data.length > saved.sweepCapLength);

    // Every value written by the old program survived; the new fields read 0.
    const config = await accounts.config.fetch(configPda);
    assert.deepStrictEqual(
      {
        owner: config.owner.toBase58(),
        backendSigner: config.backendSigner.toBase58(),
        withdrawalDelay: config.withdrawalDelay.toString(),
        withdrawalNonce: config.withdrawalNonce.toString(),
        txCounter: config.txCounter.toString(),
        bump: config.bump,
      },
      saved.config
    );
    assert.strictEqual(config.withdrawalDelayRaisedAt.toNumber(), 0);
    const sweepCap = await accounts.sweepCap.fetch(sweepCapPda(mint));
    assert.deepStrictEqual(
      {
        cap: sweepCap.cap.toString(),
        sweptInWindow: sweepCap.sweptInWindow.toString(),
        windowStart: sweepCap.windowStart.toString(),
        pendingCap: sweepCap.pendingCap.toString(),
        pendingUnlockTime: sweepCap.pendingUnlockTime.toString(),
      },
      saved.sweepCap
    );
    assert.ok(sweepCap.exitLog.every((e: BN) => e.isZero()), "exit log starts empty");

    // Migrating again is refused, and a stranger cannot migrate at all.
    assert.strictEqual(
      await errorCode(
        program.methods
          .migrateConfig()
          .accounts({ owner, config: configPda, systemProgram: SystemProgram.programId } as any)
          .rpc()
      ),
      "AlreadyMigrated"
    );
    const stranger = Keypair.generate();
    await connection.confirmTransaction(await connection.requestAirdrop(stranger.publicKey, 1_000_000_000));
    assert.strictEqual(
      await errorCode(
        program.methods
          .migrateConfig()
          .accounts({ owner: stranger.publicKey, config: configPda, systemProgram: SystemProgram.programId } as any)
          .signers([stranger])
          .rpc()
      ),
      "NotOwner"
    );

    // The withdrawal queued under the old program keeps its unlock time (nothing
    // re-armed it) and now draws on the cap: 1_000_000 - 300_000 (old window,
    // still counted) leaves 700_000.
    await sleep(4_000);
    await program.methods
      .executeWithdrawalToken()
      .accounts({ ...exitAccounts, withdrawalRequest: withdrawalPda(1) } as any)
      .rpc();
    assert.strictEqual(
      await errorCode(program.methods.sweepMerchantBackingToken(new BN(600_001)).accounts(exitAccounts as any).rpc()),
      "SweepCapExceeded"
    );
    await program.methods.sweepMerchantBackingToken(new BN(600_000)).accounts(exitAccounts as any).rpc();
    const after = await accounts.sweepCap.fetch(sweepCapPda(mint));
    assert.strictEqual(after.exitLog.filter((e: BN) => !e.isZero()).length, 2, "both exits logged");

    // The raise queued before the upgrade still applies on its own schedule.
    await program.methods
      .applySweepCap(mint)
      .accounts({ owner, config: configPda, sweepCap: sweepCapPda(mint) } as any)
      .rpc();
    assert.ok((await accounts.sweepCap.fetch(sweepCapPda(mint))).cap.eq(UNLIMITED));
    console.log("after: state preserved, migrations guarded, new rules in force");
    return;
  }

  throw new Error(`unknown phase ${phase}: before | unmigrated | after`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
