use soroban_sdk::{token, Address, Env, Vec};

use crate::admin::{bump_persistent, get_config, require_owner};
use crate::errors::Error;
use crate::events::{
    MerchantBackingSwept, PendingSweepCapCancelled, PendingSweepCapQueued, PlatformFeesSwept,
    SweepCapUpdated,
};
use crate::types::{
    DataKey, PendingCap, SweepExit, SWEEP_CAP_UNLIMITED, SWEEP_LOG_SIZE, SWEEP_WINDOW,
};
use crate::withdraw::require_unlocked;

// ── Sweep rate limit ──────────────────────────────────────────────────────

fn get_cap(env: &Env, token: &Address) -> i128 {
    env.storage()
        .persistent()
        .get(&DataKey::SweepCap(token.clone()))
        .unwrap_or(0)
}

/// The capped exits still inside the trailing SWEEP_WINDOW, and their total.
/// Older entries are dropped, which is how the log stays at most SWEEP_LOG_SIZE.
fn sweep_usage(env: &Env, token: &Address) -> (i128, Vec<SweepExit>) {
    let now = env.ledger().timestamp();
    let log: Vec<SweepExit> = env
        .storage()
        .persistent()
        .get(&DataKey::SweepLog(token.clone()))
        .unwrap_or(Vec::new(env));
    let mut live = Vec::new(env);
    let mut used: i128 = 0;
    for exit in log.iter() {
        if exit.at + SWEEP_WINDOW > now {
            used = used.saturating_add(exit.amount);
            live.push_back(exit);
        }
    }
    (used, live)
}

/// Charges `amount` against the token's sweep cap. An unset cap fails closed:
/// unlike `SpendingLimit`, where absent means "unbounded", this is a security
/// control, so it must deny by default.
///
/// The cap holds over every 24 hours, not per fixed window: an exit passes only
/// if it plus every capped exit in the trailing SWEEP_WINDOW stays within the
/// cap, and each exit is logged with its time. So no span of SWEEP_WINDOW ever
/// sees more than the cap leave, and each exit's share comes back exactly
/// SWEEP_WINDOW after it was made. A live entry is never dropped: when
/// SWEEP_LOG_SIZE exits from the last 24 hours are logged, the next one fails
/// with SweepLogFull until the oldest expires.
pub(crate) fn consume_sweep_allowance(env: &Env, token: &Address, amount: i128) -> Result<(), Error> {
    let cap = get_cap(env, token);
    if cap == 0 {
        return Err(Error::SweepCapNotSet);
    }
    if cap == SWEEP_CAP_UNLIMITED {
        return Ok(());
    }

    let (used, mut live) = sweep_usage(env, token);
    let total = used.checked_add(amount).ok_or(Error::SweepCapExceeded)?;
    if total > cap {
        return Err(Error::SweepCapExceeded);
    }
    if live.len() >= SWEEP_LOG_SIZE {
        return Err(Error::SweepLogFull);
    }

    live.push_back(SweepExit {
        at: env.ledger().timestamp(),
        amount,
    });
    let key = DataKey::SweepLog(token.clone());
    env.storage().persistent().set(&key, &live);
    bump_persistent(env, &key);
    Ok(())
}

/// How much of `token` the sweep cap lets leave right now, across every capped
/// exit. `SWEEP_CAP_UNLIMITED` when the cap is unlimited.
pub fn sweep_allowance(env: &Env, token: Address) -> i128 {
    let cap = get_cap(env, &token);
    if cap == SWEEP_CAP_UNLIMITED {
        return cap;
    }
    let (used, live) = sweep_usage(env, &token);
    if used >= cap || live.len() >= SWEEP_LOG_SIZE {
        0
    } else {
        cap - used
    }
}

/// Every transfer out of the contract goes through here. It also keeps the
/// platform fee ledger backed: the whole-treasury exits (`withdraw`,
/// `execute_withdrawal`) can take the balance below the accrued fees, and when
/// one does, the fees it took left with it, so they are booked as swept to the
/// same recipient.
pub(crate) fn send_out(env: &Env, token: &Address, recipient: &Address, amount: i128) {
    let client = token::TokenClient::new(env, token);
    client.transfer(&env.current_contract_address(), recipient, &amount);

    let fee_key = DataKey::PlatformFee(token.clone());
    let accrued: i128 = env.storage().persistent().get(&fee_key).unwrap_or(0);
    if accrued != 0 {
        let left = client.balance(&env.current_contract_address());
        if left < accrued {
            env.storage().persistent().set(&fee_key, &left);
            bump_persistent(env, &fee_key);
            PlatformFeesSwept {
                token: token.clone(),
                recipient: recipient.clone(),
                amount: accrued - left,
            }
            .publish(env);
        }
    }
}

