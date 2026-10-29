import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { TakumiPay } from "../target/types/takumi_pay";
import {
  Keypair,
  PublicKey,
  SystemProgram,
  LAMPORTS_PER_SOL,
  Ed25519Program,
  ComputeBudgetProgram,
} from "@solana/web3.js";
import {
  createMint,
  getOrCreateAssociatedTokenAccount,
  getAssociatedTokenAddressSync,
  getAccount,
  mintTo,
  TOKEN_PROGRAM_ID,
  ASSOCIATED_TOKEN_PROGRAM_ID,
} from "@solana/spl-token";
import nacl from "tweetnacl";
import { expect } from "chai";

// ── Helpers ────────────────────────────────────────────────────────────────

async function sha256(data: string): Promise<number[]> {
  const hash = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(data)
  );
  return Array.from(new Uint8Array(hash));
}

function u64LeBytes(n: number | bigint): Buffer {
  return Buffer.from(
    new Uint8Array(new BigUint64Array([BigInt(n)]).buffer)
  );
}

function buildQuoteMessage(params: {
  refId: string;
  merchantId: string;
  tokenMint: PublicKey;
  amount: anchor.BN;
  platformFeeAmount: anchor.BN;
  fiatAmountMinor: anchor.BN;
  fiatCurrency: number[];
  exchangeRateId: anchor.BN;
  expiresAt: anchor.BN;
}): Buffer {
  const parts: Buffer[] = [];

  const refIdBytes = Buffer.from(params.refId);
  const refIdLen = Buffer.alloc(4);
  refIdLen.writeUInt32LE(refIdBytes.length);
  parts.push(refIdLen, refIdBytes);

  const merchantIdBytes = Buffer.from(params.merchantId);
  const merchantIdLen = Buffer.alloc(4);
  merchantIdLen.writeUInt32LE(merchantIdBytes.length);
  parts.push(merchantIdLen, merchantIdBytes);

  parts.push(params.tokenMint.toBuffer());
  parts.push(params.amount.toBuffer("le", 8));
  parts.push(params.platformFeeAmount.toBuffer("le", 8));
  parts.push(params.fiatAmountMinor.toBuffer("le", 8));
  parts.push(Buffer.from(params.fiatCurrency));
  parts.push(params.exchangeRateId.toBuffer("le", 8));
  parts.push(params.expiresAt.toBuffer("le", 8));

  return Buffer.concat(parts);
}

