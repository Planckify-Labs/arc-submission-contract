use soroban_sdk::{Address, Env};

use crate::admin::{bump_persistent, get_config, require_owner, save_config};
use crate::errors::Error;
use crate::events::{
    PendingDelayCancelled, PendingDelayQueued, WithdrawalCancelled,
    WithdrawalDelayUpdated, WithdrawalExecuted, WithdrawalQueued, WithdrawEvent,
};
use crate::treasury::{consume_sweep_allowance, send_out};
use crate::types::{
    Config, DataKey, PendingDelay, WithdrawalRequest, INSTANCE_BUMP_THRESHOLD, INSTANCE_BUMP_TO,
    MAX_WITHDRAWAL_DELAY,
};

/// A queued entry unlocks at the time it was given, and never before the full
/// current delay has passed since `set_withdrawal_delay` last ran. An entry
/// queued after that always satisfies the second check, so it only ever binds
/// entries queued under an earlier, shorter delay.
pub(crate) fn require_unlocked(env: &Env, config: &Config, unlock_time: u64) -> Result<(), Error> {
    let now = env.ledger().timestamp();
    let raised_at: u64 = env
        .storage()
        .instance()
        .get(&DataKey::DelayRaisedAt)
        .unwrap_or(0);
    if now < unlock_time || now < raised_at + config.withdrawal_delay {
        return Err(Error::TimelockNotExpired);
    }
    Ok(())
}

pub fn get_delay_raised_at(env: &Env) -> u64 {
    env.storage()
        .instance()
        .get(&DataKey::DelayRaisedAt)
        .unwrap_or(0)
}

/// Immediate withdrawal — only usable while no timelock delay is configured.
/// Once `set_withdrawal_delay` is set above 0, callers must use
/// queue/execute so every withdrawal has a mandatory cooling-off period.
///
/// Like every exit it is bounded by the token's sweep cap. It is a
/// whole-treasury exit: it does not hold back accrued platform fees, and fees it
/// takes are booked as swept (see `send_out`).
pub fn withdraw(
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
    if config.withdrawal_delay != 0 {
        return Err(Error::TimelockActive);
    }
    consume_sweep_allowance(env, &token, amount)?;

    send_out(env, &token, &recipient, amount);

    WithdrawEvent {
        token,
        recipient,
        amount,
    }
    .publish(env);
    Ok(())
}

/// Raises the withdrawal delay. Immediate — tightening a control is always safe.
///
/// Lowering must go through `queue_withdrawal_delay` / `apply_withdrawal_delay`
/// so the reduction is itself subject to the delay currently in force. Without
/// that the timelock is decorative: an owner key that leaks would simply set the
/// delay to 0 and withdraw in the same transaction.
///
/// It also restarts the clock on everything already queued: sweep cap raises,
/// delay cuts and withdrawals all wait the full new delay from now (see
/// `require_unlocked`), so raising the delay works as an emergency brake on
/// entries queued under the shorter one. Calling it with the current value
/// restarts the clock without changing the delay.
pub fn set_withdrawal_delay(env: &Env, owner: Address, delay: u64) -> Result<(), Error> {
    let mut config = get_config(env)?;
    require_owner(&config, &owner)?;

    if delay > MAX_WITHDRAWAL_DELAY {
        return Err(Error::DelayExceedsMax);
    }
    if delay < config.withdrawal_delay {
        return Err(Error::NotALoosening);
    }
    config.withdrawal_delay = delay;
    save_config(env, &config);
    env.storage()
        .instance()
        .set(&DataKey::DelayRaisedAt, &env.ledger().timestamp());
    env.storage()
        .instance()
        .extend_ttl(INSTANCE_BUMP_THRESHOLD, INSTANCE_BUMP_TO);

    WithdrawalDelayUpdated { delay }.publish(env);
    Ok(())
}

pub fn queue_withdrawal_delay(env: &Env, owner: Address, delay: u64) -> Result<(), Error> {
    let config = get_config(env)?;
    require_owner(&config, &owner)?;

    if delay >= config.withdrawal_delay {
        return Err(Error::NotALoosening);
    }

    let unlock_time = env.ledger().timestamp() + config.withdrawal_delay;
    let key = DataKey::PendingWithdrawalDelay;
    env.storage().persistent().set(
        &key,
        &PendingDelay {
            value: delay,
            unlock_time,
        },
    );
    bump_persistent(env, &key);

    PendingDelayQueued { delay, unlock_time }.publish(env);
    Ok(())
}

