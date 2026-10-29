#![no_std]

mod admin;
mod config;
mod errors;
mod events;
mod merchant;
mod point;
mod transaction;
mod treasury;
mod types;
mod util;
mod withdraw;

#[cfg(test)]
mod test;

use soroban_sdk::{contract, contractimpl, Address, BytesN, Env, String};

pub use errors::Error;
pub use types::{
    Config, CreateTransactionParams, DataKey, MerchantPayment, MerchantQuote,
    PointDepositRecord, TransactionRecord, WithdrawalRequest,
};

#[contract]
pub struct TakumiPay;

#[contractimpl]
impl TakumiPay {
    // ── Initialize ──────────────────────────────────────────────────

    pub fn initialize(env: Env, owner: Address, backend_signer: BytesN<32>) -> Result<(), Error> {
        admin::initialize(&env, owner, backend_signer)
    }

    // ── Admin management ────────────────────────────────────────────

    pub fn add_admin(env: Env, owner: Address, admin: Address) -> Result<(), Error> {
        admin::add_admin(&env, owner, admin)
    }

    pub fn remove_admin(env: Env, owner: Address, admin: Address) -> Result<(), Error> {
        admin::remove_admin(&env, owner, admin)
    }

    // ── Ownership transfer ──────────────────────────────────────────

    pub fn transfer_ownership(env: Env, owner: Address, new_owner: Address) -> Result<(), Error> {
        admin::transfer_ownership(&env, owner, new_owner)
    }

    pub fn accept_ownership(env: Env, new_owner: Address) -> Result<(), Error> {
        admin::accept_ownership(&env, new_owner)
    }

    pub fn cancel_ownership_transfer(env: Env, owner: Address) -> Result<(), Error> {
        admin::cancel_ownership_transfer(&env, owner)
    }

    // ── Configuration ───────────────────────────────────────────────

    pub fn set_paused(env: Env, caller: Address, paused: bool) -> Result<(), Error> {
        config::set_paused(&env, caller, paused)
    }

    pub fn set_point_deposits_paused(
        env: Env,
        caller: Address,
        paused: bool,
    ) -> Result<(), Error> {
        config::set_point_deposits_paused(&env, caller, paused)
    }

    pub fn set_spending_limit(
        env: Env,
        owner: Address,
        token: Address,
        max_amount: i128,
    ) -> Result<(), Error> {
        config::set_spending_limit(&env, owner, token, max_amount)
    }

    pub fn rotate_backend_signer(
        env: Env,
        owner: Address,
        new_signer: BytesN<32>,
    ) -> Result<(), Error> {
        config::rotate_backend_signer(&env, owner, new_signer)
    }

    pub fn add_allowed_payment_token(
        env: Env,
        owner: Address,
        token: Address,
    ) -> Result<(), Error> {
        config::add_allowed_payment_token(&env, owner, token)
    }

    pub fn remove_allowed_payment_token(
        env: Env,
        owner: Address,
        token: Address,
    ) -> Result<(), Error> {
        config::remove_allowed_payment_token(&env, owner, token)
    }

    // ── Transactions ────────────────────────────────────────────────

    pub fn create_transaction(
        env: Env,
        payer: Address,
        params: CreateTransactionParams,
    ) -> Result<u64, Error> {
        transaction::create_transaction(&env, payer, params)
    }

    // ── Merchant payments ───────────────────────────────────────────

    pub fn process_merchant_payment(
        env: Env,
        payer: Address,
        quote: MerchantQuote,
        backend_signature: BytesN<64>,
    ) -> Result<(), Error> {
        merchant::process_merchant_payment(&env, payer, quote, backend_signature)
    }

    // ── Point deposits ──────────────────────────────────────────────

    pub fn deposit_points(
        env: Env,
        payer: Address,
        token: Address,
        ref_id: String,
        amount: i128,
    ) -> Result<u64, Error> {
        point::deposit_points(&env, payer, token, ref_id, amount)
    }

    // ── Treasury ────────────────────────────────────────────────────

    pub fn sweep_platform_fees(
        env: Env,
        owner: Address,
        token: Address,
        recipient: Address,
        amount: i128,
    ) -> Result<(), Error> {
        treasury::sweep_platform_fees(&env, owner, token, recipient, amount)
    }

    pub fn sweep_merchant_backing(
        env: Env,
        owner: Address,
        token: Address,
        recipient: Address,
        amount: i128,
    ) -> Result<(), Error> {
        treasury::sweep_merchant_backing(&env, owner, token, recipient, amount)
    }

    // ── Sweep rate limit ────────────────────────────────────────────
    // Sweeps bypass the withdrawal timelock by design (merchant float has to
    // settle daily), so a per-token cap bounds what a leaked owner key can move
    // in any 24 hours. Every exit draws on it, withdrawals included. Raising a
    // cap is a loosening and is queued.