async function airdrop(
  connection: anchor.web3.Connection,
  to: PublicKey,
  amount: number
) {
  const sig = await connection.requestAirdrop(to, amount);
  await connection.confirmTransaction(sig);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ── Tests ──────────────────────────────────────────────────────────────────

describe("takumi_pay", () => {
  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);
  const connection = provider.connection;

  const program = anchor.workspace.takumiPay as Program<TakumiPay>;
  const owner = provider.wallet as anchor.Wallet;
  const backendSigner = Keypair.generate();

  const [configPda] = PublicKey.findProgramAddressSync(
    [Buffer.from("config")],
    program.programId
  );

  // Every value-in entrypoint is gated by this marker PDA. Native SOL is keyed
  // by PublicKey.default, the same sentinel the _sol instructions use.
  const allowedPaymentTokenPda = (mint: PublicKey): PublicKey =>
    PublicKey.findProgramAddressSync(
      [
        Buffer.from("allowed_payment_token"),
        configPda.toBuffer(),
        mint.toBuffer(),
      ],
      program.programId
    )[0];

  // Treasury sweeps fail closed until a cap is configured, and raising a cap is
  // a loosening so it goes queue -> apply. With withdrawalDelay at 0 both legs
  // land immediately.
  const sweepCapPda = (mint: PublicKey): PublicKey =>
    PublicKey.findProgramAddressSync(
      [Buffer.from("sweep_cap"), configPda.toBuffer(), mint.toBuffer()],
      program.programId
    )[0];

  // Exits take the mint's PlatformFeeAccount (which may not exist yet) so they
  // can keep the fee ledger backed.
  const platformFeePda = (mint: PublicKey): PublicKey =>
    PublicKey.findProgramAddressSync(
      [Buffer.from("platform_fee"), configPda.toBuffer(), mint.toBuffer()],
      program.programId
    )[0];

  const raiseSweepCap = async (
    mint: PublicKey,
    cap: anchor.BN
  ): Promise<PublicKey> => {
    const pda = sweepCapPda(mint);
    await program.methods
      .queueSweepCap(mint, cap)
      .accounts({
        owner: owner.publicKey,
        config: configPda,
        sweepCap: pda,
        systemProgram: SystemProgram.programId,
      })
      .rpc();
    await program.methods
      .applySweepCap(mint)
      .accounts({
        owner: owner.publicKey,
        config: configPda,
        sweepCap: pda,
      })
      .rpc();
    return pda;
  };

  const allowPaymentToken = async (mint: PublicKey): Promise<PublicKey> => {
    const pda = allowedPaymentTokenPda(mint);
    await program.methods
      .addAllowedPaymentToken(mint)
      .accounts({
        owner: owner.publicKey,
        config: configPda,
        allowedToken: pda,
        systemProgram: SystemProgram.programId,
      })
      .rpc();
    return pda;
  };

  // Shared state across tests
  let adminKeypair: Keypair;
  let adminPda: PublicKey;
  let tokenMint: PublicKey;
  let secondTokenMint: PublicKey;

  // ── Initialize ───────────────────────────────────────────────────────

  it("initializes the config", async () => {
    await program.methods
      .initialize(backendSigner.publicKey)
      .accounts({
        owner: owner.publicKey,
        config: configPda,
        systemProgram: SystemProgram.programId,
      })
      .rpc();

    const config = await program.account.config.fetch(configPda);
    expect(config.owner.toBase58()).to.equal(owner.publicKey.toBase58());
    expect(config.backendSigner.toBase58()).to.equal(
      backendSigner.publicKey.toBase58()
    );
    expect(config.paused).to.equal(false);
    expect(config.pointDepositsPaused).to.equal(false);
    expect(config.txCounter.toNumber()).to.equal(0);
    expect(config.pointDepositCounter.toNumber()).to.equal(0);
    expect(config.withdrawalDelay.toNumber()).to.equal(0);
  });

  it("allowlists native SOL for payments", async () => {
    const pda = await allowPaymentToken(PublicKey.default);
    const at = await program.account.allowedPaymentToken.fetch(pda);
    expect(at.tokenMint.toBase58()).to.equal(PublicKey.default.toBase58());
  });

  // ── Admin Management ─────────────────────────────────────────────────

  describe("Admin Management", () => {
    it("adds an admin", async () => {
      adminKeypair = Keypair.generate();
      [adminPda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("admin"),
          configPda.toBuffer(),
          adminKeypair.publicKey.toBuffer(),
        ],
        program.programId
      );

      await program.methods
        .addAdmin()
        .accounts({
          owner: owner.publicKey,
          config: configPda,
          adminPubkey: adminKeypair.publicKey,
          adminRecord: adminPda,
          systemProgram: SystemProgram.programId,
        })
        .rpc();

      const admin = await program.account.admin.fetch(adminPda);
      expect(admin.admin.toBase58()).to.equal(
        adminKeypair.publicKey.toBase58()
      );
    });

    it("rejects add_admin from non-owner", async () => {
      const nonOwner = Keypair.generate();
      await airdrop(connection, nonOwner.publicKey, LAMPORTS_PER_SOL);

      const fakeAdmin = Keypair.generate();
      const [fakeAdminPda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("admin"),
          configPda.toBuffer(),
          fakeAdmin.publicKey.toBuffer(),
        ],
        program.programId
      );

      try {
        await program.methods
          .addAdmin()
          .accounts({
            owner: nonOwner.publicKey,
            config: configPda,
            adminPubkey: fakeAdmin.publicKey,
            adminRecord: fakeAdminPda,
            systemProgram: SystemProgram.programId,
          })
          .signers([nonOwner])
          .rpc();
        expect.fail("Should have thrown");
      } catch (err: any) {
        expect(err.error?.errorCode?.code || "ConstraintHasOne").to.be.oneOf([
          "NotOwner",
          "ConstraintHasOne",
        ]);
      }
    });

    it("removes an admin", async () => {
      await program.methods
        .removeAdmin()
        .accounts({
          owner: owner.publicKey,
          config: configPda,
          adminPubkey: adminKeypair.publicKey,
          adminRecord: adminPda,
        })
        .rpc();

      // Account should be closed
      const info = await connection.getAccountInfo(adminPda);
      expect(info).to.be.null;
    });
  });

  // ── Pause / Unpause ─��──────────────────────────────────────���─────────

  describe("Pause / Unpause", () => {
    it("owner can pause and unpause", async () => {
      await program.methods
        .setPaused(true)
        .accounts({
          authority: owner.publicKey,
          config: configPda,
          adminRecord: null,
        })
        .rpc();
      let config = await program.account.config.fetch(configPda);
      expect(config.paused).to.equal(true);

      await program.methods
        .setPaused(false)
        .accounts({
          authority: owner.publicKey,
          config: configPda,
          adminRecord: null,
        })
        .rpc();
      config = await program.account.config.fetch(configPda);
      expect(config.paused).to.equal(false);
    });

    it("non-admin non-owner cannot pause", async () => {
      const nobody = Keypair.generate();
      await airdrop(connection, nobody.publicKey, LAMPORTS_PER_SOL);

      try {
        await program.methods
          .setPaused(true)
          .accounts({
            authority: nobody.publicKey,
            config: configPda,
            adminRecord: null,
          })
          .signers([nobody])
          .rpc();
        expect.fail("Should have thrown");
      } catch (err: any) {
        expect(err.error?.errorCode?.code).to.equal("NotAdminOrOwner");
      }
    });

    it("paused contract rejects transactions", async () => {
      // Pause
      await program.methods
        .setPaused(true)
        .accounts({
          authority: owner.publicKey,
          config: configPda,
          adminRecord: null,
        })
        .rpc();

      const refId = "paused-ref-001";
      const refIdHash = await sha256(refId);
      const config = await program.account.config.fetch(configPda);
      const nextTxId = config.txCounter.toNumber() + 1;

      const [txRecordPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("tx"), configPda.toBuffer(), u64LeBytes(nextTxId)],
        program.programId
      );
      const [refRecordPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("ref"), configPda.toBuffer(), Buffer.from(refIdHash)],
        program.programId
      );

      try {
        await program.methods
          .createTransactionSol({
            bookingId: "booking-paused",
            exchangeRateId: new anchor.BN(1),
            productVariantId: "variant-paused",
            refId,
            refIdHash,
            amount: new anchor.BN(10_000_000),
          })
          .accounts({
            payer: owner.publicKey,
            config: configPda,
          allowedToken: allowedPaymentTokenPda(PublicKey.default),
            txRecord: txRecordPda,
            refRecord: refRecordPda,
            spendingLimit: null,
            systemProgram: SystemProgram.programId,
          })
          .rpc();
        expect.fail("Should have thrown");
      } catch (err: any) {
        expect(err.error?.errorCode?.code || "ContractPaused").to.equal(
          "ContractPaused"
        );
      }

      // Unpause for subsequent tests
      await program.methods
        .setPaused(false)
        .accounts({
          authority: owner.publicKey,
          config: configPda,
          adminRecord: null,
        })
        .rpc();
    });
  });

  // ── Ownership Transfer ───────────────────────────────────────────────

  describe("Ownership Transfer", () => {
    let newOwner: Keypair;

    before(async () => {
      newOwner = Keypair.generate();
      await airdrop(connection, newOwner.publicKey, 2 * LAMPORTS_PER_SOL);
    });

    it("initiates ownership transfer", async () => {
      await program.methods
        .transferOwnership(newOwner.publicKey)
        .accounts({ owner: owner.publicKey, config: configPda })
        .rpc();

      const config = await program.account.config.fetch(configPda);
      expect(config.pendingOwner?.toBase58()).to.equal(
        newOwner.publicKey.toBase58()
      );
    });

    it("rejects accept from wrong signer", async () => {
      const imposter = Keypair.generate();
      await airdrop(connection, imposter.publicKey, LAMPORTS_PER_SOL);

      try {
        await program.methods
          .acceptOwnership()
          .accounts({ newOwner: imposter.publicKey, config: configPda })
          .signers([imposter])
          .rpc();
        expect.fail("Should have thrown");
      } catch (err: any) {
        expect(err.error?.errorCode?.code).to.equal("NotPendingOwner");
      }
    });

    it("cancels ownership transfer", async () => {
      await program.methods
        .cancelOwnershipTransfer()
        .accounts({ owner: owner.publicKey, config: configPda })
        .rpc();

      const config = await program.account.config.fetch(configPda);
      expect(config.pendingOwner).to.be.null;
    });

    it("completes full ownership transfer and transfers back", async () => {
      // Transfer to newOwner
      await program.methods
        .transferOwnership(newOwner.publicKey)
        .accounts({ owner: owner.publicKey, config: configPda })
        .rpc();

      await program.methods
        .acceptOwnership()
        .accounts({ newOwner: newOwner.publicKey, config: configPda })
        .signers([newOwner])
        .rpc();

      let config = await program.account.config.fetch(configPda);
      expect(config.owner.toBase58()).to.equal(newOwner.publicKey.toBase58());

      // Transfer back to original owner
      await program.methods
        .transferOwnership(owner.publicKey)
        .accounts({ owner: newOwner.publicKey, config: configPda })
        .signers([newOwner])
        .rpc();

      await program.methods
        .acceptOwnership()
        .accounts({ newOwner: owner.publicKey, config: configPda })
        .rpc();

      config = await program.account.config.fetch(configPda);
      expect(config.owner.toBase58()).to.equal(owner.publicKey.toBase58());
    });
  });

  // ── SOL Transactions ─────────────────────────────────────────────────

  describe("SOL Transactions", () => {
    it("creates a SOL transaction", async () => {
      const refId = "sol-tx-001";
      const refIdHash = await sha256(refId);
      const config = await program.account.config.fetch(configPda);
      const nextTxId = config.txCounter.toNumber() + 1;

      const [txRecordPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("tx"), configPda.toBuffer(), u64LeBytes(nextTxId)],
        program.programId
      );
      const [refRecordPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("ref"), configPda.toBuffer(), Buffer.from(refIdHash)],
        program.programId
      );

      const amount = new anchor.BN(100_000_000);

      await program.methods
        .createTransactionSol({
          bookingId: "booking-sol",
          exchangeRateId: new anchor.BN(42),
          productVariantId: "variant-sol",
          refId,
          refIdHash,
          amount,
        })
        .accounts({
          payer: owner.publicKey,
          config: configPda,
          allowedToken: allowedPaymentTokenPda(PublicKey.default),
          txRecord: txRecordPda,
          refRecord: refRecordPda,
          spendingLimit: null,
          systemProgram: SystemProgram.programId,
        })
        .rpc();

      const txRecord = await program.account.transactionRecord.fetch(
        txRecordPda
      );
      expect(txRecord.txId.toNumber()).to.equal(nextTxId);
      expect(txRecord.amount.toString()).to.equal(amount.toString());
      expect(txRecord.bookingId).to.equal("booking-sol");
      expect(txRecord.exchangeRateId.toNumber()).to.equal(42);
      expect(txRecord.tokenMint.toBase58()).to.equal(
        PublicKey.default.toBase58()
      );
    });

    it("rejects duplicate ref IDs", async () => {
      const refId = "sol-tx-001"; // same as above
      const refIdHash = await sha256(refId);
      const config = await program.account.config.fetch(configPda);
      const nextTxId = config.txCounter.toNumber() + 1;

      const [txRecordPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("tx"), configPda.toBuffer(), u64LeBytes(nextTxId)],
        program.programId
      );
      const [refRecordPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("ref"), configPda.toBuffer(), Buffer.from(refIdHash)],
        program.programId
      );

      try {
        await program.methods
          .createTransactionSol({
            bookingId: "booking-dup",
            exchangeRateId: new anchor.BN(1),
            productVariantId: "variant-dup",
            refId,
            refIdHash,
            amount: new anchor.BN(10_000_000),
          })
          .accounts({
            payer: owner.publicKey,
            config: configPda,
          allowedToken: allowedPaymentTokenPda(PublicKey.default),
            txRecord: txRecordPda,
            refRecord: refRecordPda,
            spendingLimit: null,
            systemProgram: SystemProgram.programId,
          })
          .rpc();
        expect.fail("Should have thrown");
      } catch (err) {
        expect(err).to.exist;
      }
    });

    it("rejects zero amount", async () => {
      const refId = "sol-tx-zero";
      const refIdHash = await sha256(refId);
      const config = await program.account.config.fetch(configPda);
      const nextTxId = config.txCounter.toNumber() + 1;

      const [txRecordPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("tx"), configPda.toBuffer(), u64LeBytes(nextTxId)],
        program.programId
      );
      const [refRecordPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("ref"), configPda.toBuffer(), Buffer.from(refIdHash)],
        program.programId
      );

      try {
        await program.methods
          .createTransactionSol({
            bookingId: "booking-zero",
            exchangeRateId: new anchor.BN(1),
            productVariantId: "variant-zero",
            refId,
            refIdHash,
            amount: new anchor.BN(0),
          })
          .accounts({
            payer: owner.publicKey,
            config: configPda,
          allowedToken: allowedPaymentTokenPda(PublicKey.default),
            txRecord: txRecordPda,
            refRecord: refRecordPda,
            spendingLimit: null,
            systemProgram: SystemProgram.programId,
          })
          .rpc();
        expect.fail("Should have thrown");
      } catch (err: any) {
        expect(err.error?.errorCode?.code).to.equal("ZeroAmount");
      }
    });
  });

  // ── SPL Token Transactions ───────────────────────────────────────────

  describe("SPL Token Transactions", () => {
    before(async () => {
      tokenMint = await createMint(
        connection,
        owner.payer,
        owner.publicKey,
        null,
        6
      );

      const payerAta = await getOrCreateAssociatedTokenAccount(
        connection,
        owner.payer,
        tokenMint,
        owner.publicKey
      );

      await mintTo(
        connection,
        owner.payer,
        tokenMint,
        payerAta.address,
        owner.publicKey,
        1_000_000_000 // 1000 tokens
      );

      await allowPaymentToken(tokenMint);
    });

    it("creates a token transaction", async () => {
      const refId = "token-tx-001";
      const refIdHash = await sha256(refId);
      const config = await program.account.config.fetch(configPda);
      const nextTxId = config.txCounter.toNumber() + 1;

      const [txRecordPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("tx"), configPda.toBuffer(), u64LeBytes(nextTxId)],
        program.programId
      );
      const [refRecordPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("ref"), configPda.toBuffer(), Buffer.from(refIdHash)],
        program.programId
      );

      const payerAta = getAssociatedTokenAddressSync(
        tokenMint,
        owner.publicKey
      );
      const vaultAta = getAssociatedTokenAddressSync(tokenMint, configPda, true);

      const amount = new anchor.BN(500_000); // 0.5 tokens

      await program.methods
        .createTransactionToken({
          bookingId: "booking-token",
          exchangeRateId: new anchor.BN(100),
          productVariantId: "variant-token",
          refId,
          refIdHash,
          amount,
        })
        .accounts({
          payer: owner.publicKey,
          config: configPda,
          allowedToken: allowedPaymentTokenPda(tokenMint),
          txRecord: txRecordPda,
          refRecord: refRecordPda,
          tokenMint,
          payerTokenAccount: payerAta,
          vaultTokenAccount: vaultAta,
          spendingLimit: null,
          tokenProgram: TOKEN_PROGRAM_ID,
          associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .rpc();

      const txRecord = await program.account.transactionRecord.fetch(
        txRecordPda
      );
      expect(txRecord.amount.toString()).to.equal(amount.toString());
      expect(txRecord.tokenMint.toBase58()).to.equal(tokenMint.toBase58());
    });
  });

  // ── Spending Limits ──────────────────────────────────────────────────

  describe("Spending Limits", () => {
    it("sets a spending limit for a token", async () => {
      const [spendingLimitPda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("spending_limit"),
          configPda.toBuffer(),
          tokenMint.toBuffer(),
        ],
        program.programId
      );

      await program.methods
        .setSpendingLimit(new anchor.BN(200_000))
        .accounts({
          owner: owner.publicKey,
          config: configPda,
          tokenMint,
          spendingLimit: spendingLimitPda,
          systemProgram: SystemProgram.programId,
        })
        .rpc();

      const sl = await program.account.spendingLimit.fetch(spendingLimitPda);
      expect(sl.maxAmount.toNumber()).to.equal(200_000);
    });

    it("rejects token transaction exceeding limit", async () => {
      const refId = "limit-exceed-001";
      const refIdHash = await sha256(refId);
      const config = await program.account.config.fetch(configPda);
      const nextTxId = config.txCounter.toNumber() + 1;

      const [txRecordPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("tx"), configPda.toBuffer(), u64LeBytes(nextTxId)],
        program.programId
      );
      const [refRecordPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("ref"), configPda.toBuffer(), Buffer.from(refIdHash)],
        program.programId
      );
      const [spendingLimitPda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("spending_limit"),
          configPda.toBuffer(),
          tokenMint.toBuffer(),
        ],
        program.programId
      );

      const payerAta = getAssociatedTokenAddressSync(
        tokenMint,
        owner.publicKey
      );
      const vaultAta = getAssociatedTokenAddressSync(tokenMint, configPda, true);

      try {
        await program.methods
          .createTransactionToken({
            bookingId: "booking-over",
            exchangeRateId: new anchor.BN(1),
            productVariantId: "variant-over",
            refId,
            refIdHash,
            amount: new anchor.BN(300_000), // exceeds 200_000 limit
          })
          .accounts({
            payer: owner.publicKey,
            config: configPda,
          allowedToken: allowedPaymentTokenPda(tokenMint),
            txRecord: txRecordPda,
            refRecord: refRecordPda,
            tokenMint,
            payerTokenAccount: payerAta,
            vaultTokenAccount: vaultAta,
            spendingLimit: spendingLimitPda,
            tokenProgram: TOKEN_PROGRAM_ID,
            associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
          })
          .rpc();
        expect.fail("Should have thrown");
      } catch (err: any) {
        expect(err.error?.errorCode?.code).to.equal("AmountExceedsLimit");
      }
    });

    it("allows token transaction within limit", async () => {
      const refId = "limit-ok-001";
      const refIdHash = await sha256(refId);
      const config = await program.account.config.fetch(configPda);
      const nextTxId = config.txCounter.toNumber() + 1;

      const [txRecordPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("tx"), configPda.toBuffer(), u64LeBytes(nextTxId)],
        program.programId
      );
      const [refRecordPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("ref"), configPda.toBuffer(), Buffer.from(refIdHash)],
        program.programId
      );
      const [spendingLimitPda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("spending_limit"),
          configPda.toBuffer(),
          tokenMint.toBuffer(),
        ],
        program.programId
      );

      const payerAta = getAssociatedTokenAddressSync(
        tokenMint,
        owner.publicKey
      );
      const vaultAta = getAssociatedTokenAddressSync(tokenMint, configPda, true);

      await program.methods
        .createTransactionToken({
          bookingId: "booking-ok",
          exchangeRateId: new anchor.BN(1),
          productVariantId: "variant-ok",
          refId,
          refIdHash,
          amount: new anchor.BN(100_000), // within 200_000 limit
        })
        .accounts({
          payer: owner.publicKey,
          config: configPda,
          allowedToken: allowedPaymentTokenPda(tokenMint),
          txRecord: txRecordPda,
          refRecord: refRecordPda,
          tokenMint,
          payerTokenAccount: payerAta,
          vaultTokenAccount: vaultAta,
          spendingLimit: spendingLimitPda,
          tokenProgram: TOKEN_PROGRAM_ID,
          associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .rpc();
    });
  });

  // ── Merchant Payments — SOL ──────────────────────────────────────────

  describe("Merchant Payments — SOL", () => {
    it("processes a merchant payment with valid Ed25519 signature", async () => {
      const refId = "merchant-sol-001";
      const refIdHash = await sha256(refId);
      const expiresAt = new anchor.BN(
        Math.floor(Date.now() / 1000) + 300
      );

      const quoteParams = {
        refId,
        merchantId: "shop-tokyo-01",
        tokenMint: PublicKey.default,
        amount: new anchor.BN(200_000_000), // 0.2 SOL
        platformFeeAmount: new anchor.BN(10_000_000), // 0.01 SOL
        fiatAmountMinor: new anchor.BN(2000), // $20.00
        fiatCurrency: [85, 83, 68], // "USD"
        exchangeRateId: new anchor.BN(5),
        expiresAt,
      };

      const message = buildQuoteMessage(quoteParams);
      const signature = nacl.sign.detached(message, backendSigner.secretKey);

      const ed25519Ix = Ed25519Program.createInstructionWithPublicKey({
        publicKey: backendSigner.publicKey.toBytes(),
        message,
        signature,
      });

      const [merchantPaymentPda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("merchant_payment"),
          configPda.toBuffer(),
          Buffer.from(refIdHash),
        ],
        program.programId
      );

      const [platformFeePda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("platform_fee"),
          configPda.toBuffer(),
          PublicKey.default.toBuffer(),
        ],
        program.programId
      );

      await program.methods
        .processMerchantPaymentSol({
          refId,
          refIdHash,
          merchantId: "shop-tokyo-01",
          amount: quoteParams.amount,
          platformFeeAmount: quoteParams.platformFeeAmount,
          fiatAmountMinor: quoteParams.fiatAmountMinor,
          fiatCurrency: quoteParams.fiatCurrency,
          exchangeRateId: quoteParams.exchangeRateId,
          expiresAt,
        })
        .accounts({
          payer: owner.publicKey,
          config: configPda,
          allowedToken: allowedPaymentTokenPda(PublicKey.default),
          merchantPayment: merchantPaymentPda,
          platformFeeAccount: platformFeePda,
          instructionsSysvar: anchor.web3.SYSVAR_INSTRUCTIONS_PUBKEY,
          systemProgram: SystemProgram.programId,
        })
        .preInstructions([ed25519Ix])
        .rpc();

      const mp = await program.account.merchantPayment.fetch(
        merchantPaymentPda
      );
      expect(mp.refId).to.equal(refId);
      expect(mp.merchantId).to.equal("shop-tokyo-01");
      expect(mp.amount.toString()).to.equal("200000000");
      expect(mp.platformFeeAmount.toString()).to.equal("10000000");

      const pfa = await program.account.platformFeeAccount.fetch(
        platformFeePda
      );
      expect(pfa.accruedAmount.toNumber()).to.equal(10_000_000);
    });

    it("rejects expired quotes", async () => {
      const refId = "merchant-expired-001";
      const refIdHash = await sha256(refId);
      const expiresAt = new anchor.BN(
        Math.floor(Date.now() / 1000) - 60 // 1 minute ago
      );

      const quoteParams = {
        refId,
        merchantId: "shop-expired",
        tokenMint: PublicKey.default,
        amount: new anchor.BN(100_000_000),
        platformFeeAmount: new anchor.BN(5_000_000),
        fiatAmountMinor: new anchor.BN(1000),
        fiatCurrency: [85, 83, 68],
        exchangeRateId: new anchor.BN(1),
        expiresAt,
      };

      const message = buildQuoteMessage(quoteParams);
      const signature = nacl.sign.detached(message, backendSigner.secretKey);
      const ed25519Ix = Ed25519Program.createInstructionWithPublicKey({
        publicKey: backendSigner.publicKey.toBytes(),
        message,
        signature,
      });

      const [merchantPaymentPda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("merchant_payment"),
          configPda.toBuffer(),
          Buffer.from(refIdHash),
        ],
        program.programId
      );
      const [platformFeePda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("platform_fee"),
          configPda.toBuffer(),
          PublicKey.default.toBuffer(),
        ],
        program.programId
      );

      try {
        await program.methods
          .processMerchantPaymentSol({
            refId,
            refIdHash,
            merchantId: "shop-expired",
            amount: quoteParams.amount,
            platformFeeAmount: quoteParams.platformFeeAmount,
            fiatAmountMinor: quoteParams.fiatAmountMinor,
            fiatCurrency: quoteParams.fiatCurrency,
            exchangeRateId: quoteParams.exchangeRateId,
            expiresAt,
          })
          .accounts({
            payer: owner.publicKey,
            config: configPda,
          allowedToken: allowedPaymentTokenPda(PublicKey.default),
            merchantPayment: merchantPaymentPda,
            platformFeeAccount: platformFeePda,
            instructionsSysvar: anchor.web3.SYSVAR_INSTRUCTIONS_PUBKEY,
            systemProgram: SystemProgram.programId,
          })
          .preInstructions([ed25519Ix])
          .rpc();
        expect.fail("Should have thrown");
      } catch (err: any) {
        expect(err.error?.errorCode?.code).to.equal("QuoteExpired");
      }
    });

    it("rejects wrong backend signer", async () => {
      const refId = "merchant-wrong-sig-001";
      const refIdHash = await sha256(refId);
      const expiresAt = new anchor.BN(
        Math.floor(Date.now() / 1000) + 300
      );

      const wrongSigner = Keypair.generate();

      const quoteParams = {
        refId,
        merchantId: "shop-bad",
        tokenMint: PublicKey.default,
        amount: new anchor.BN(100_000_000),
        platformFeeAmount: new anchor.BN(5_000_000),
        fiatAmountMinor: new anchor.BN(1000),
        fiatCurrency: [85, 83, 68],
        exchangeRateId: new anchor.BN(1),
        expiresAt,
      };

      const message = buildQuoteMessage(quoteParams);
      // Sign with WRONG keypair
      const signature = nacl.sign.detached(message, wrongSigner.secretKey);
      const ed25519Ix = Ed25519Program.createInstructionWithPublicKey({
        publicKey: wrongSigner.publicKey.toBytes(),
        message,
        signature,
      });

      const [merchantPaymentPda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("merchant_payment"),
          configPda.toBuffer(),
          Buffer.from(refIdHash),
        ],
        program.programId
      );
      const [platformFeePda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("platform_fee"),
          configPda.toBuffer(),
          PublicKey.default.toBuffer(),
        ],
        program.programId
      );

      try {
        await program.methods
          .processMerchantPaymentSol({
            refId,
            refIdHash,
            merchantId: "shop-bad",
            amount: quoteParams.amount,
            platformFeeAmount: quoteParams.platformFeeAmount,
            fiatAmountMinor: quoteParams.fiatAmountMinor,
            fiatCurrency: quoteParams.fiatCurrency,
            exchangeRateId: quoteParams.exchangeRateId,
            expiresAt,
          })
          .accounts({
            payer: owner.publicKey,
            config: configPda,
          allowedToken: allowedPaymentTokenPda(PublicKey.default),
            merchantPayment: merchantPaymentPda,
            platformFeeAccount: platformFeePda,
            instructionsSysvar: anchor.web3.SYSVAR_INSTRUCTIONS_PUBKEY,
            systemProgram: SystemProgram.programId,
          })
          .preInstructions([ed25519Ix])
          .rpc();
        expect.fail("Should have thrown");
      } catch (err: any) {
        expect(err.error?.errorCode?.code).to.equal("BadQuote");
      }
    });

    it("rejects fee exceeding amount", async () => {
      const refId = "merchant-fee-exceed-001";
      const refIdHash = await sha256(refId);
      const expiresAt = new anchor.BN(
        Math.floor(Date.now() / 1000) + 300
      );

      const quoteParams = {
        refId,
        merchantId: "shop-fee",
        tokenMint: PublicKey.default,
        amount: new anchor.BN(100_000_000),
        platformFeeAmount: new anchor.BN(200_000_000), // fee > amount
        fiatAmountMinor: new anchor.BN(1000),
        fiatCurrency: [85, 83, 68],
        exchangeRateId: new anchor.BN(1),
        expiresAt,
      };

      const message = buildQuoteMessage(quoteParams);
      const signature = nacl.sign.detached(message, backendSigner.secretKey);
      const ed25519Ix = Ed25519Program.createInstructionWithPublicKey({
        publicKey: backendSigner.publicKey.toBytes(),
        message,
        signature,
      });

      const [merchantPaymentPda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("merchant_payment"),
          configPda.toBuffer(),
          Buffer.from(refIdHash),
        ],
        program.programId
      );
      const [platformFeePda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("platform_fee"),
          configPda.toBuffer(),
          PublicKey.default.toBuffer(),
        ],
        program.programId
      );

      try {
        await program.methods
          .processMerchantPaymentSol({
            refId,
            refIdHash,
            merchantId: "shop-fee",
            amount: quoteParams.amount,
            platformFeeAmount: quoteParams.platformFeeAmount,
            fiatAmountMinor: quoteParams.fiatAmountMinor,
            fiatCurrency: quoteParams.fiatCurrency,
            exchangeRateId: quoteParams.exchangeRateId,
            expiresAt,
          })
          .accounts({
            payer: owner.publicKey,
            config: configPda,
          allowedToken: allowedPaymentTokenPda(PublicKey.default),
            merchantPayment: merchantPaymentPda,
            platformFeeAccount: platformFeePda,
            instructionsSysvar: anchor.web3.SYSVAR_INSTRUCTIONS_PUBKEY,
            systemProgram: SystemProgram.programId,
          })
          .preInstructions([ed25519Ix])
          .rpc();
        expect.fail("Should have thrown");
      } catch (err: any) {
        expect(err.error?.errorCode?.code).to.equal("FeeExceedsAmount");
      }
    });
  });

  // ── Merchant Payments — Token ────────────────────────────────────────

  describe("Merchant Payments — Token", () => {
    it("processes a token merchant payment", async () => {
      const refId = "merchant-token-001";
      const refIdHash = await sha256(refId);
      const expiresAt = new anchor.BN(
        Math.floor(Date.now() / 1000) + 300
      );

      const quoteParams = {
        refId,
        merchantId: "shop-token-01",
        tokenMint,
        amount: new anchor.BN(50_000), // 0.05 tokens
        platformFeeAmount: new anchor.BN(2_500),
        fiatAmountMinor: new anchor.BN(500),
        fiatCurrency: [85, 83, 68],
        exchangeRateId: new anchor.BN(10),
        expiresAt,
      };

      const message = buildQuoteMessage(quoteParams);
      const signature = nacl.sign.detached(message, backendSigner.secretKey);
      const ed25519Ix = Ed25519Program.createInstructionWithPublicKey({
        publicKey: backendSigner.publicKey.toBytes(),
        message,
        signature,
      });

      const [merchantPaymentPda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("merchant_payment"),
          configPda.toBuffer(),
          Buffer.from(refIdHash),
        ],
        program.programId
      );
      const [platformFeePda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("platform_fee"),
          configPda.toBuffer(),
          tokenMint.toBuffer(),
        ],
        program.programId
      );

      const payerAta = getAssociatedTokenAddressSync(
        tokenMint,
        owner.publicKey
      );
      const vaultAta = getAssociatedTokenAddressSync(tokenMint, configPda, true);

      await program.methods
        .processMerchantPaymentToken({
          refId,
          refIdHash,
          merchantId: "shop-token-01",
          amount: quoteParams.amount,
          platformFeeAmount: quoteParams.platformFeeAmount,
          fiatAmountMinor: quoteParams.fiatAmountMinor,
          fiatCurrency: quoteParams.fiatCurrency,
          exchangeRateId: quoteParams.exchangeRateId,
          expiresAt,
        })
        .accounts({
          payer: owner.publicKey,
          config: configPda,
          allowedToken: allowedPaymentTokenPda(tokenMint),
          merchantPayment: merchantPaymentPda,
          platformFeeAccount: platformFeePda,
          tokenMint,
          payerTokenAccount: payerAta,
          vaultTokenAccount: vaultAta,
          instructionsSysvar: anchor.web3.SYSVAR_INSTRUCTIONS_PUBKEY,
          tokenProgram: TOKEN_PROGRAM_ID,
          associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .preInstructions([ed25519Ix])
        .rpc();

      const mp = await program.account.merchantPayment.fetch(
        merchantPaymentPda
      );
      expect(mp.tokenMint.toBase58()).to.equal(tokenMint.toBase58());
      expect(mp.amount.toNumber()).to.equal(50_000);

      const pfa = await program.account.platformFeeAccount.fetch(
        platformFeePda
      );
      expect(pfa.accruedAmount.toNumber()).to.equal(2_500);
    });
  });

  // ── Withdrawals — Immediate ──────────────────────────────────────────

  describe("Withdrawals — Immediate", () => {
    before(async () => {
      // Withdrawals draw on the sweep cap like every other exit and fail closed
      // without one. Finite here so the Treasury block can still raise them.
      await raiseSweepCap(PublicKey.default, new anchor.BN("1000000000000000"));
      await raiseSweepCap(tokenMint, new anchor.BN("1000000000000000"));
    });

    it("withdraws SOL", async () => {
      const recipient = Keypair.generate();

      await airdrop(connection, configPda, LAMPORTS_PER_SOL);

      const amount = new anchor.BN(50_000_000);

      await program.methods
        .withdrawSol(amount)
        .accounts({
          owner: owner.publicKey,
          config: configPda,
          sweepCap: sweepCapPda(PublicKey.default),
          platformFeeAccount: platformFeePda(PublicKey.default),
          recipient: recipient.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .rpc();

      const balance = await connection.getBalance(recipient.publicKey);
      expect(balance).to.equal(50_000_000);
    });

    it("withdraws tokens", async () => {
      const recipient = Keypair.generate();
      const recipientAta = await getOrCreateAssociatedTokenAccount(
        connection,
        owner.payer,
        tokenMint,
        recipient.publicKey
      );
      const vaultAta = getAssociatedTokenAddressSync(tokenMint, configPda, true);

      const amount = new anchor.BN(10_000);

      await program.methods
        .withdrawToken(amount)
        .accounts({
          owner: owner.publicKey,
          config: configPda,
          tokenMint,
          vaultTokenAccount: vaultAta,
          sweepCap: sweepCapPda(tokenMint),
          platformFeeAccount: platformFeePda(tokenMint),
          recipientTokenAccount: recipientAta.address,
          tokenProgram: TOKEN_PROGRAM_ID,
        })
        .rpc();

      const ata = await getOrCreateAssociatedTokenAccount(
        connection,
        owner.payer,
        tokenMint,
        recipient.publicKey
      );
      expect(Number(ata.amount)).to.equal(10_000);
    });

    it("rejects non-owner withdrawal", async () => {
      const nobody = Keypair.generate();
      await airdrop(connection, nobody.publicKey, LAMPORTS_PER_SOL);

      try {
        await program.methods
          .withdrawSol(new anchor.BN(1_000_000))
          .accounts({
            owner: nobody.publicKey,
            config: configPda,
            sweepCap: sweepCapPda(PublicKey.default),
            platformFeeAccount: platformFeePda(PublicKey.default),
            recipient: nobody.publicKey,
            systemProgram: SystemProgram.programId,
          })
          .signers([nobody])
          .rpc();
        expect.fail("Should have thrown");
      } catch (err: any) {
        expect(err.error?.errorCode?.code).to.be.oneOf([
          "NotOwner",
          "ConstraintHasOne",
        ]);
      }
    });
  });

  // ── Withdrawals — Timelock ───────────────────────────────────────────

  describe("Withdrawals — Timelock", () => {
    it("sets withdrawal delay", async () => {
      await program.methods
        .setWithdrawalDelay(new anchor.BN(2))
        .accounts({ owner: owner.publicKey, config: configPda })
        .rpc();

      const config = await program.account.config.fetch(configPda);
      expect(config.withdrawalDelay.toNumber()).to.equal(2);
    });

    it("rejects immediate withdrawal when delay is set", async () => {
      try {
        await program.methods
          .withdrawSol(new anchor.BN(1_000_000))
          .accounts({
            owner: owner.publicKey,
            config: configPda,
            sweepCap: sweepCapPda(PublicKey.default),
            platformFeeAccount: platformFeePda(PublicKey.default),
            recipient: owner.publicKey,
            systemProgram: SystemProgram.programId,
          })
          .rpc();
        expect.fail("Should have thrown");
      } catch (err: any) {
        expect(err.error?.errorCode?.code).to.equal("TimelockActive");
      }
    });

    it("queues, waits, and executes a timelocked SOL withdrawal", async () => {
      const recipient = Keypair.generate();
      const config = await program.account.config.fetch(configPda);
      const nextNonce = config.withdrawalNonce.toNumber() + 1;

      const [withdrawalPda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("withdrawal"),
          configPda.toBuffer(),
          u64LeBytes(nextNonce),
        ],
        program.programId
      );

      await program.methods
        .queueWithdrawal(
          PublicKey.default,
          recipient.publicKey,
          new anchor.BN(25_000_000),
          true
        )
        .accounts({
          owner: owner.publicKey,
          config: configPda,
          withdrawalRequest: withdrawalPda,
          systemProgram: SystemProgram.programId,
        })
        .rpc();

      const wr = await program.account.withdrawalRequest.fetch(withdrawalPda);
      expect(wr.amount.toNumber()).to.equal(25_000_000);
      expect(wr.executed).to.equal(false);
      expect(wr.cancelled).to.equal(false);
      expect(wr.isNative).to.equal(true);

      // Wait for timelock to expire (delay = 2 seconds)
      await sleep(4000);

      await program.methods
        .executeWithdrawalSol()
        .accounts({
          owner: owner.publicKey,
          config: configPda,
          withdrawalRequest: withdrawalPda,
          sweepCap: sweepCapPda(PublicKey.default),
          platformFeeAccount: platformFeePda(PublicKey.default),
          recipient: recipient.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .rpc();

      const balance = await connection.getBalance(recipient.publicKey);
      expect(balance).to.equal(25_000_000);

      const wrAfter = await program.account.withdrawalRequest.fetch(
        withdrawalPda
      );
      expect(wrAfter.executed).to.equal(true);
    });

    it("cancels a queued withdrawal", async () => {
      const config = await program.account.config.fetch(configPda);
      const nextNonce = config.withdrawalNonce.toNumber() + 1;

      const [withdrawalPda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("withdrawal"),
          configPda.toBuffer(),
          u64LeBytes(nextNonce),
        ],
        program.programId
      );

      await program.methods
        .queueWithdrawal(
          PublicKey.default,
          owner.publicKey,
          new anchor.BN(10_000_000),
          true
        )
        .accounts({
          owner: owner.publicKey,
          config: configPda,
          withdrawalRequest: withdrawalPda,
          systemProgram: SystemProgram.programId,
        })
        .rpc();

      await program.methods
        .cancelWithdrawal()
        .accounts({
          owner: owner.publicKey,
          config: configPda,
          withdrawalRequest: withdrawalPda,
        })
        .rpc();

      const wr = await program.account.withdrawalRequest.fetch(withdrawalPda);
      expect(wr.cancelled).to.equal(true);
    });

    it("rejects executing a cancelled withdrawal", async () => {
      const config = await program.account.config.fetch(configPda);
      const nonce = config.withdrawalNonce.toNumber(); // the one we just cancelled

      const [withdrawalPda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("withdrawal"),
          configPda.toBuffer(),
          u64LeBytes(nonce),
        ],
        program.programId
      );

      try {
        await program.methods
          .executeWithdrawalSol()
          .accounts({
            owner: owner.publicKey,
            config: configPda,
            withdrawalRequest: withdrawalPda,
            sweepCap: sweepCapPda(PublicKey.default),
            platformFeeAccount: platformFeePda(PublicKey.default),
            recipient: owner.publicKey,
            systemProgram: SystemProgram.programId,
          })
          .rpc();
        expect.fail("Should have thrown");
      } catch (err: any) {
        expect(err.error?.errorCode?.code).to.equal("AlreadyCancelled");
      }
    });

    it("rejects lowering the delay in a single call", async () => {
      // The original bypass: setWithdrawalDelay(0) then withdraw() in one
      // transaction made the timelock decorative.
      try {
        await program.methods
          .setWithdrawalDelay(new anchor.BN(0))
          .accounts({ owner: owner.publicKey, config: configPda })
          .rpc();
        expect.fail("Should have thrown");
      } catch (err: any) {
        expect(err.error?.errorCode?.code).to.equal("NotALoosening");
      }

      const config = await program.account.config.fetch(configPda);
      expect(config.withdrawalDelay.toNumber()).to.equal(2);
    });

    it("lowers the delay only after waiting it out", async () => {
      await program.methods
        .queueWithdrawalDelay(new anchor.BN(0))
        .accounts({ owner: owner.publicKey, config: configPda })
        .rpc();

      // Still locked — the reduction is subject to the delay in force.
      try {
        await program.methods
          .applyWithdrawalDelay()
          .accounts({ owner: owner.publicKey, config: configPda })
          .rpc();
        expect.fail("Should have thrown");
      } catch (err: any) {
        expect(err.error?.errorCode?.code).to.equal("PendingChangeLocked");
      }

      await sleep(3000);
      await program.methods
        .applyWithdrawalDelay()
        .accounts({ owner: owner.publicKey, config: configPda })
        .rpc();

      const config = await program.account.config.fetch(configPda);
      expect(config.withdrawalDelay.toNumber()).to.equal(0);
    });
  });

  // ── Point Deposits ────────────────────────────────────────────────���──

  describe("Point Deposits", () => {
    before(async () => {
      secondTokenMint = await createMint(
        connection,
        owner.payer,
        owner.publicKey,
        null,
        6
      );

      const ata = await getOrCreateAssociatedTokenAccount(
        connection,
        owner.payer,
        secondTokenMint,
        owner.publicKey
      );
      await mintTo(
        connection,
        owner.payer,
        secondTokenMint,
        ata.address,
        owner.publicKey,
        500_000_000
      );
    });

    it("adds an allowed payment token", async () => {
      const allowedPda = await allowPaymentToken(secondTokenMint);

      const at = await program.account.allowedPaymentToken.fetch(allowedPda);
      expect(at.tokenMint.toBase58()).to.equal(secondTokenMint.toBase58());
    });

    it("deposits points", async () => {
      const refId = "point-ref-001";
      const refIdHash = await sha256(refId);
      const config = await program.account.config.fetch(configPda);
      const nextDepositId = config.pointDepositCounter.toNumber() + 1;

      const [pointDepositPda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("point_deposit"),
          configPda.toBuffer(),
          u64LeBytes(nextDepositId),
        ],
        program.programId
      );
      const [pointRefPda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("point_ref"),
          configPda.toBuffer(),
          Buffer.from(refIdHash),
        ],
        program.programId
      );
      const allowedPda = allowedPaymentTokenPda(secondTokenMint);

      const payerAta = getAssociatedTokenAddressSync(
        secondTokenMint,
        owner.publicKey
      );
      const vaultAta = getAssociatedTokenAddressSync(
        secondTokenMint,
        configPda,
        true
      );

      await program.methods
        .depositPoints(refId, refIdHash, new anchor.BN(100_000))
        .accounts({
          payer: owner.publicKey,
          config: configPda,
          tokenMint: secondTokenMint,
          allowedToken: allowedPda,
          pointDeposit: pointDepositPda,
          pointRefRecord: pointRefPda,
          payerTokenAccount: payerAta,
          vaultTokenAccount: vaultAta,
          tokenProgram: TOKEN_PROGRAM_ID,
          associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .rpc();

      const pd = await program.account.pointDepositRecord.fetch(
        pointDepositPda
      );
      expect(pd.amount.toNumber()).to.equal(100_000);
      expect(pd.refId).to.equal(refId);
    });

    it("rejects duplicate point ref IDs", async () => {
      const refId = "point-ref-001"; // same as above
      const refIdHash = await sha256(refId);
      const config = await program.account.config.fetch(configPda);
      const nextDepositId = config.pointDepositCounter.toNumber() + 1;

      const [pointDepositPda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("point_deposit"),
          configPda.toBuffer(),
          u64LeBytes(nextDepositId),
        ],
        program.programId
      );
      const [pointRefPda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("point_ref"),
          configPda.toBuffer(),
          Buffer.from(refIdHash),
        ],
        program.programId
      );
      const allowedPda = allowedPaymentTokenPda(secondTokenMint);

      const payerAta = getAssociatedTokenAddressSync(
        secondTokenMint,
        owner.publicKey
      );
      const vaultAta = getAssociatedTokenAddressSync(
        secondTokenMint,
        configPda,
        true
      );

      try {
        await program.methods
          .depositPoints(refId, refIdHash, new anchor.BN(50_000))
          .accounts({
            payer: owner.publicKey,
            config: configPda,
            tokenMint: secondTokenMint,
            allowedToken: allowedPda,
            pointDeposit: pointDepositPda,
            pointRefRecord: pointRefPda,
            payerTokenAccount: payerAta,
            vaultTokenAccount: vaultAta,
            tokenProgram: TOKEN_PROGRAM_ID,
            associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
          })
          .rpc();
        expect.fail("Should have thrown");
      } catch (err) {
        expect(err).to.exist;
      }
    });

    it("pauses and rejects point deposits", async () => {
      await program.methods
        .setPointDepositsPaused(true)
        .accounts({
          authority: owner.publicKey,
          config: configPda,
          adminRecord: null,
        })
        .rpc();

      const refId = "point-ref-paused";
      const refIdHash = await sha256(refId);
      const config = await program.account.config.fetch(configPda);
      const nextDepositId = config.pointDepositCounter.toNumber() + 1;

      const [pointDepositPda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("point_deposit"),
          configPda.toBuffer(),
          u64LeBytes(nextDepositId),
        ],
        program.programId
      );
      const [pointRefPda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("point_ref"),
          configPda.toBuffer(),
          Buffer.from(refIdHash),
        ],
        program.programId
      );
      const allowedPda = allowedPaymentTokenPda(secondTokenMint);

      const payerAta = getAssociatedTokenAddressSync(
        secondTokenMint,
        owner.publicKey
      );
      const vaultAta = getAssociatedTokenAddressSync(
        secondTokenMint,
        configPda,
        true
      );

      try {
        await program.methods
          .depositPoints(refId, refIdHash, new anchor.BN(10_000))
          .accounts({
            payer: owner.publicKey,
            config: configPda,
            tokenMint: secondTokenMint,
            allowedToken: allowedPda,
            pointDeposit: pointDepositPda,
            pointRefRecord: pointRefPda,
            payerTokenAccount: payerAta,
            vaultTokenAccount: vaultAta,
            tokenProgram: TOKEN_PROGRAM_ID,
            associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
          })
          .rpc();
        expect.fail("Should have thrown");
      } catch (err: any) {
        expect(err.error?.errorCode?.code || "PointDepositsPaused").to.equal(
          "PointDepositsPaused"
        );
      }

      // Unpause
      await program.methods
        .setPointDepositsPaused(false)
        .accounts({
          authority: owner.publicKey,
          config: configPda,
          adminRecord: null,
        })
        .rpc();
    });

    it("removes an allowed payment token", async () => {
      const allowedPda = allowedPaymentTokenPda(secondTokenMint);

      await program.methods
        .removeAllowedPaymentToken(secondTokenMint)
        .accounts({
          owner: owner.publicKey,
          config: configPda,
          allowedToken: allowedPda,
        })
        .rpc();

      const info = await connection.getAccountInfo(allowedPda);
      expect(info).to.be.null;
    });
  });

  // ── Treasury ─────────────────────────────────────────────────────────

  describe("Treasury", () => {
    before(async () => {
      // Sweeps fail closed until a cap exists — configure both native and SPL.
      const unlimited = new anchor.BN("18446744073709551615"); // u64::MAX
      await raiseSweepCap(PublicKey.default, unlimited);
      await raiseSweepCap(tokenMint, unlimited);
    });

    it("rejects a sweep for a token with no cap configured", async () => {
      const uncapped = await createMint(
        connection,
        owner.payer,
        owner.publicKey,
        null,
        6
      );

      try {
        await program.methods
          .sweepMerchantBackingToken(new anchor.BN(1))
          .accounts({
            owner: owner.publicKey,
            config: configPda,
            sweepCap: sweepCapPda(uncapped),
            platformFeeAccount: platformFeePda(uncapped),
            tokenMint: uncapped,
            vaultTokenAccount: getAssociatedTokenAddressSync(
              uncapped,
              configPda,
              true
            ),
            recipientTokenAccount: getAssociatedTokenAddressSync(
              uncapped,
              owner.publicKey
            ),
            tokenProgram: TOKEN_PROGRAM_ID,
          } as any)
          .rpc();
        expect.fail("Should have thrown");
      } catch (err: any) {
        // The cap PDA was never created, so the sweep fails closed loading it.
        expect(err.error?.errorCode?.code).to.equal("AccountNotInitialized");
      }
    });

    it("sweeps platform fees SOL", async () => {
      const recipient = Keypair.generate();

      const [platformFeePda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("platform_fee"),
          configPda.toBuffer(),
          PublicKey.default.toBuffer(),
        ],
        program.programId
      );

      const pfaBefore = await program.account.platformFeeAccount.fetch(
        platformFeePda
      );
      const sweepAmount = new anchor.BN(5_000_000);

      await program.methods
        .sweepPlatformFeesSol(sweepAmount)
        .accounts({
          owner: owner.publicKey,
          config: configPda,
          sweepCap: sweepCapPda(PublicKey.default),
          platformFeeAccount: platformFeePda,
          recipient: recipient.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .rpc();

      const pfaAfter = await program.account.platformFeeAccount.fetch(
        platformFeePda
      );
      expect(pfaAfter.accruedAmount.toNumber()).to.equal(
        pfaBefore.accruedAmount.toNumber() - sweepAmount.toNumber()
      );

      const balance = await connection.getBalance(recipient.publicKey);
      expect(balance).to.equal(5_000_000);
    });

    it("rejects sweep exceeding accrued fees", async () => {
      const [platformFeePda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("platform_fee"),
          configPda.toBuffer(),
          PublicKey.default.toBuffer(),
        ],
        program.programId
      );

      try {
        await program.methods
          .sweepPlatformFeesSol(new anchor.BN(999_999_999_999))
          .accounts({
            owner: owner.publicKey,
            config: configPda,
          sweepCap: sweepCapPda(PublicKey.default),
            platformFeeAccount: platformFeePda,
            recipient: owner.publicKey,
            systemProgram: SystemProgram.programId,
          })
          .rpc();
        expect.fail("Should have thrown");
      } catch (err: any) {
        expect(err.error?.errorCode?.code).to.equal("FeeAmountInvalid");
      }
    });

    it("sweeps merchant backing SOL", async () => {
      const recipient = Keypair.generate();

      await program.methods
        .sweepMerchantBackingSol(new anchor.BN(10_000_000))
        .accounts({
          owner: owner.publicKey,
          config: configPda,
          sweepCap: sweepCapPda(PublicKey.default),
          platformFeeAccount: platformFeePda(PublicKey.default),
          recipient: recipient.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .rpc();

      const balance = await connection.getBalance(recipient.publicKey);
      expect(balance).to.equal(10_000_000);
    });

    it("sweeps platform fees token", async () => {
      const [platformFeePda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("platform_fee"),
          configPda.toBuffer(),
          tokenMint.toBuffer(),
        ],
        program.programId
      );

      const recipient = Keypair.generate();
      const recipientAta = await getOrCreateAssociatedTokenAccount(
        connection,
        owner.payer,
        tokenMint,
        recipient.publicKey
      );
      const vaultAta = getAssociatedTokenAddressSync(tokenMint, configPda, true);

      const pfa = await program.account.platformFeeAccount.fetch(
        platformFeePda
      );
      const sweepAmount = pfa.accruedAmount;

      await program.methods
        .sweepPlatformFeesToken(sweepAmount)
        .accounts({
          owner: owner.publicKey,
          config: configPda,
          sweepCap: sweepCapPda(tokenMint),
          tokenMint,
          platformFeeAccount: platformFeePda,
          vaultTokenAccount: vaultAta,
          recipientTokenAccount: recipientAta.address,
          tokenProgram: TOKEN_PROGRAM_ID,
        })
        .rpc();

      const pfaAfter = await program.account.platformFeeAccount.fetch(
        platformFeePda
      );
      expect(pfaAfter.accruedAmount.toNumber()).to.equal(0);
    });

    it("sweeps merchant backing token", async () => {
      const recipient = Keypair.generate();
      const recipientAta = await getOrCreateAssociatedTokenAccount(
        connection,
        owner.payer,
        tokenMint,
        recipient.publicKey
      );
      const vaultAta = getAssociatedTokenAddressSync(tokenMint, configPda, true);

      await program.methods
        .sweepMerchantBackingToken(new anchor.BN(5_000))
        .accounts({
          owner: owner.publicKey,
          config: configPda,
          sweepCap: sweepCapPda(tokenMint),
          platformFeeAccount: platformFeePda(tokenMint),
          tokenMint,
          vaultTokenAccount: vaultAta,
          recipientTokenAccount: recipientAta.address,
          tokenProgram: TOKEN_PROGRAM_ID,
        })
        .rpc();

      const ata = await getOrCreateAssociatedTokenAccount(
        connection,
        owner.payer,
        tokenMint,
        recipient.publicKey
      );
      expect(Number(ata.amount)).to.equal(5_000);
    });
  });

  // ── Backend Signer ──────────────────────────────────────────���────────

  describe("Backend Signer", () => {
    it("rotates backend signer", async () => {
      const newSigner = Keypair.generate();

      await program.methods
        .rotateBackendSigner(newSigner.publicKey)
        .accounts({ owner: owner.publicKey, config: configPda })
        .rpc();

      const config = await program.account.config.fetch(configPda);
      expect(config.backendSigner.toBase58()).to.equal(
        newSigner.publicKey.toBase58()
      );

      // Rotate back to original for consistency
      await program.methods
        .rotateBackendSigner(backendSigner.publicKey)
        .accounts({ owner: owner.publicKey, config: configPda })
        .rpc();
    });

    it("rejects zero address as signer", async () => {
      try {
        await program.methods
          .rotateBackendSigner(PublicKey.default)
          .accounts({ owner: owner.publicKey, config: configPda })
          .rpc();
        expect.fail("Should have thrown");
      } catch (err: any) {
        expect(err.error?.errorCode?.code).to.equal("ZeroSigner");
      }
    });
  });

  // ── Withdrawal Delay Edge Cases ──────────────────────────────────────

  describe("Sweep Cap", () => {
    it("lowers immediately but rejects raising in a single call", async () => {
      const pda = sweepCapPda(tokenMint);

      // Tightening is immediate.
      await program.methods
        .setSweepCap(tokenMint, new anchor.BN(1_000))
        .accounts({
          owner: owner.publicKey,
          config: configPda,
          sweepCap: pda,
          systemProgram: SystemProgram.programId,
        })
        .rpc();

      let sc = await program.account.sweepCap.fetch(pda);
      expect(sc.cap.toNumber()).to.equal(1_000);

      // Raising in one call would put the rate limit one call from defeat.
      try {
        await program.methods
          .setSweepCap(tokenMint, new anchor.BN(5_000))
          .accounts({
            owner: owner.publicKey,
            config: configPda,
            sweepCap: pda,
            systemProgram: SystemProgram.programId,
          })
          .rpc();
        expect.fail("Should have thrown");
      } catch (err: any) {
        expect(err.error?.errorCode?.code).to.equal("NotALoosening");
      }

      // Queue + apply is the supported path.
      await raiseSweepCap(tokenMint, new anchor.BN(5_000));
      sc = await program.account.sweepCap.fetch(pda);
      expect(sc.cap.toNumber()).to.equal(5_000);
    });
  });

  describe("Withdrawal Delay Edge Cases", () => {
    it("rejects delay exceeding maximum (7 days)", async () => {
      const eightDays = 8 * 24 * 60 * 60;
      try {
        await program.methods
          .setWithdrawalDelay(new anchor.BN(eightDays))
          .accounts({ owner: owner.publicKey, config: configPda })
          .rpc();
        expect.fail("Should have thrown");
      } catch (err: any) {
        expect(err.error?.errorCode?.code).to.equal("DelayExceedsMax");
      }
    });
  });

  // ── Fixes ported from EVM 2.3.0 ──────────────────────────────────────
  // Section numbers refer to the Olympix scan of the EVM contract
  // (contract/evm/docs/olympix-bugpocer-response-2.2.0.md). The timing rules
  // themselves (exact 24h expiry, the 16-exit log) are unit-tested in
  // state.rs; these check the instructions are wired to them.

  describe("EVM 2.3.0 parity", () => {
    const UNLIMITED = new anchor.BN("18446744073709551615");
    let mint: PublicKey;
    let vault: PublicKey;

    before(async () => {
      mint = await createMint(connection, owner.payer, owner.publicKey, null, 6);
      vault = (
        await getOrCreateAssociatedTokenAccount(connection, owner.payer, mint, configPda, true)
      ).address;
      await mintTo(connection, owner.payer, mint, vault, owner.payer, 1_000_000);
      await allowPaymentToken(mint);
    });

    const freshRecipient = async (): Promise<PublicKey> =>
      (
        await getOrCreateAssociatedTokenAccount(
          connection,
          owner.payer,
          mint,
          Keypair.generate().publicKey
        )
      ).address;

    const exitAccounts = (to: PublicKey) => ({
      owner: owner.publicKey,
      config: configPda,
      sweepCap: sweepCapPda(mint),
      platformFeeAccount: platformFeePda(mint),
      tokenMint: mint,
      vaultTokenAccount: vault,
      recipientTokenAccount: to,
      tokenProgram: TOKEN_PROGRAM_ID,
    });

    const errorCode = async (p: Promise<unknown>): Promise<string | undefined> => {
      try {
        await p;
        return undefined;
      } catch (err: any) {
        return err.error?.errorCode?.code;
      }
    };

    it("withdrawals draw on the sweep cap and fail closed without one", async () => {
      const to = await freshRecipient();
      expect(
        await errorCode(program.methods.withdrawToken(new anchor.BN(1)).accounts(exitAccounts(to)).rpc())
      ).to.equal("AccountNotInitialized");

      await raiseSweepCap(mint, new anchor.BN(100_000));
      await program.methods.sweepMerchantBackingToken(new anchor.BN(60_000)).accounts(exitAccounts(to)).rpc();
      expect(
        await errorCode(program.methods.withdrawToken(new anchor.BN(50_000)).accounts(exitAccounts(to)).rpc())
      ).to.equal("SweepCapExceeded");
      await program.methods.withdrawToken(new anchor.BN(40_000)).accounts(exitAccounts(to)).rpc();

      const sc = await program.account.sweepCap.fetch(sweepCapPda(mint));
      expect(sc.exitLog.filter((e: anchor.BN) => !e.isZero()).length).to.equal(2);
    });

    it("the brake cancels a queued raise (5.2.4)", async () => {
      const capAccounts = {
        owner: owner.publicKey,
        config: configPda,
        sweepCap: sweepCapPda(mint),
        systemProgram: SystemProgram.programId,
      };
      await program.methods.queueSweepCap(mint, UNLIMITED).accounts(capAccounts).rpc();
      let sc = await program.account.sweepCap.fetch(sweepCapPda(mint));
      expect(sc.pendingUnlockTime.toNumber()).to.be.greaterThan(0);

      await program.methods.setSweepCap(mint, new anchor.BN(0)).accounts(capAccounts).rpc();
      sc = await program.account.sweepCap.fetch(sweepCapPda(mint));
      expect(sc.cap.toNumber()).to.equal(0);
      expect(sc.pendingUnlockTime.toNumber()).to.equal(0);
      expect(
        await errorCode(program.methods.applySweepCap(mint).accounts({
          owner: owner.publicKey,
          config: configPda,
          sweepCap: sweepCapPda(mint),
        }).rpc())
      ).to.equal("NoPendingChange");
    });

    it("backing sweeps leave accrued fees; withdrawals book the fees they take (5.2.5)", async () => {
      await raiseSweepCap(mint, UNLIMITED);

      // A merchant payment of 50_000 with a 5_000 fee into the mint.
      const refId = "parity-fee-001";
      const refIdHash = await sha256(refId);
      const expiresAt = new anchor.BN(Math.floor(Date.now() / 1000) + 300);
      const quote = {
        refId,
        merchantId: "shop-parity",
        tokenMint: mint,
        amount: new anchor.BN(50_000),
        platformFeeAmount: new anchor.BN(5_000),
        fiatAmountMinor: new anchor.BN(500),
        fiatCurrency: [85, 83, 68],
        exchangeRateId: new anchor.BN(10),
        expiresAt,
      };
      const message = buildQuoteMessage(quote);
      const signature = nacl.sign.detached(message, backendSigner.secretKey);
      const payerAta = await getOrCreateAssociatedTokenAccount(connection, owner.payer, mint, owner.publicKey);
      await mintTo(connection, owner.payer, mint, payerAta.address, owner.payer, 50_000);
      await program.methods
        .processMerchantPaymentToken({
          refId,
          refIdHash,
          merchantId: quote.merchantId,
          amount: quote.amount,
          platformFeeAmount: quote.platformFeeAmount,
          fiatAmountMinor: quote.fiatAmountMinor,
          fiatCurrency: quote.fiatCurrency,
          exchangeRateId: quote.exchangeRateId,
          expiresAt,
        })
        .accounts({
          payer: owner.publicKey,
          config: configPda,
          allowedToken: allowedPaymentTokenPda(mint),
          merchantPayment: PublicKey.findProgramAddressSync(
            [Buffer.from("merchant_payment"), configPda.toBuffer(), Buffer.from(refIdHash)],
            program.programId
          )[0],
          platformFeeAccount: platformFeePda(mint),
          tokenMint: mint,
          payerTokenAccount: payerAta.address,
          vaultTokenAccount: vault,
          instructionsSysvar: anchor.web3.SYSVAR_INSTRUCTIONS_PUBKEY,
          tokenProgram: TOKEN_PROGRAM_ID,
          associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .preInstructions([
          Ed25519Program.createInstructionWithPublicKey({
            publicKey: backendSigner.publicKey.toBytes(),
            message,
            signature,
          }),
        ])
        .rpc();

      const to = await freshRecipient();
      const held = Number((await getAccount(connection, vault)).amount);
      expect(
        await errorCode(
          program.methods.sweepMerchantBackingToken(new anchor.BN(held)).accounts(exitAccounts(to)).rpc()
        )
      ).to.equal("InsufficientBalance");

      // Sweep down to 6_000 left: 5_000 of fees and 1_000 of float.
      await program.methods
        .sweepMerchantBackingToken(new anchor.BN(held - 6_000))
        .accounts(exitAccounts(to))
        .rpc();

      // Withdrawing 4_000 dips 3_000 into the fee-backed balance.
      const sig = await program.methods.withdrawToken(new anchor.BN(4_000)).accounts(exitAccounts(to)).rpc();
      const pfa = await program.account.platformFeeAccount.fetch(platformFeePda(mint));
      expect(pfa.accruedAmount.toNumber()).to.equal(2_000);

      await connection.confirmTransaction(sig, "confirmed");
      const tx = await connection.getTransaction(sig, { commitment: "confirmed", maxSupportedTransactionVersion: 0 });
      const events = [...new anchor.EventParser(program.programId, program.coder).parseLogs(tx!.meta!.logMessages!)];
      const swept = events.find((e) => e.name === "platformFeesSwept");
      expect(swept?.data.amount.toNumber()).to.equal(3_000);
      expect(swept?.data.recipient.toBase58()).to.equal(to.toBase58());
    });

    it("raising the delay re-arms a queued cap raise (5.2.1)", async () => {
      const someMint = Keypair.generate().publicKey;
      const capAccounts = {
        owner: owner.publicKey,
        config: configPda,
        sweepCap: sweepCapPda(someMint),
        systemProgram: SystemProgram.programId,
      };
      const delay = (seconds: number) =>
        program.methods
          .setWithdrawalDelay(new anchor.BN(seconds))
          .accounts({ owner: owner.publicKey, config: configPda })
          .rpc();
      const apply = () =>
        program.methods
          .applySweepCap(someMint)
          .accounts({ owner: owner.publicKey, config: configPda, sweepCap: sweepCapPda(someMint) })
          .rpc();

      await delay(2);
      await program.methods.queueSweepCap(someMint, new anchor.BN(1_000)).accounts(capAccounts).rpc();
      await delay(6); // raised: the queued raise now waits the full 6s from here
      await sleep(3_000); // past the raise's own 2s unlock
      expect(await errorCode(apply())).to.equal("PendingChangeLocked");

      await sleep(4_000); // past the re-armed 6s
      await apply();
      const sc = await program.account.sweepCap.fetch(sweepCapPda(someMint));
      expect(sc.cap.toNumber()).to.equal(1_000);

      // Back to 0 for anything that runs after this.
      await program.methods
        .queueWithdrawalDelay(new anchor.BN(0))
        .accounts({ owner: owner.publicKey, config: configPda })
        .rpc();
      await sleep(7_000);
      await program.methods
        .applyWithdrawalDelay()
        .accounts({ owner: owner.publicKey, config: configPda })
        .rpc();
    });
  });
});
