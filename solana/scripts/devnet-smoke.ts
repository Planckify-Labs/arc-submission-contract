// End-to-end smoke test of every USDC payment entrypoint on devnet, paid by the
// deployer wallet. Spends ~1.5 USDC (the merchant amount and the sweep are
// returned to the deployer's own ATA).
//
//   DEPLOYER=... QUOTE_SIGNER=... npx ts-node scripts/devnet-smoke.ts
import { Program, AnchorProvider, Wallet, BN } from "@coral-xyz/anchor";
import {
  Connection,
  Ed25519Program,
  Keypair,
  PublicKey,
  SystemProgram,
  SYSVAR_INSTRUCTIONS_PUBKEY,
} from "@solana/web3.js";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  TOKEN_PROGRAM_ID,
  getAssociatedTokenAddressSync,
} from "@solana/spl-token";
import { createHash } from "crypto";
import nacl from "tweetnacl";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";

const RPC_URL = process.env.RPC_URL || "https://api.devnet.solana.com";
const USDC = new PublicKey("4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU");

const load = (p: string) =>
  Keypair.fromSecretKey(
    new Uint8Array(JSON.parse(fs.readFileSync(p.replace(/^~/, os.homedir()), "utf-8")))
  );
const sha = (s: string) => Array.from(createHash("sha256").update(s).digest());
const u64 = (n: BN) => n.toArrayLike(Buffer, "le", 8);
const i64 = (n: number) => {
  const b = Buffer.alloc(8);
  b.writeBigInt64LE(BigInt(n));
  return b;
};
const str = (s: string) => {
  const b = Buffer.from(s);
  const l = Buffer.alloc(4);
  l.writeUInt32LE(b.length);
  return Buffer.concat([l, b]);
};