    pub fn set_sweep_cap(env: Env, owner: Address, token: Address, cap: i128) -> Result<(), Error> {
        treasury::set_sweep_cap(&env, owner, token, cap)
    }

    pub fn queue_sweep_cap(
        env: Env,
        owner: Address,
        token: Address,
        cap: i128,
    ) -> Result<(), Error> {
        treasury::queue_sweep_cap(&env, owner, token, cap)
    }

    pub fn apply_sweep_cap(env: Env, owner: Address, token: Address) -> Result<(), Error> {
        treasury::apply_sweep_cap(&env, owner, token)
    }

    pub fn cancel_sweep_cap(env: Env, owner: Address, token: Address) -> Result<(), Error> {
        treasury::cancel_sweep_cap(&env, owner, token)
    }

    pub fn get_sweep_cap(env: Env, token: Address) -> i128 {
        treasury::get_sweep_cap(&env, token)
    }

    /// What the sweep cap lets leave right now, across every capped exit.
    pub fn get_sweep_allowance(env: Env, token: Address) -> i128 {
        treasury::sweep_allowance(&env, token)
    }

    /// When `set_withdrawal_delay` last ran; queued entries also wait the full
    /// current delay from then.
    pub fn get_withdrawal_delay_raised_at(env: Env) -> u64 {
        withdraw::get_delay_raised_at(&env)
    }

    // ── Withdrawals ─────────────────────────────────────────────────

    pub fn withdraw(
        env: Env,
        owner: Address,
        token: Address,
        recipient: Address,
        amount: i128,
    ) -> Result<(), Error> {
        withdraw::withdraw(&env, owner, token, recipient, amount)
    }

    pub fn set_withdrawal_delay(env: Env, owner: Address, delay: u64) -> Result<(), Error> {
        withdraw::set_withdrawal_delay(&env, owner, delay)
    }

    pub fn queue_withdrawal_delay(env: Env, owner: Address, delay: u64) -> Result<(), Error> {
        withdraw::queue_withdrawal_delay(&env, owner, delay)
    }

    pub fn apply_withdrawal_delay(env: Env, owner: Address) -> Result<(), Error> {
        withdraw::apply_withdrawal_delay(&env, owner)
    }

    pub fn cancel_withdrawal_delay(env: Env, owner: Address) -> Result<(), Error> {
        withdraw::cancel_withdrawal_delay(&env, owner)
    }

    pub fn queue_withdrawal(
        env: Env,
        owner: Address,
        token: Address,
        recipient: Address,
        amount: i128,
    ) -> Result<u64, Error> {
        withdraw::queue_withdrawal(&env, owner, token, recipient, amount)
    }

    pub fn execute_withdrawal(env: Env, owner: Address, nonce: u64) -> Result<(), Error> {
        withdraw::execute_withdrawal(&env, owner, nonce)
    }

    pub fn cancel_withdrawal(env: Env, owner: Address, nonce: u64) -> Result<(), Error> {
        withdraw::cancel_withdrawal(&env, owner, nonce)
    }

    // ── Read-only views ─────────────────────────────────────────────

    pub fn get_config(env: Env) -> Result<Config, Error> {
        admin::get_config(&env)
    }

    pub fn get_transaction(env: Env, tx_id: u64) -> Option<TransactionRecord> {
        transaction::get_transaction(&env, tx_id)
    }

    pub fn get_merchant_payment(env: Env, ref_id: String) -> Option<MerchantPayment> {
        merchant::get_merchant_payment(&env, &ref_id)
    }

    pub fn get_point_deposit(env: Env, deposit_id: u64) -> Option<PointDepositRecord> {
        point::get_point_deposit(&env, deposit_id)
    }

    pub fn get_withdrawal(env: Env, nonce: u64) -> Option<WithdrawalRequest> {
        withdraw::get_withdrawal(&env, nonce)
    }

    pub fn get_platform_fee_accrued(env: Env, token: Address) -> i128 {
        env.storage()
            .persistent()
            .get(&DataKey::PlatformFee(token))
            .unwrap_or(0)
    }

    pub fn is_admin(env: Env, admin: Address) -> bool {
        env.storage().persistent().has(&DataKey::Admin(admin))
    }

    pub fn is_allowed_payment_token(env: Env, token: Address) -> bool {
        env.storage()
            .persistent()
            .has(&DataKey::AllowedPaymentToken(token))
    }

    pub fn get_spending_limit(env: Env, token: Address) -> i128 {
        env.storage()
            .persistent()
            .get(&DataKey::SpendingLimit(token))
            .unwrap_or(0)
    }
}
