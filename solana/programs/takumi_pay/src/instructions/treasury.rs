use anchor_lang::prelude::*;
use anchor_spl::token_interface::{self, Mint, TokenInterface, TokenAccount, TransferChecked};

use crate::errors::TakumiPayError;
use crate::instructions::sweep_cap::consume_sweep_allowance;
use crate::state::*;

// ── Fee ledger ─────────────────────────────────────────────────────────────

/// The platform fee accrued in one mint, read from its PlatformFeeAccount PDA.
/// That PDA exists only once a merchant payment has accrued a fee in the mint;
/// until then the ledger is 0. Exits take it as an unchecked account whose
/// address is pinned by `seeds`, so they work for any mint.
pub(crate) fn accrued_fees(pfa: &AccountInfo) -> Result<u64> {
    if pfa.owner != &crate::ID || pfa.data_is_empty() {
        return Ok(0);
    }
    let data = pfa.try_borrow_data()?;
    Ok(PlatformFeeAccount::try_deserialize(&mut &data[..])?.accrued_amount)
}

/// After a whole-treasury exit: when the balance `left` is below the accrued
/// fees, the fees the exit took left with it, so they are booked as swept to the
/// same recipient. The ledger then never claims fees the vault no longer holds,
/// and a later fee sweep cannot take merchant float.
pub(crate) fn settle_fee_ledger(
    pfa: &AccountInfo,
    left: u64,
    token_mint: Pubkey,
    recipient: Pubkey,
) -> Result<()> {
    if pfa.owner != &crate::ID || pfa.data_is_empty() {
        return Ok(());
    }
    let mut account = {
        let data = pfa.try_borrow_data()?;
        PlatformFeeAccount::try_deserialize(&mut &data[..])?
    };
    if left >= account.accrued_amount {
        return Ok(());
    }
    let taken = account.accrued_amount - left;
    account.accrued_amount = left;
    let mut data = pfa.try_borrow_mut_data()?;
    let mut writer: &mut [u8] = &mut data[..];
    account.try_serialize(&mut writer)?;

    emit!(PlatformFeesSwept {
        token_mint,
        recipient,
        amount: taken,
    });
    Ok(())
}

/// Lamports the config PDA holds above its rent-exempt minimum: the SOL float.
pub(crate) fn sol_float(config: &AccountInfo) -> Result<u64> {
    let min_balance = Rent::get()?.minimum_balance(config.data_len());
    Ok(config.lamports().saturating_sub(min_balance))
}

// ── Sweep Platform Fees SOL ────────────────────────────────────────────────

#[derive(Accounts)]
pub struct SweepPlatformFeesSol<'info> {
    pub owner: Signer<'info>,

    #[account(
        mut,
        has_one = owner @ TakumiPayError::NotOwner,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    #[account(
        mut,
        seeds = [SWEEP_CAP_SEED, config.key().as_ref(), Pubkey::default().as_ref()],
        bump = sweep_cap.bump,
        has_one = config,
    )]
    pub sweep_cap: Account<'info, SweepCap>,

    #[account(
        mut,
        seeds = [PLATFORM_FEE_SEED, config.key().as_ref(), Pubkey::default().as_ref()],
        bump = platform_fee_account.bump,
        has_one = config,
    )]
    pub platform_fee_account: Account<'info, PlatformFeeAccount>,

    /// CHECK: Recipient for SOL fees. Validated as non-default in handler.
    #[account(mut)]
    pub recipient: AccountInfo<'info>,

    pub system_program: Program<'info, System>,
}

pub fn handle_sweep_platform_fees_sol(
    ctx: Context<SweepPlatformFeesSol>,
    amount: u64,
) -> Result<()> {
    require!(amount > 0, TakumiPayError::ZeroAmount);
    consume_sweep_allowance(&mut ctx.accounts.sweep_cap, amount)?;
    require!(
        ctx.accounts.recipient.key() != Pubkey::default(),
        TakumiPayError::ZeroRecipient
    );

    let pfa = &mut ctx.accounts.platform_fee_account;
    require!(
        amount <= pfa.accrued_amount,
        TakumiPayError::FeeAmountInvalid
    );
    pfa.accrued_amount -= amount;

    let rent = Rent::get()?;
    let min_balance = rent.minimum_balance(ctx.accounts.config.to_account_info().data_len());
    let available = ctx
        .accounts
        .config
        .to_account_info()
        .lamports()
        .checked_sub(min_balance)
        .ok_or(TakumiPayError::InsufficientBalance)?;
    require!(amount <= available, TakumiPayError::InsufficientBalance);

    **ctx
        .accounts
        .config
        .to_account_info()
        .try_borrow_mut_lamports()? -= amount;
    **ctx.accounts.recipient.try_borrow_mut_lamports()? += amount;

    emit!(PlatformFeesSwept {
        token_mint: Pubkey::default(),
        recipient: ctx.accounts.recipient.key(),
        amount,
    });

    Ok(())
}