pub fn apply_withdrawal_delay(env: &Env, owner: Address) -> Result<(), Error> {
    let mut config = get_config(env)?;
    require_owner(&config, &owner)?;

    let key = DataKey::PendingWithdrawalDelay;
    let pending: PendingDelay = env
        .storage()
        .persistent()
        .get(&key)
        .ok_or(Error::NoPendingChange)?;
    require_unlocked(env, &config, pending.unlock_time)?;
    env.storage().persistent().remove(&key);

    config.withdrawal_delay = pending.value;
    save_config(env, &config);

    WithdrawalDelayUpdated {
        delay: pending.value,
    }
    .publish(env);
    Ok(())
}

pub fn cancel_withdrawal_delay(env: &Env, owner: Address) -> Result<(), Error> {
    let config = get_config(env)?;
    require_owner(&config, &owner)?;

    let key = DataKey::PendingWithdrawalDelay;
    let pending: PendingDelay = env
        .storage()
        .persistent()
        .get(&key)
        .ok_or(Error::NoPendingChange)?;
    env.storage().persistent().remove(&key);

    PendingDelayCancelled {
        delay: pending.value,
    }
    .publish(env);
    Ok(())
}

pub fn queue_withdrawal(
    env: &Env,
    owner: Address,
    token: Address,
    recipient: Address,
    amount: i128,
) -> Result<u64, Error> {
    let mut config = get_config(env)?;
    require_owner(&config, &owner)?;

    if amount <= 0 {
        return Err(Error::ZeroAmount);
    }
    if config.withdrawal_delay == 0 {
        return Err(Error::NoDelaySet);
    }

    config.withdrawal_nonce += 1;
    let nonce = config.withdrawal_nonce;
    let unlock_time = env.ledger().timestamp() + config.withdrawal_delay;

    let request = WithdrawalRequest {
        token: token.clone(),
        recipient: recipient.clone(),
        amount,
        unlock_time,
        executed: false,
        cancelled: false,
        nonce,
    };
    let key = DataKey::Withdrawal(nonce);
    env.storage().persistent().set(&key, &request);
    bump_persistent(env, &key);

    save_config(env, &config);

    WithdrawalQueued {
        token,
        recipient,
        nonce,
        amount,
        unlock_time,
    }
    .publish(env);
    Ok(nonce)
}

pub fn execute_withdrawal(env: &Env, owner: Address, nonce: u64) -> Result<(), Error> {
    let config = get_config(env)?;
    require_owner(&config, &owner)?;

    let key = DataKey::Withdrawal(nonce);
    let mut request: WithdrawalRequest = env
        .storage()
        .persistent()
        .get(&key)
        .ok_or(Error::NoPendingTransfer)?;

    if request.executed {
        return Err(Error::AlreadyExecuted);
    }
    if request.cancelled {
        return Err(Error::AlreadyCancelled);
    }
    require_unlocked(env, &config, request.unlock_time)?;
    consume_sweep_allowance(env, &request.token, request.amount)?;

    request.executed = true;
    env.storage().persistent().set(&key, &request);
    bump_persistent(env, &key);

    send_out(env, &request.token, &request.recipient, request.amount);

    WithdrawalExecuted { nonce }.publish(env);
    Ok(())
}

pub fn cancel_withdrawal(env: &Env, owner: Address, nonce: u64) -> Result<(), Error> {
    let config = get_config(env)?;
    require_owner(&config, &owner)?;

    let key = DataKey::Withdrawal(nonce);
    let mut request: WithdrawalRequest = env
        .storage()
        .persistent()
        .get(&key)
        .ok_or(Error::NoPendingTransfer)?;

    if request.executed {
        return Err(Error::AlreadyExecuted);
    }
    if request.cancelled {
        return Err(Error::AlreadyCancelled);
    }

    request.cancelled = true;
    env.storage().persistent().set(&key, &request);
    bump_persistent(env, &key);

    WithdrawalCancelled { nonce }.publish(env);
    Ok(())
}

pub fn get_withdrawal(env: &Env, nonce: u64) -> Option<WithdrawalRequest> {
    env.storage().persistent().get(&DataKey::Withdrawal(nonce))
}
