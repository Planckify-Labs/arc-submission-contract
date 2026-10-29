use anchor_lang::prelude::*;

use crate::errors::TakumiPayError;

// ── PDA Seeds ──────────────────────────────────────────────────────────────

pub const CONFIG_SEED: &[u8] = b"config";
pub const ADMIN_SEED: &[u8] = b"admin";
pub const SPENDING_LIMIT_SEED: &[u8] = b"spending_limit";
pub const TX_RECORD_SEED: &[u8] = b"tx";
pub const REF_RECORD_SEED: &[u8] = b"ref";
pub const MERCHANT_PAYMENT_SEED: &[u8] = b"merchant_payment";
pub const PLATFORM_FEE_SEED: &[u8] = b"platform_fee";
pub const POINT_DEPOSIT_SEED: &[u8] = b"point_deposit";
pub const POINT_REF_SEED: &[u8] = b"point_ref";
/// Marker PDA gating every entrypoint that moves value in: create_transaction_*,
/// process_merchant_payment_* and deposit_points. Native SOL is keyed by
/// `Pubkey::default()` — the same sentinel the `_sol` instructions already use
/// for `token_mint` — so native is allowlisted explicitly rather than bypassing.
pub const ALLOWED_PAYMENT_TOKEN_SEED: &[u8] = b"allowed_payment_token";
pub const WITHDRAWAL_SEED: &[u8] = b"withdrawal";
pub const SWEEP_CAP_SEED: &[u8] = b"sweep_cap";

// ── Constants ──────────────────────────────────────────────────────────────

pub const MAX_STRING_LEN: usize = 64;
pub const MAX_WITHDRAWAL_DELAY: i64 = 7 * 24 * 60 * 60; // 7 days

/// Span the treasury sweep cap holds over (24h).
///
/// Sweeps deliberately bypass the withdrawal timelock — merchant float has to
/// settle daily and a 7-day queue would break that. The cap gives back what the
/// timelock was there for: a leaked owner key can move at most `cap` in any 24
/// hours, visibly, instead of emptying the vault in one transaction.
pub const SWEEP_WINDOW: i64 = 24 * 60 * 60;

/// Most capped exits one token can make within SWEEP_WINDOW.
pub const SWEEP_LOG_SIZE: usize = 16;

/// Sentinel meaning "no cap". Must be set explicitly — it is not the default.
pub const SWEEP_CAP_UNLIMITED: u64 = u64::MAX;

// ── Accounts ───────────────────────────────────────────────────────────────

#[account]
#[derive(InitSpace)]
pub struct Config {
    pub owner: Pubkey,
    pub pending_owner: Option<Pubkey>,
    pub backend_signer: Pubkey,
    pub paused: bool,
    pub point_deposits_paused: bool,
    pub tx_counter: u64,
    pub point_deposit_counter: u64,
    pub withdrawal_delay: i64,
    pub withdrawal_nonce: u64,
    /// Queued reduction of `withdrawal_delay`. Lowering the delay weakens the
    /// timelock, so it is subject to the delay currently in force — otherwise a
    /// leaked owner key would just set it to 0 and withdraw in one transaction.
    /// `pending_delay_unlock_time == 0` means nothing is queued.
    pub pending_withdrawal_delay: i64,
    pub pending_delay_unlock_time: i64,
    pub bump: u8,
    /// When `set_withdrawal_delay` last ran. Queued loosenings and withdrawals also
    /// wait the full current delay from then, so raising the delay reaches entries
    /// queued under a shorter one. Appended in the 2.3.0-parity release: a config
    /// created earlier must be grown by `migrate_config` first, after which this
    /// reads 0 and changes nothing until the delay is next set.
    pub withdrawal_delay_raised_at: i64,
}

impl Config {
    /// The earliest time any queued entry may land, whatever its own unlock time:
    /// the full current delay after the delay was last set. An entry queued after
    /// that always unlocks later anyway, so this only binds entries queued under
    /// an earlier, shorter delay.
    pub fn rearmed_at(&self) -> i64 {
        self.withdrawal_delay_raised_at
            .saturating_add(self.withdrawal_delay)
    }
}