// ── Sweep Platform Fees Token ──────────────────────────────────────────────

#[derive(Accounts)]
pub struct SweepPlatformFeesToken<'info> {
    pub owner: Signer<'info>,

    #[account(
        has_one = owner @ TakumiPayError::NotOwner,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    #[account(
        mut,
        seeds = [SWEEP_CAP_SEED, config.key().as_ref(), token_mint.key().as_ref()],
        bump = sweep_cap.bump,
        has_one = config,
    )]
    pub sweep_cap: Account<'info, SweepCap>,

    pub token_mint: InterfaceAccount<'info, Mint>,

    #[account(
        mut,
        seeds = [PLATFORM_FEE_SEED, config.key().as_ref(), token_mint.key().as_ref()],
        bump = platform_fee_account.bump,
        has_one = config,
    )]
    pub platform_fee_account: Account<'info, PlatformFeeAccount>,

    #[account(
        mut,
        associated_token::mint = token_mint,
        associated_token::authority = config,
    )]
    pub vault_token_account: InterfaceAccount<'info, TokenAccount>,

    #[account(mut)]
    pub recipient_token_account: InterfaceAccount<'info, TokenAccount>,

    pub token_program: Interface<'info, TokenInterface>,
}

pub fn handle_sweep_platform_fees_token(
    ctx: Context<SweepPlatformFeesToken>,
    amount: u64,
) -> Result<()> {
    require!(amount > 0, TakumiPayError::ZeroAmount);
    consume_sweep_allowance(&mut ctx.accounts.sweep_cap, amount)?;

    let pfa = &mut ctx.accounts.platform_fee_account;
    require!(
        amount <= pfa.accrued_amount,
        TakumiPayError::FeeAmountInvalid
    );
    pfa.accrued_amount -= amount;

    let config_bump = ctx.accounts.config.bump;
    let seeds: &[&[u8]] = &[CONFIG_SEED, &[config_bump]];
    let signer_seeds = &[seeds];

    let cpi_accounts = TransferChecked {
        from: ctx.accounts.vault_token_account.to_account_info(),
        to: ctx.accounts.recipient_token_account.to_account_info(),
        authority: ctx.accounts.config.to_account_info(),
        mint: ctx.accounts.token_mint.to_account_info(),
    };
    token_interface::transfer_checked(
        CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            cpi_accounts,
            signer_seeds,
        ),
        amount,
        ctx.accounts.token_mint.decimals,
    )?;

    emit!(PlatformFeesSwept {
        token_mint: ctx.accounts.token_mint.key(),
        recipient: ctx.accounts.recipient_token_account.key(),
        amount,
    });

    Ok(())
}

// ── Sweep Merchant Backing SOL ─────────────────────────────────────────────

#[derive(Accounts)]
pub struct SweepMerchantBackingSol<'info> {
    pub owner: Signer<'info>,

    #[account(
        mut,
        has_one = owner @ TakumiPayError::NotOwner,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    #[account(
        mut,
        seeds = [SWEEP_CAP_SEED, config.key().as_ref(), Pubkey::default().as_ref()],
        bump = sweep_cap.bump,
        has_one = config,
    )]
    pub sweep_cap: Account<'info, SweepCap>,

    /// CHECK: native SOL's PlatformFeeAccount, which may not exist yet. Read by
    /// `accrued_fees`, which checks its owner and discriminator.
    #[account(
        seeds = [PLATFORM_FEE_SEED, config.key().as_ref(), Pubkey::default().as_ref()],
        bump,
    )]
    pub platform_fee_account: UncheckedAccount<'info>,

    /// CHECK: Recipient for SOL. Validated as non-default in handler.
    #[account(mut)]
    pub recipient: AccountInfo<'info>,

    pub system_program: Program<'info, System>,
}

