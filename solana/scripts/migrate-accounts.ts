// Grows the accounts a pre-2.3.0-parity program created to the current layout:
// the Config PDA (+ withdrawal_delay_raised_at) and every SweepCap (+ exit_log).
// Run once, right after upgrading the program; until then every instruction
// that loads those accounts fails. Idempotent: accounts already at the current
// size are skipped. The owner pays the extra rent, never the vault.
//
//   DEPLOYER=~/.takumipay-secrets/solana-devnet-deployer.json \
//   npx ts-node scripts/migrate-accounts.ts
//
// RPC_URL defaults to devnet; IDL defaults to deployments/takumi_pay.idl.json,
// which must already be the upgraded program's IDL. Keys are never printed.
import { Program, AnchorProvider, Wallet } from "@coral-xyz/anchor";
import { Connection, Keypair, PublicKey, SystemProgram } from "@solana/web3.js";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";

const RPC_URL = process.env.RPC_URL || "https://api.devnet.solana.com";
const IDL_PATH = process.env.IDL || path.join(__dirname, "..", "deployments", "takumi_pay.idl.json");

function loadKeypair(p: string): Keypair {
  const file = p.replace(/^~/, os.homedir());
  return Keypair.fromSecretKey(new Uint8Array(JSON.parse(fs.readFileSync(file, "utf-8"))));
}

async function main() {
  const owner = loadKeypair(process.env.DEPLOYER!);
  const idl = JSON.parse(fs.readFileSync(IDL_PATH, "utf-8"));
  const connection = new Connection(RPC_URL, "confirmed");
  const provider = new AnchorProvider(connection, new Wallet(owner), { commitment: "confirmed" });
  const program = new Program(idl, provider);
  const accounts = program.account as any;
  const [configPda] = PublicKey.findProgramAddressSync([Buffer.from("config")], program.programId);

  console.log("Program:", program.programId.toBase58());
  console.log("Config PDA:", configPda.toBase58());

  const config = await connection.getAccountInfo(configPda);
  if (!config) throw new Error("config PDA not found: is the program initialised?");
  if (config.data.length < accounts.config.size) {
    const sig = await program.methods
      .migrateConfig()
      .accounts({ owner: owner.publicKey, config: configPda, systemProgram: SystemProgram.programId } as any)
      .rpc();
    console.log(`migrate_config (${config.data.length} -> ${accounts.config.size} bytes):`, sig);
  } else {
    console.log("config already at the current layout");
  }

  // Every SweepCap this program owns, found by discriminator, so no mint is missed.
  const sweepCaps = await connection.getProgramAccounts(program.programId, {
    // The TS client camel-cases IDL names, so the coder knows it as `sweepCap`.
    filters: [{ memcmp: program.coder.accounts.memcmp("sweepCap") }],
  });
  for (const { pubkey, account } of sweepCaps) {
    // Layout prefix shared by every version: discriminator, config, token_mint.
    const tokenMint = new PublicKey(account.data.subarray(40, 72));
    if (account.data.length >= accounts.sweepCap.size) {
      console.log(`sweep cap ${tokenMint.toBase58()}: already at the current layout`);
      continue;
    }
    const sig = await program.methods
      .migrateSweepCap(tokenMint)
      .accounts({
        owner: owner.publicKey,
        config: configPda,
        sweepCap: pubkey,
        systemProgram: SystemProgram.programId,
      } as any)
      .rpc();
    console.log(`migrate_sweep_cap ${tokenMint.toBase58()}:`, sig);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