#[account]
#[derive(InitSpace)]
pub struct Admin {
    pub config: Pubkey,
    pub admin: Pubkey,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct SpendingLimit {
    pub config: Pubkey,
    pub token_mint: Pubkey,
    pub max_amount: u64,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct TransactionRecord {
    pub config: Pubkey,
    pub tx_id: u64,
    pub wallet_address: Pubkey,
    pub token_mint: Pubkey,
    #[max_len(MAX_STRING_LEN)]
    pub booking_id: String,
    pub exchange_rate_id: u64,
    #[max_len(MAX_STRING_LEN)]
    pub product_variant_id: String,
    #[max_len(MAX_STRING_LEN)]
    pub ref_id: String,
    pub amount: u64,
    pub timestamp: i64,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct RefRecord {
    pub config: Pubkey,
    pub record_id: u64,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct MerchantPayment {
    pub config: Pubkey,
    pub payer: Pubkey,
    pub token_mint: Pubkey,
    #[max_len(MAX_STRING_LEN)]
    pub merchant_id: String,
    #[max_len(MAX_STRING_LEN)]
    pub ref_id: String,
    pub amount: u64,
    pub platform_fee_amount: u64,
    pub fiat_amount_minor: u64,
    pub fiat_currency: [u8; 3],
    pub exchange_rate_id: u64,
    pub timestamp: i64,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct PlatformFeeAccount {
    pub config: Pubkey,
    pub token_mint: Pubkey,
    pub accrued_amount: u64,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct PointDepositRecord {
    pub config: Pubkey,
    pub deposit_id: u64,
    pub wallet_address: Pubkey,
    pub token_mint: Pubkey,
    pub amount: u64,
    #[max_len(MAX_STRING_LEN)]
    pub ref_id: String,
    pub timestamp: i64,
    pub bump: u8,
}

/// Per-token treasury sweep rate limit, plus the queued increase for it.
///
/// `cap == 0` (the default, and the state of a token that was never configured)
/// blocks every exit entirely. Unlike `SpendingLimit`, where 0 means "unbounded",
/// this is a security control, so an unconfigured value must fail closed.
#[account]
#[derive(InitSpace)]
pub struct SweepCap {
    pub config: Pubkey,
    pub token_mint: Pubkey,
    pub cap: u64,
    /// The fixed-window state from before the exit log. No longer written. An
    /// account migrated from that layout keeps its last window's total here, and
    /// `usage` still counts it until none of its exits can be inside the trailing
    /// 24 hours.
    pub swept_in_window: u64,
    pub window_start: i64,
    /// Queued increase. Raising a cap weakens a control, so it is subject to the
    /// withdrawal delay currently in force. 0 unlock_time == nothing pending.
    pub pending_cap: u64,
    pub pending_unlock_time: i64,
    pub bump: u8,
    /// Recent capped exits, each packed as (timestamp << 64 | amount); 0 is an
    /// empty slot. Order means nothing: an entry SWEEP_WINDOW old or more has
    /// expired and its slot is reused. Appended in the 2.3.0-parity release: an
    /// account created earlier must be grown by `migrate_sweep_cap` first.
    pub exit_log: [u128; SWEEP_LOG_SIZE],
}

impl SweepCap {
    /// What left through capped exits in the trailing SWEEP_WINDOW as of `now`, and
    /// a log slot free for the next exit (None when every slot is live).
    pub fn usage(&self, now: i64) -> (u64, Option<usize>) {
        let mut used: u64 = 0;
        let mut free = None;
        for (i, entry) in self.exit_log.iter().enumerate() {
            let at = (*entry >> 64) as i64;
            if *entry != 0 && at.saturating_add(SWEEP_WINDOW) > now {
                used = used.saturating_add(*entry as u64);
            } else {
                free = Some(i);
            }
        }
        // The old fixed window's exits all happened before window_start +
        // SWEEP_WINDOW, so they can be inside the trailing window only until twice
        // that. Counting the whole total until then is safe.
        if now < self.window_start.saturating_add(2 * SWEEP_WINDOW) {
            used = used.saturating_add(self.swept_in_window);
        }
        (used, free)
    }

    /// Charges `amount` at `now`. The cap holds over every 24 hours, not per fixed
    /// window: an exit passes only if it plus every capped exit in the trailing
    /// SWEEP_WINDOW stays within `cap`, so no span of SWEEP_WINDOW ever sees more
    /// than `cap` leave, and each exit's share comes back exactly SWEEP_WINDOW
    /// after it was made. A live entry is never overwritten: with every slot live,
    /// the exit fails with SweepLogFull until the oldest expires.
    pub fn charge(&mut self, now: i64, amount: u64) -> Result<()> {
        require!(self.cap > 0, TakumiPayError::SweepCapNotSet);
        if self.cap == SWEEP_CAP_UNLIMITED {
            return Ok(());
        }

        let (used, free) = self.usage(now);
        let total = used.checked_add(amount).ok_or(TakumiPayError::Overflow)?;
        require!(total <= self.cap, TakumiPayError::SweepCapExceeded);
        let slot = free.ok_or(TakumiPayError::SweepLogFull)?;
        self.exit_log[slot] = ((now as u64 as u128) << 64) | amount as u128;
        Ok(())
    }

    /// How much the cap lets leave at `now`. Off-chain readers of the account get
    /// the same figure by applying `usage` to the decoded fields.
    pub fn allowance(&self, now: i64) -> u64 {
        if self.cap == SWEEP_CAP_UNLIMITED {
            return self.cap;
        }
        let (used, free) = self.usage(now);
        if free.is_none() || used >= self.cap {
            0
        } else {
            self.cap - used
        }
    }
}

#[account]
#[derive(InitSpace)]
pub struct AllowedPaymentToken {
    pub config: Pubkey,
    pub token_mint: Pubkey,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct WithdrawalRequest {
    pub config: Pubkey,
    pub token_mint: Pubkey,
    pub recipient: Pubkey,
    pub amount: u64,
    pub unlock_time: i64,
    pub executed: bool,
    pub cancelled: bool,
    pub nonce: u64,
    pub is_native: bool,
    pub bump: u8,
}

// ── Instruction Params ─────────────────────────────────────────────────────

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct CreateTransactionParams {
    pub booking_id: String,
    pub exchange_rate_id: u64,
    pub product_variant_id: String,
    pub ref_id: String,
    pub ref_id_hash: [u8; 32],
    pub amount: u64,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct MerchantQuoteParams {
    pub ref_id: String,
    pub ref_id_hash: [u8; 32],
    pub merchant_id: String,
    pub amount: u64,
    pub platform_fee_amount: u64,
    pub fiat_amount_minor: u64,
    pub fiat_currency: [u8; 3],
    pub exchange_rate_id: u64,
    pub expires_at: i64,
}

// ── Events ─────────────────────────────────────────────────────────────────

#[event]
pub struct TransactionCreated {
    pub tx_id: u64,
    pub wallet_address: Pubkey,
    pub token_mint: Pubkey,
    pub booking_id: String,
    pub exchange_rate_id: u64,
    pub product_variant_id: String,
    pub ref_id: String,
    pub amount: u64,
    pub timestamp: i64,
}

#[event]
pub struct MerchantPaymentProcessed {
    pub ref_id: String,
    pub merchant_id: String,
    pub payer: Pubkey,
    pub token_mint: Pubkey,
    pub amount: u64,
    pub platform_fee_amount: u64,
    pub fiat_amount_minor: u64,
    pub exchange_rate_id: u64,
}

#[event]
pub struct PlatformFeesSwept {
    pub token_mint: Pubkey,
    pub recipient: Pubkey,
    pub amount: u64,
}

#[event]
pub struct MerchantBackingSwept {
    pub token_mint: Pubkey,
    pub recipient: Pubkey,
    pub amount: u64,
}

#[event]
pub struct BackendSignerRotated {
    pub previous: Pubkey,
    pub next: Pubkey,
}

#[event]
pub struct AdminAdded {
    pub admin: Pubkey,
}

#[event]
pub struct AdminRemoved {
    pub admin: Pubkey,
}

#[event]
pub struct WithdrawEvent {
    pub recipient: Pubkey,
    pub token_mint: Pubkey,
    pub amount: u64,
}

#[event]
pub struct ContractPausedToggled {
    pub paused: bool,
}

#[event]
pub struct MaxTransactionAmountUpdated {
    pub token_mint: Pubkey,
    pub amount: u64,
}

#[event]
pub struct WithdrawalQueued {
    pub withdrawal_id: Pubkey,
    pub token_mint: Pubkey,
    pub recipient: Pubkey,
    pub amount: u64,
    pub unlock_time: i64,
}

#[event]
pub struct WithdrawalExecuted {
    pub withdrawal_id: Pubkey,
}

#[event]
pub struct WithdrawalCancelled {
    pub withdrawal_id: Pubkey,
}

#[event]
pub struct WithdrawalDelayUpdated {
    pub delay: i64,
}

#[event]
pub struct OwnershipTransferInitiated {
    pub current_owner: Pubkey,
    pub pending_owner: Pubkey,
}

#[event]
pub struct OwnershipTransferred {
    pub previous_owner: Pubkey,
    pub new_owner: Pubkey,
}

#[event]
pub struct OwnershipTransferCancelled {
    pub cancelled_pending_owner: Pubkey,
}

#[event]
pub struct PointDepositCreated {
    pub deposit_id: u64,
    pub wallet_address: Pubkey,
    pub token_mint: Pubkey,
    pub ref_id: String,
    pub amount: u64,
    pub timestamp: i64,
}

#[event]
pub struct AllowedPaymentTokenAdded {
    pub token_mint: Pubkey,
}

#[event]
pub struct AllowedPaymentTokenRemoved {
    pub token_mint: Pubkey,
}

#[event]
pub struct SweepCapUpdated {
    pub token_mint: Pubkey,
    pub cap: u64,
}

#[event]
pub struct PendingSweepCapQueued {
    pub token_mint: Pubkey,
    pub cap: u64,
    pub unlock_time: i64,
}

#[event]
pub struct PendingSweepCapCancelled {
    pub token_mint: Pubkey,
}

#[event]
pub struct PendingDelayQueued {
    pub delay: i64,
    pub unlock_time: i64,
}

#[event]
pub struct PendingDelayCancelled {
    pub delay: i64,
}

#[event]
pub struct PointDepositsPausedToggled {
    pub paused: bool,
}

// ── Helpers ────────────────────────────────────────────────────────────────

pub fn validate_string(s: &str) -> bool {
    !s.is_empty() && s.len() <= MAX_STRING_LEN
}

pub fn verify_ref_id_hash(ref_id: &str, expected_hash: &[u8; 32]) -> bool {
    use sha2::{Sha256, Digest};
    let result = Sha256::digest(ref_id.as_bytes());
    result.as_slice() == expected_hash
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A live chain's clock.
    const T0: i64 = 1_790_000_000;
    const DAY: i64 = SWEEP_WINDOW;

    fn cap_of(cap: u64) -> SweepCap {
        SweepCap {
            config: Pubkey::default(),
            token_mint: Pubkey::default(),
            cap,
            swept_in_window: 0,
            window_start: 0,
            pending_cap: 0,
            pending_unlock_time: 0,
            bump: 0,
            exit_log: [0; SWEEP_LOG_SIZE],
        }
    }

    fn err(code: TakumiPayError) -> Error {
        code.into()
    }

    /// 5.2.2: s at W, cap - s at W + 1 day - 1s, then a full cap at W + 1 day.
    /// The third exit fails, because the trailing 24 hours still hold cap - s.
    #[test]
    fn no_boundary_burst() {
        let mut sc = cap_of(100);
        sc.charge(T0, 10).unwrap();
        sc.charge(T0 + DAY - 1, 90).unwrap();
        assert_eq!(sc.allowance(T0 + DAY), 10);
        assert_eq!(sc.charge(T0 + DAY, 100).unwrap_err(), err(TakumiPayError::SweepCapExceeded));
        sc.charge(T0 + DAY, 10).unwrap();
    }

    #[test]
    fn each_exit_frees_its_share_exactly_a_day_later() {
        let mut sc = cap_of(240);
        sc.charge(T0, 100).unwrap();
        sc.charge(T0 + 6 * 3600, 140).unwrap();
        assert_eq!(sc.allowance(T0 + DAY - 1), 0);
        assert_eq!(sc.allowance(T0 + DAY), 100);
        assert_eq!(sc.allowance(T0 + DAY + 6 * 3600), 240);
    }

    #[test]
    fn log_holds_sixteen_exits_per_day() {
        let mut sc = cap_of(1_000);
        for i in 0..SWEEP_LOG_SIZE as i64 {
            sc.charge(T0 + i * 3600, 1).unwrap();
        }
        assert_eq!(sc.allowance(T0 + 15 * 3600), 0, "a full log reports nothing left");
        assert_eq!(sc.charge(T0 + 15 * 3600, 1).unwrap_err(), err(TakumiPayError::SweepLogFull));
        // The first entry expires at T0 + DAY; its slot is reused.
        assert_eq!(sc.allowance(T0 + DAY), 1_000 - 15);
        sc.charge(T0 + DAY, 1).unwrap();
    }

    #[test]
    fn unset_cap_fails_closed_and_unlimited_skips_the_log() {
        let mut unset = cap_of(0);
        assert_eq!(unset.charge(T0, 1).unwrap_err(), err(TakumiPayError::SweepCapNotSet));

        let mut unlimited = cap_of(SWEEP_CAP_UNLIMITED);
        for _ in 0..100 {
            unlimited.charge(T0, u64::MAX / 2).unwrap();
        }
        assert_eq!(unlimited.exit_log, [0; SWEEP_LOG_SIZE]);
        assert_eq!(unlimited.allowance(T0), SWEEP_CAP_UNLIMITED);
    }

    #[test]
    fn overflowing_amount_is_refused() {
        let mut sc = cap_of(u64::MAX - 1);
        sc.charge(T0, 10).unwrap();
        assert_eq!(sc.charge(T0, u64::MAX).unwrap_err(), err(TakumiPayError::Overflow));
    }

    /// An account migrated from the fixed-window layout keeps that window's total
    /// counted until none of its exits can be inside the trailing 24 hours.
    #[test]
    fn legacy_window_total_counts_for_two_days() {
        let mut sc = cap_of(50);
        sc.window_start = T0;
        sc.swept_in_window = 30;
        assert_eq!(sc.allowance(T0 + 6 * 3600), 20);
        assert_eq!(sc.charge(T0 + 6 * 3600, 21).unwrap_err(), err(TakumiPayError::SweepCapExceeded));
        sc.charge(T0 + 6 * 3600, 20).unwrap();
        // The 20 expired at T0 + 30h; the legacy 30 still counts until T0 + 2 days.
        assert_eq!(sc.allowance(T0 + 2 * DAY - 1), 20);
        assert_eq!(sc.allowance(T0 + 2 * DAY), 50);
    }

    /// The invariant: for pseudo-random exits at pseudo-random times, no two
    /// accepted exits less than a day apart, with everything between them, ever
    /// add up to more than the cap.
    #[test]
    fn no_day_ever_sees_more_than_the_cap() {
        let cap: u64 = 1_000;
        for seed in 0..300u64 {
            let mut sc = cap_of(cap);
            let mut state = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            let mut next = || {
                state = state
                    .wrapping_mul(6364136223846793005)
                    .wrapping_add(1442695040888963407);
                state >> 33
            };
            let mut now = T0;
            let mut accepted: std::vec::Vec<(i64, u64)> = std::vec::Vec::new();
            for _ in 0..48 {
                now += (next() % (8 * 3600)) as i64;
                let amount = 1 + next() % cap;
                if sc.charge(now, amount).is_ok() {
                    accepted.push((now, amount));
                }
            }
            for i in 0..accepted.len() {
                let mut sum = 0;
                for (at, amount) in &accepted[i..] {
                    if *at >= accepted[i].0 + DAY {
                        break;
                    }
                    sum += amount;
                    assert!(sum <= cap, "seed {seed}: {sum} left within a day");
                }
            }
        }
    }

    #[test]
    fn rearmed_at_is_raise_plus_current_delay() {
        let mut config = Config {
            owner: Pubkey::default(),
            pending_owner: None,
            backend_signer: Pubkey::default(),
            paused: false,
            point_deposits_paused: false,
            tx_counter: 0,
            point_deposit_counter: 0,
            withdrawal_delay: 3600,
            withdrawal_nonce: 0,
            pending_withdrawal_delay: 0,
            pending_delay_unlock_time: 0,
            bump: 0,
            withdrawal_delay_raised_at: 0,
        };
        assert_eq!(config.rearmed_at(), 3600, "never raised: no extra wait on a real clock");
        config.withdrawal_delay_raised_at = T0;
        config.withdrawal_delay = 7 * DAY;
        assert_eq!(config.rearmed_at(), T0 + 7 * DAY);
    }
}