/// Sweeps merchant-backing SOL. Accrued platform fees are not float: they stay
/// behind for `sweep_platform_fees_sol`, so the fee ledger stays backed.
pub fn handle_sweep_merchant_backing_sol(
    ctx: Context<SweepMerchantBackingSol>,
    amount: u64,
) -> Result<()> {
    require!(amount > 0, TakumiPayError::ZeroAmount);
    require!(
        ctx.accounts.recipient.key() != Pubkey::default(),
        TakumiPayError::ZeroRecipient
    );

    let available = sol_float(&ctx.accounts.config.to_account_info())?;
    let fees = accrued_fees(&ctx.accounts.platform_fee_account)?;
    require!(
        fees <= available && amount <= available - fees,
        TakumiPayError::InsufficientBalance
    );
    consume_sweep_allowance(&mut ctx.accounts.sweep_cap, amount)?;

    **ctx
        .accounts
        .config
        .to_account_info()
        .try_borrow_mut_lamports()? -= amount;
    **ctx.accounts.recipient.try_borrow_mut_lamports()? += amount;

    emit!(MerchantBackingSwept {
        token_mint: Pubkey::default(),
        recipient: ctx.accounts.recipient.key(),
        amount,
    });

    Ok(())
}

// ── Sweep Merchant Backing Token ───────────────────────────────────────────

#[derive(Accounts)]
pub struct SweepMerchantBackingToken<'info> {
    pub owner: Signer<'info>,

    #[account(
        has_one = owner @ TakumiPayError::NotOwner,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    #[account(
        mut,
        seeds = [SWEEP_CAP_SEED, config.key().as_ref(), token_mint.key().as_ref()],
        bump = sweep_cap.bump,
        has_one = config,
    )]
    pub sweep_cap: Account<'info, SweepCap>,

    pub token_mint: InterfaceAccount<'info, Mint>,

    #[account(
        mut,
        associated_token::mint = token_mint,
        associated_token::authority = config,
    )]
    pub vault_token_account: InterfaceAccount<'info, TokenAccount>,

    /// CHECK: this mint's PlatformFeeAccount, which may not exist yet. Read by
    /// `accrued_fees`, which checks its owner and discriminator.
    #[account(
        seeds = [PLATFORM_FEE_SEED, config.key().as_ref(), token_mint.key().as_ref()],
        bump,
    )]
    pub platform_fee_account: UncheckedAccount<'info>,

    #[account(mut)]
    pub recipient_token_account: InterfaceAccount<'info, TokenAccount>,

    pub token_program: Interface<'info, TokenInterface>,
}

/// Sweeps merchant-backing tokens. Accrued platform fees are not float: they
/// stay behind for `sweep_platform_fees_token`, so the fee ledger stays backed.
pub fn handle_sweep_merchant_backing_token(
    ctx: Context<SweepMerchantBackingToken>,
    amount: u64,
) -> Result<()> {
    require!(amount > 0, TakumiPayError::ZeroAmount);
    let balance = ctx.accounts.vault_token_account.amount;
    let fees = accrued_fees(&ctx.accounts.platform_fee_account)?;
    require!(
        fees <= balance && amount <= balance - fees,
        TakumiPayError::InsufficientBalance
    );
    consume_sweep_allowance(&mut ctx.accounts.sweep_cap, amount)?;

    let config_bump = ctx.accounts.config.bump;
    let seeds: &[&[u8]] = &[CONFIG_SEED, &[config_bump]];
    let signer_seeds = &[seeds];

    let cpi_accounts = TransferChecked {
        from: ctx.accounts.vault_token_account.to_account_info(),
        to: ctx.accounts.recipient_token_account.to_account_info(),
        authority: ctx.accounts.config.to_account_info(),
        mint: ctx.accounts.token_mint.to_account_info(),
    };
    token_interface::transfer_checked(
        CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            cpi_accounts,
            signer_seeds,
        ),
        amount,
        ctx.accounts.token_mint.decimals,
    )?;

    emit!(MerchantBackingSwept {
        token_mint: ctx.accounts.token_mint.key(),
        recipient: ctx.accounts.recipient_token_account.key(),
        amount,
    });

    Ok(())
}