async function main() {
  const payer = load(process.env.DEPLOYER!);
  const signer = load(process.env.QUOTE_SIGNER!);
  const idl = JSON.parse(
    fs.readFileSync(path.join(__dirname, "..", "deployments", "takumi_pay.idl.json"), "utf-8")
  );
  const connection = new Connection(RPC_URL, "confirmed");
  const program: any = new Program(
    idl,
    new AnchorProvider(connection, new Wallet(payer), { commitment: "confirmed" })
  );
  const pid = program.programId;
  const pda = (...seeds: Buffer[]) => PublicKey.findProgramAddressSync(seeds, pid)[0];
  const config = pda(Buffer.from("config"));
  const allowed = pda(Buffer.from("allowed_payment_token"), config.toBuffer(), USDC.toBuffer());
  const sweepCap = pda(Buffer.from("sweep_cap"), config.toBuffer(), USDC.toBuffer());
  const platformFee = pda(Buffer.from("platform_fee"), config.toBuffer(), USDC.toBuffer());
  const payerAta = getAssociatedTokenAddressSync(USDC, payer.publicKey);
  const vault = getAssociatedTokenAddressSync(USDC, config, true);
  const bal = async () =>
    (await connection.getTokenAccountBalance(payerAta)).value.uiAmountString;
  const link = (s: string) => `https://explorer.solana.com/tx/${s}?cluster=devnet`;
  const stamp = Date.now();
  const common = {
    payer: payer.publicKey,
    config,
    tokenMint: USDC,
    allowedToken: allowed,
    payerTokenAccount: payerAta,
    vaultTokenAccount: vault,
    tokenProgram: TOKEN_PROGRAM_ID,
    associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
    systemProgram: SystemProgram.programId,
  };

  console.log("USDC before:", await bal());

  // 1. process_merchant_payment_token (ed25519-signed quote)
  {
    const refId = `smoke-merchant-${stamp}`;
    const refIdHash = sha(refId);
    const q = {
      amount: new BN(1_000_000),
      platformFeeAmount: new BN(50_000),
      fiatAmountMinor: new BN(100),
      exchangeRateId: new BN(1),
      expiresAt: Math.floor(Date.now() / 1000) + 300,
    };
    const merchantId = "smoke-merchant";
    const message = Buffer.concat([
      str(refId),
      str(merchantId),
      USDC.toBuffer(),
      u64(q.amount),
      u64(q.platformFeeAmount),
      u64(q.fiatAmountMinor),
      Buffer.from("USD"),
      u64(q.exchangeRateId),
      i64(q.expiresAt),
    ]);
    const edIx = Ed25519Program.createInstructionWithPublicKey({
      publicKey: signer.publicKey.toBytes(),
      message,
      signature: nacl.sign.detached(message, signer.secretKey),
    });
    const merchantPayment = pda(Buffer.from("merchant_payment"), config.toBuffer(), Buffer.from(refIdHash));
    const sig = await program.methods
      .processMerchantPaymentToken({
        refId,
        refIdHash,
        merchantId,
        amount: q.amount,
        platformFeeAmount: q.platformFeeAmount,
        fiatAmountMinor: q.fiatAmountMinor,
        fiatCurrency: [85, 83, 68],
        exchangeRateId: q.exchangeRateId,
        expiresAt: new BN(q.expiresAt),
      })
      .accounts({
        ...common,
        merchantPayment,
        platformFeeAccount: platformFee,
        instructionsSysvar: SYSVAR_INSTRUCTIONS_PUBKEY,
      } as any)
      .preInstructions([edIx])
      .rpc();
    const mp: any = await (program.account as any).merchantPayment.fetch(merchantPayment);
    console.log("merchant payment OK:", link(sig));
    console.log("  on-chain amount", mp.amount.toString(), "fee", mp.platformFeeAmount.toString(), "ref", mp.refId);
  }

  // 2. create_transaction_token
  {
    const refId = `smoke-tx-${stamp}`;
    const refIdHash = sha(refId);
    const cfg: any = await (program.account as any).config.fetch(config);
    const txRecord = pda(Buffer.from("tx"), config.toBuffer(), u64(cfg.txCounter.add(new BN(1))));
    const refRecord = pda(Buffer.from("ref"), config.toBuffer(), Buffer.from(refIdHash));
    const sig = await program.methods
      .createTransactionToken({
        bookingId: "smoke-booking",
        exchangeRateId: new BN(1),
        productVariantId: "smoke-variant",
        refId,
        refIdHash,
        amount: new BN(250_000),
      })
      .accounts({ ...common, txRecord, refRecord, spendingLimit: null } as any)
      .rpc();
    console.log("create_transaction_token OK:", link(sig));
  }

  // 3. deposit_points
  {
    const refId = `smoke-points-${stamp}`;
    const refIdHash = sha(refId);
    const cfg: any = await (program.account as any).config.fetch(config);
    const pointDeposit = pda(Buffer.from("point_deposit"), config.toBuffer(), u64(cfg.pointDepositCounter.add(new BN(1))));
    const pointRefRecord = pda(Buffer.from("point_ref"), config.toBuffer(), Buffer.from(refIdHash));
    const sig = await program.methods
      .depositPoints(refId, refIdHash, new BN(250_000))
      .accounts({ ...common, pointDeposit, pointRefRecord } as any)
      .rpc();
    console.log("deposit_points OK:", link(sig));
  }

  // 4. sweep_platform_fees_token (owner → own ATA)
  {
    const sig = await program.methods
      .sweepPlatformFeesToken(new BN(50_000))
      .accounts({
        owner: payer.publicKey,
        config,
        sweepCap,
        tokenMint: USDC,
        platformFeeAccount: platformFee,
        vaultTokenAccount: vault,
        recipientTokenAccount: payerAta,
        tokenProgram: TOKEN_PROGRAM_ID,
      } as any)
      .rpc();
    console.log("sweep_platform_fees_token OK:", link(sig));
  }

  // 5. a mint that is not allowlisted must be rejected
  {
    const bogus = Keypair.generate().publicKey;
    const bogusAllowed = pda(Buffer.from("allowed_payment_token"), config.toBuffer(), bogus.toBuffer());
    try {
      await program.methods
        .depositPoints(`smoke-bogus-${stamp}`, sha(`smoke-bogus-${stamp}`), new BN(1))
        .accounts({ ...common, tokenMint: bogus, allowedToken: bogusAllowed, pointDeposit: payer.publicKey, pointRefRecord: payer.publicKey } as any)
        .simulate();
      console.log("FAIL: non-allowlisted mint was accepted");
      process.exitCode = 1;
    } catch {
      console.log("non-allowlisted mint rejected OK");
    }
  }

  console.log("USDC after:", await bal());
}

main().catch((e) => {
  console.error(e?.logs ?? e);
  process.exit(1);
});
