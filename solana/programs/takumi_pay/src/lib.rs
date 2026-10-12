use anchor_lang::prelude::*;

declare_id!("Baj91uzqwt8hRaJmke3dV8RdBwjq5MaWEtKNuUFTBBwS");

pub mod errors;
pub mod instructions;
pub mod state;

use instructions::*;
use state::*;

#[program]
pub mod takumi_pay {
    use super::*;

    // ── Initialize ─────────────────────────────────────────────────────

    pub fn initialize(ctx: Context<Initialize>, backend_signer: Pubkey) -> Result<()> {
        instructions::admin::handle_initialize(ctx, backend_signer)
    }

    // ── Admin Management ───────────────────────────────────────────────

    pub fn add_admin(ctx: Context<AddAdmin>) -> Result<()> {
        instructions::admin::handle_add_admin(ctx)
    }

    pub fn remove_admin(ctx: Context<RemoveAdmin>) -> Result<()> {
        instructions::admin::handle_remove_admin(ctx)
    }

    // ── Ownership Transfer ─────────────────────────────────────────────

    pub fn transfer_ownership(ctx: Context<TransferOwnership>, new_owner: Pubkey) -> Result<()> {
        instructions::admin::handle_transfer_ownership(ctx, new_owner)
    }

    pub fn accept_ownership(ctx: Context<AcceptOwnership>) -> Result<()> {
        instructions::admin::handle_accept_ownership(ctx)
    }

    pub fn cancel_ownership_transfer(ctx: Context<CancelOwnershipTransfer>) -> Result<()> {
        instructions::admin::handle_cancel_ownership_transfer(ctx)
    }

    // ── Configuration ──────────────────────────────────────────────────

    pub fn set_paused(ctx: Context<SetPaused>, paused: bool) -> Result<()> {
        instructions::config::handle_set_paused(ctx, paused)
    }

    pub fn set_spending_limit(ctx: Context<SetSpendingLimit>, max_amount: u64) -> Result<()> {
        instructions::config::handle_set_spending_limit(ctx, max_amount)
    }

    pub fn rotate_backend_signer(
        ctx: Context<RotateBackendSigner>,
        new_signer: Pubkey,
    ) -> Result<()> {
        instructions::config::handle_rotate_backend_signer(ctx, new_signer)
    }

    pub fn set_point_deposits_paused(
        ctx: Context<SetPointDepositsPaused>,
        paused: bool,
    ) -> Result<()> {
        instructions::config::handle_set_point_deposits_paused(ctx, paused)
    }

    /// Allowlists a token for every value-in entrypoint. Pass `Pubkey::default()`
    /// to allowlist native SOL.
    pub fn add_allowed_payment_token(
        ctx: Context<AddAllowedPaymentToken>,
        token_mint: Pubkey,
    ) -> Result<()> {
        instructions::config::handle_add_allowed_payment_token(ctx, token_mint)
    }

    pub fn remove_allowed_payment_token(
        ctx: Context<RemoveAllowedPaymentToken>,
        token_mint: Pubkey,
    ) -> Result<()> {
        instructions::config::handle_remove_allowed_payment_token(ctx, token_mint)
    }

    // ── Transactions ───────────────────────────────────────────────────

    pub fn create_transaction_sol(
        ctx: Context<CreateTransactionSol>,
        params: CreateTransactionParams,
    ) -> Result<()> {
        instructions::transaction::handle_create_transaction_sol(ctx, params)
    }

    pub fn create_transaction_token(
        ctx: Context<CreateTransactionToken>,
        params: CreateTransactionParams,
    ) -> Result<()> {
        instructions::transaction::handle_create_transaction_token(ctx, params)
    }

    // ── Merchant Payments ──────────────────────────────────────────────

    pub fn process_merchant_payment_sol(
        ctx: Context<ProcessMerchantPaymentSol>,
        params: MerchantQuoteParams,
    ) -> Result<()> {
        instructions::merchant::handle_process_merchant_payment_sol(ctx, params)
    }

    pub fn process_merchant_payment_token(
        ctx: Context<ProcessMerchantPaymentToken>,
        params: MerchantQuoteParams,
    ) -> Result<()> {
        instructions::merchant::handle_process_merchant_payment_token(ctx, params)
    }

    // ── Withdrawals ────────────────────────────────────────────────────

    pub fn withdraw_sol(ctx: Context<WithdrawSol>, amount: u64) -> Result<()> {
        instructions::withdraw::handle_withdraw_sol(ctx, amount)
    }

