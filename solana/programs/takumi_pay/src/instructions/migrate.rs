use anchor_lang::prelude::*;
use anchor_lang::system_program::{self, Transfer};
use anchor_lang::Discriminator;

use crate::errors::TakumiPayError;
use crate::state::*;

// ── Account migrations ─────────────────────────────────────────────────────
// The 2.3.0-parity release appended `Config::withdrawal_delay_raised_at` and
// `SweepCap::exit_log`. Accounts created before it are too short to load as the
// new types, so every instruction that takes them fails until they are grown.
// After upgrading the program, call `migrate_config` once, then
// `migrate_sweep_cap` for each mint that has a sweep cap. The new bytes are
// zero, which both new fields read as "nothing yet", so no other state changes.

/// Grows `info` to `new_len`, charging the extra rent to `payer` rather than to
/// the account's own balance: the config PDA's balance is the SOL float.
fn grow<'info>(
    info: &AccountInfo<'info>,
    payer: &Signer<'info>,
    system_program: &Program<'info, System>,
    new_len: usize,
) -> Result<()> {
    let old_len = info.data_len();
    require!(old_len < new_len, TakumiPayError::AlreadyMigrated);

    let rent = Rent::get()?;
    let extra = rent
        .minimum_balance(new_len)
        .saturating_sub(rent.minimum_balance(old_len));
    if extra > 0 {
        system_program::transfer(
            CpiContext::new(
                system_program.to_account_info(),
                Transfer {
                    from: payer.to_account_info(),
                    to: info.clone(),
                },
            ),
            extra,
        )?;
    }
    // Zero-fills the new bytes.
    info.resize(new_len)?;
    Ok(())
}

/// Checks that the program owns `info` and that it starts with `discriminator`.
fn require_layout(info: &AccountInfo, discriminator: &[u8]) -> Result<()> {
    require_keys_eq!(
        *info.owner,
        crate::ID,
        anchor_lang::error::ErrorCode::AccountOwnedByWrongProgram
    );
    let data = info.try_borrow_data()?;
    require!(
        data.len() >= 8 && &data[..8] == discriminator,
        anchor_lang::error::ErrorCode::AccountDiscriminatorMismatch
    );
    Ok(())
}

// ── Migrate Config ─────────────────────────────────────────────────────────

#[derive(Accounts)]
pub struct MigrateConfig<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,

    /// CHECK: loaded by hand, because a config created before this release is
    /// too short to deserialize as `Config`. The address is pinned by `seeds`;
    /// the handler checks the program owns it, its discriminator and its owner.
    #[account(mut, seeds = [CONFIG_SEED], bump)]
    pub config: UncheckedAccount<'info>,

    pub system_program: Program<'info, System>,
}

pub fn handle_migrate_config(ctx: Context<MigrateConfig>) -> Result<()> {
    let info = ctx.accounts.config.to_account_info();
    require_layout(&info, Config::DISCRIMINATOR)?;
    {
        // `owner` is the first field in every layout, right after the
        // discriminator, so it can be read before the account is grown.
        let data = info.try_borrow_data()?;
        require!(data.len() >= 40, TakumiPayError::NotOwner);
        let owner = Pubkey::new_from_array(data[8..40].try_into().unwrap());
        require_keys_eq!(owner, ctx.accounts.owner.key(), TakumiPayError::NotOwner);
    }
    grow(
        &info,
        &ctx.accounts.owner,
        &ctx.accounts.system_program,
        8 + Config::INIT_SPACE,
    )
}

// ── Migrate Sweep Cap ──────────────────────────────────────────────────────

#[derive(Accounts)]
#[instruction(token_mint: Pubkey)]
pub struct MigrateSweepCap<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,

    /// Already migrated: `migrate_config` runs first.
    #[account(
        has_one = owner @ TakumiPayError::NotOwner,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    /// CHECK: loaded by hand for the same reason as `MigrateConfig::config`. The
    /// address is pinned by `seeds`; the handler checks owner and discriminator.
    #[account(
        mut,
        seeds = [SWEEP_CAP_SEED, config.key().as_ref(), token_mint.as_ref()],
        bump,
    )]
    pub sweep_cap: UncheckedAccount<'info>,

    pub system_program: Program<'info, System>,
}

pub fn handle_migrate_sweep_cap(ctx: Context<MigrateSweepCap>, _token_mint: Pubkey) -> Result<()> {
    let info = ctx.accounts.sweep_cap.to_account_info();
    require_layout(&info, SweepCap::DISCRIMINATOR)?;
    grow(
        &info,
        &ctx.accounts.owner,
        &ctx.accounts.system_program,
        8 + SweepCap::INIT_SPACE,
    )
}