/// Lowers (tightens) a token's sweep cap. Immediate — tightening is always safe.
/// Raising must go through `queue_sweep_cap`, otherwise the rate limit would be
/// one call away from being defeated.
///
/// 0 is the emergency brake: it freezes every exit for the token. Any raise
/// already queued for the token is cancelled, so a tightening always supersedes
/// a pending loosening and the brake holds in a single call.
pub fn set_sweep_cap(env: &Env, owner: Address, token: Address, cap: i128) -> Result<(), Error> {
    let config = get_config(env)?;
    require_owner(&config, &owner)?;

    if cap < 0 {
        return Err(Error::ZeroAmount);
    }
    if cap > get_cap(env, &token) {
        return Err(Error::NotALoosening);
    }

    let key = DataKey::SweepCap(token.clone());
    env.storage().persistent().set(&key, &cap);
    bump_persistent(env, &key);

    let pending_key = DataKey::PendingSweepCap(token.clone());
    if env.storage().persistent().has(&pending_key) {
        env.storage().persistent().remove(&pending_key);
        PendingSweepCapCancelled {
            token: token.clone(),
        }
        .publish(env);
    }

    SweepCapUpdated { token, cap }.publish(env);
    Ok(())
}

pub fn queue_sweep_cap(env: &Env, owner: Address, token: Address, cap: i128) -> Result<(), Error> {
    let config = get_config(env)?;
    require_owner(&config, &owner)?;

    if cap <= get_cap(env, &token) {
        return Err(Error::NotALoosening);
    }

    let unlock_time = env.ledger().timestamp() + config.withdrawal_delay;
    let key = DataKey::PendingSweepCap(token.clone());
    env.storage().persistent().set(
        &key,
        &PendingCap {
            value: cap,
            unlock_time,
        },
    );
    bump_persistent(env, &key);

    PendingSweepCapQueued {
        token,
        cap,
        unlock_time,
    }
    .publish(env);
    Ok(())
}

pub fn apply_sweep_cap(env: &Env, owner: Address, token: Address) -> Result<(), Error> {
    let config = get_config(env)?;
    require_owner(&config, &owner)?;

    let key = DataKey::PendingSweepCap(token.clone());
    let pending: PendingCap = env
        .storage()
        .persistent()
        .get(&key)
        .ok_or(Error::NoPendingChange)?;
    require_unlocked(env, &config, pending.unlock_time)?;
    env.storage().persistent().remove(&key);

    let cap_key = DataKey::SweepCap(token.clone());
    env.storage().persistent().set(&cap_key, &pending.value);
    bump_persistent(env, &cap_key);

    SweepCapUpdated {
        token,
        cap: pending.value,
    }
    .publish(env);
    Ok(())
}

pub fn cancel_sweep_cap(env: &Env, owner: Address, token: Address) -> Result<(), Error> {
    let config = get_config(env)?;
    require_owner(&config, &owner)?;

    let key = DataKey::PendingSweepCap(token.clone());
    if !env.storage().persistent().has(&key) {
        return Err(Error::NoPendingChange);
    }
    env.storage().persistent().remove(&key);

    PendingSweepCapCancelled { token }.publish(env);
    Ok(())
}

pub fn get_sweep_cap(env: &Env, token: Address) -> i128 {
    get_cap(env, &token)
}

/// Sweeps accrued platform fees (bounded by what merchant payments have
/// actually accrued for this token) to `recipient`.
pub fn sweep_platform_fees(
    env: &Env,
    owner: Address,
    token: Address,
    recipient: Address,
    amount: i128,
) -> Result<(), Error> {
    let config = get_config(env)?;
    require_owner(&config, &owner)?;

    if amount <= 0 {
        return Err(Error::ZeroAmount);
    }

    let fee_key = DataKey::PlatformFee(token.clone());
    let accrued: i128 = env.storage().persistent().get(&fee_key).unwrap_or(0);
    if amount > accrued {
        return Err(Error::FeeAmountInvalid);
    }
    consume_sweep_allowance(env, &token, amount)?;
    let remaining = accrued - amount;
    env.storage().persistent().set(&fee_key, &remaining);
    bump_persistent(env, &fee_key);

    send_out(env, &token, &recipient, amount);

    PlatformFeesSwept {
        token,
        recipient,
        amount,
    }
    .publish(env);
    Ok(())
}

/// Sweeps merchant-backing funds (the float backing merchant payouts) to
/// `recipient`. Accrued platform fees are not float: they stay behind for
/// `sweep_platform_fees`, so the fee ledger stays backed.
pub fn sweep_merchant_backing(
    env: &Env,
    owner: Address,
    token: Address,
    recipient: Address,
    amount: i128,
) -> Result<(), Error> {
    let config = get_config(env)?;
    require_owner(&config, &owner)?;

    if amount <= 0 {
        return Err(Error::ZeroAmount);
    }

    let balance = token::TokenClient::new(env, &token).balance(&env.current_contract_address());
    let fees: i128 = env
        .storage()
        .persistent()
        .get(&DataKey::PlatformFee(token.clone()))
        .unwrap_or(0);
    if fees > balance || amount > balance - fees {
        return Err(Error::InsufficientBalance);
    }
    consume_sweep_allowance(env, &token, amount)?;

    send_out(env, &token, &recipient, amount);

    MerchantBackingSwept {
        token,
        recipient,
        amount,
    }
    .publish(env);
    Ok(())
}
