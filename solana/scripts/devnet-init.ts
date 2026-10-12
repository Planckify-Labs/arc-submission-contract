// Initialises a freshly deployed takumi_pay program on devnet and enables
// Circle's devnet USDC for every payment entrypoint. Idempotent.
//
//   DEPLOYER=~/.takumipay-secrets/solana-devnet-deployer.json \
//   QUOTE_SIGNER=~/.takumipay-secrets/solana-devnet-quote-signer.json \
//   npx ts-node scripts/devnet-init.ts
//
// Keys are read from the files named above and never printed.
import * as anchor from "@coral-xyz/anchor";
import { Program, AnchorProvider, Wallet, BN } from "@coral-xyz/anchor";
import { Connection, Keypair, PublicKey, SystemProgram } from "@solana/web3.js";
import { getAssociatedTokenAddressSync } from "@solana/spl-token";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";

const RPC_URL = process.env.RPC_URL || "https://api.devnet.solana.com";
// Circle's official devnet USDC (6 decimals).
const USDC_MINT = new PublicKey("4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU");
// 100,000 USDC rolling 24h sweep allowance. Unset caps fail closed.
const USDC_SWEEP_CAP = new BN(100_000_000_000);

function loadKeypair(p: string): Keypair {
  const file = p.replace(/^~/, os.homedir());
  return Keypair.fromSecretKey(new Uint8Array(JSON.parse(fs.readFileSync(file, "utf-8"))));
}

async function main() {
  const owner = loadKeypair(process.env.DEPLOYER!);
  const signer = loadKeypair(process.env.QUOTE_SIGNER!);
  const idl = JSON.parse(
    fs.readFileSync(path.join(__dirname, "..", "deployments", "takumi_pay.idl.json"), "utf-8")
  );
  const connection = new Connection(RPC_URL, "confirmed");
  const provider = new AnchorProvider(connection, new Wallet(owner), { commitment: "confirmed" });
  const program = new Program(idl, provider);
  const [configPda] = PublicKey.findProgramAddressSync([Buffer.from("config")], program.programId);

  console.log("Program:", program.programId.toBase58());
  console.log("Owner:", owner.publicKey.toBase58());
  console.log("Config PDA:", configPda.toBase58());

  if (!(await connection.getAccountInfo(configPda))) {
    const sig = await program.methods
      .initialize(signer.publicKey)
      .accounts({ owner: owner.publicKey, config: configPda, systemProgram: SystemProgram.programId } as any)
      .rpc();
    console.log("initialize:", sig);
  } else {
    console.log("already initialised");
  }
  const config: any = await (program.account as any).config.fetch(configPda);
  if (config.backendSigner.toBase58() !== signer.publicKey.toBase58()) {
    throw new Error(`on-chain backend signer ${config.backendSigner.toBase58()} != local quote signer`);
  }

  const [allowedPda] = PublicKey.findProgramAddressSync(
    [Buffer.from("allowed_payment_token"), configPda.toBuffer(), USDC_MINT.toBuffer()],
    program.programId
  );
  if (!(await connection.getAccountInfo(allowedPda))) {
    const sig = await program.methods
      .addAllowedPaymentToken(USDC_MINT)
      .accounts({
        owner: owner.publicKey,
        config: configPda,
        allowedToken: allowedPda,
        systemProgram: SystemProgram.programId,
      } as any)
      .rpc();
    console.log("add_allowed_payment_token(USDC):", sig);
  } else {
    console.log("USDC already allowlisted");
  }

  const [sweepCapPda] = PublicKey.findProgramAddressSync(
    [Buffer.from("sweep_cap"), configPda.toBuffer(), USDC_MINT.toBuffer()],
    program.programId
  );
  const capInfo = await connection.getAccountInfo(sweepCapPda);
  const current: any = capInfo ? await (program.account as any).sweepCap.fetch(sweepCapPda) : null;
  if (!current || current.cap.lt(USDC_SWEEP_CAP)) {
    // Raising a cap is queued behind withdrawal_delay (0 on devnet), then applied.
    const accounts = { owner: owner.publicKey, config: configPda, sweepCap: sweepCapPda } as any;
    console.log(
      "queue_sweep_cap:",
      await program.methods
        .queueSweepCap(USDC_MINT, USDC_SWEEP_CAP)
        .accounts({ ...accounts, systemProgram: SystemProgram.programId })
        .rpc()
    );
    console.log(
      "apply_sweep_cap:",
      await program.methods.applySweepCap(USDC_MINT).accounts(accounts).rpc()
    );
  } else {
    console.log("sweep cap already set:", current.cap.toString());
  }

  const ownerAta = getAssociatedTokenAddressSync(USDC_MINT, owner.publicKey);
  const ata = await connection.getTokenAccountBalance(ownerAta).catch(() => null);
  console.log("Deployer USDC:", ata ? ata.value.uiAmountString : "no token account");
  console.log("Deployer SOL:", (await connection.getBalance(owner.publicKey)) / 1e9);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