    pub fn withdraw_token(ctx: Context<WithdrawToken>, amount: u64) -> Result<()> {
        instructions::withdraw::handle_withdraw_token(ctx, amount)
    }

    // ── Sweep rate limit ───────────────────────────────────────────────
    // Sweeps bypass the withdrawal timelock by design (merchant float has to
    // settle daily), so a per-token rolling cap bounds what a leaked owner key
    // can drain per window. Pass Pubkey::default() for native SOL.

    pub fn set_sweep_cap(ctx: Context<SetSweepCap>, token_mint: Pubkey, cap: u64) -> Result<()> {
        instructions::sweep_cap::handle_set_sweep_cap(ctx, token_mint, cap)
    }

    pub fn queue_sweep_cap(
        ctx: Context<QueueSweepCap>,
        token_mint: Pubkey,
        cap: u64,
    ) -> Result<()> {
        instructions::sweep_cap::handle_queue_sweep_cap(ctx, token_mint, cap)
    }

    pub fn apply_sweep_cap(
        ctx: Context<ModifyPendingSweepCap>,
        token_mint: Pubkey,
    ) -> Result<()> {
        instructions::sweep_cap::handle_apply_sweep_cap(ctx, token_mint)
    }

    pub fn cancel_sweep_cap(
        ctx: Context<ModifyPendingSweepCap>,
        token_mint: Pubkey,
    ) -> Result<()> {
        instructions::sweep_cap::handle_cancel_sweep_cap(ctx, token_mint)
    }

    pub fn queue_withdrawal_delay(ctx: Context<SetWithdrawalDelay>, delay: i64) -> Result<()> {
        instructions::withdraw::handle_queue_withdrawal_delay(ctx, delay)
    }

    pub fn apply_withdrawal_delay(ctx: Context<SetWithdrawalDelay>) -> Result<()> {
        instructions::withdraw::handle_apply_withdrawal_delay(ctx)
    }

    pub fn cancel_withdrawal_delay(ctx: Context<SetWithdrawalDelay>) -> Result<()> {
        instructions::withdraw::handle_cancel_withdrawal_delay(ctx)
    }

    pub fn set_withdrawal_delay(ctx: Context<SetWithdrawalDelay>, delay: i64) -> Result<()> {
        instructions::withdraw::handle_set_withdrawal_delay(ctx, delay)
    }

    pub fn queue_withdrawal(
        ctx: Context<QueueWithdrawal>,
        token_mint: Pubkey,
        recipient: Pubkey,
        amount: u64,
        is_native: bool,
    ) -> Result<()> {
        instructions::withdraw::handle_queue_withdrawal(ctx, token_mint, recipient, amount, is_native)
    }

    pub fn execute_withdrawal_sol(ctx: Context<ExecuteWithdrawalSol>) -> Result<()> {
        instructions::withdraw::handle_execute_withdrawal_sol(ctx)
    }

    pub fn execute_withdrawal_token(ctx: Context<ExecuteWithdrawalToken>) -> Result<()> {
        instructions::withdraw::handle_execute_withdrawal_token(ctx)
    }

    pub fn cancel_withdrawal(ctx: Context<CancelWithdrawal>) -> Result<()> {
        instructions::withdraw::handle_cancel_withdrawal(ctx)
    }

    // ── Point Deposits ─────────────────────────────────────────────────

    pub fn deposit_points(
        ctx: Context<DepositPoints>,
        ref_id: String,
        ref_id_hash: [u8; 32],
        amount: u64,
    ) -> Result<()> {
        instructions::point::handle_deposit_points(ctx, ref_id, ref_id_hash, amount)
    }

    // ── Treasury ───────────────────────────────────────────────────────

    pub fn sweep_platform_fees_sol(
        ctx: Context<SweepPlatformFeesSol>,
        amount: u64,
    ) -> Result<()> {
        instructions::treasury::handle_sweep_platform_fees_sol(ctx, amount)
    }

    pub fn sweep_platform_fees_token(
        ctx: Context<SweepPlatformFeesToken>,
        amount: u64,
    ) -> Result<()> {
        instructions::treasury::handle_sweep_platform_fees_token(ctx, amount)
    }

    pub fn sweep_merchant_backing_sol(
        ctx: Context<SweepMerchantBackingSol>,
        amount: u64,
    ) -> Result<()> {
        instructions::treasury::handle_sweep_merchant_backing_sol(ctx, amount)
    }

    pub fn sweep_merchant_backing_token(
        ctx: Context<SweepMerchantBackingToken>,
        amount: u64,
    ) -> Result<()> {
        instructions::treasury::handle_sweep_merchant_backing_token(ctx, amount)
    }
}
