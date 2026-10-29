extern crate std;

use ed25519_dalek::{Signer, SigningKey};
use soroban_sdk::testutils::{Address as _, Events as _, Ledger};
use soroban_sdk::xdr::ToXdr;
use soroban_sdk::{token, Address, BytesN, Env, Event, String};

use crate::events::{PendingSweepCapCancelled, PlatformFeesSwept};
use crate::merchant::QuoteMessage;
use crate::types::{MerchantQuote, SWEEP_CAP_UNLIMITED, SWEEP_WINDOW};
use crate::{Error, TakumiPay, TakumiPayClient};

/// Raising a sweep cap is a loosening, so it is a two-step queue/apply. With
/// `withdrawal_delay` at 0 both legs land in the same ledger.
fn raise_sweep_cap(client: &TakumiPayClient, owner: &Address, token: &Address, cap: i128) {
    client.queue_sweep_cap(owner, token, &cap);
    client.apply_sweep_cap(owner, token);
}

fn signing_key(env: &Env) -> (SigningKey, BytesN<32>) {
    let mut csprng = rand::rngs::OsRng;
    let key = SigningKey::generate(&mut csprng);
    let pubkey = BytesN::from_array(env, &key.verifying_key().to_bytes());
    (key, pubkey)
}

fn sign_quote(
    env: &Env,
    contract_id: &Address,
    key: &SigningKey,
    quote: &MerchantQuote,
) -> BytesN<64> {
    let message = QuoteMessage {
        network_id: env.ledger().network_id(),
        contract: contract_id.clone(),
        quote: quote.clone(),
    };
    let bytes = message.to_xdr(env);
    let buffer = bytes.to_buffer::<1024>();
    let sig = key.sign(buffer.as_slice());
    BytesN::from_array(env, &sig.to_bytes())
}

fn setup(env: &Env) -> (TakumiPayClient<'_>, Address, Address, SigningKey) {
    env.mock_all_auths();
    let owner = Address::generate(env);
    let (backend_key, backend_pubkey) = signing_key(env);

    let contract_id = env.register(TakumiPay, ());
    let client = TakumiPayClient::new(env, &contract_id);
    client.initialize(&owner, &backend_pubkey);

    (client, owner, contract_id, backend_key)
}

fn setup_token(env: &Env, admin: &Address) -> Address {
    env.register_stellar_asset_contract_v2(admin.clone()).address()
}

fn mint(env: &Env, token: &Address, to: &Address, amount: i128) {
    token::StellarAssetClient::new(env, token).mint(to, &amount);
}

fn default_quote(env: &Env, token: &Address, ref_id: &str, expires_at: u64) -> MerchantQuote {
    MerchantQuote {
        ref_id: String::from_str(env, ref_id),
        merchant_id: String::from_str(env, "merchant-1"),
        token: token.clone(),
        amount: 1_000_000,
        platform_fee_amount: 10_000,
        fiat_amount_minor: 150_000,
        fiat_currency: BytesN::from_array(env, b"USD"),
        exchange_rate_id: 42,
        expires_at,
    }
}

#[test]
fn test_initialize_and_config() {
    let env = Env::default();
    let (client, owner, _contract_id, _backend_key) = setup(&env);

    let config = client.get_config();
    assert_eq!(config.owner, owner);
    assert!(!config.paused);
    assert!(!config.point_deposits_paused);
    assert_eq!(config.tx_counter, 0);
}

#[test]
fn test_admin_management_and_pause() {
    let env = Env::default();
    let (client, owner, _contract_id, _backend_key) = setup(&env);

    let admin = Address::generate(&env);
    client.add_admin(&owner, &admin);
    assert!(client.is_admin(&admin));

    // Admin (not owner) can pause.
    client.set_paused(&admin, &true);
    assert!(client.get_config().paused);

    client.set_paused(&owner, &false);
    assert!(!client.get_config().paused);

    client.remove_admin(&owner, &admin);
    assert!(!client.is_admin(&admin));
}

#[test]
fn test_ownership_transfer_flow() {
    let env = Env::default();
    let (client, owner, _contract_id, _backend_key) = setup(&env);

    let new_owner = Address::generate(&env);
    client.transfer_ownership(&owner, &new_owner);
    assert_eq!(client.get_config().pending_owner, Some(new_owner.clone()));

    client.accept_ownership(&new_owner);
    let config = client.get_config();
    assert_eq!(config.owner, new_owner);
    assert_eq!(config.pending_owner, None);

    // Old owner no longer has authority.
    let result = client.try_set_paused(&owner, &true);
    assert_eq!(result, Err(Ok(Error::NotAdminOrOwner)));
}

#[test]
fn test_create_transaction_and_spending_limit() {
    let env = Env::default();
    let (client, owner, contract_id, _backend_key) = setup(&env);

    let payer = Address::generate(&env);
    let token = setup_token(&env, &owner);
    mint(&env, &token, &payer, 10_000_000);
    client.add_allowed_payment_token(&owner, &token);

    client.set_spending_limit(&owner, &token, &500_000);

    let params = crate::types::CreateTransactionParams {
        booking_id: String::from_str(&env, "booking-1"),
        exchange_rate_id: 1,
        product_variant_id: String::from_str(&env, "variant-1"),
        ref_id: String::from_str(&env, "ref-1"),
        token: token.clone(),
        amount: 1_000_000,
    };

    let result = client.try_create_transaction(&payer, &params);
    assert_eq!(result, Err(Ok(Error::AmountExceedsLimit)));

    let mut ok_params = params.clone();
    ok_params.amount = 400_000;
    let tx_id = client.create_transaction(&payer, &ok_params);
    assert_eq!(tx_id, 1);

    let record = client.get_transaction(&tx_id).unwrap();
    assert_eq!(record.wallet_address, payer);
    assert_eq!(record.amount, 400_000);

    let token_client = token::TokenClient::new(&env, &token);
    assert_eq!(token_client.balance(&contract_id), 400_000);
    assert_eq!(token_client.balance(&payer), 10_000_000 - 400_000);

    // Replaying the same ref_id is rejected.
    let replay = client.try_create_transaction(&payer, &ok_params);
    assert_eq!(replay, Err(Ok(Error::RefConsumed)));
}

#[test]
fn test_process_merchant_payment_happy_path() {
    let env = Env::default();
    let (client, owner, contract_id, backend_key) = setup(&env);

    let payer = Address::generate(&env);
    let token = setup_token(&env, &owner);
    mint(&env, &token, &payer, 10_000_000);
    client.add_allowed_payment_token(&owner, &token);

    let quote = default_quote(&env, &token, "quote-1", env.ledger().timestamp() + 1000);
    let signature = sign_quote(&env, &contract_id, &backend_key, &quote);

    client.process_merchant_payment(&payer, &quote, &signature);

    let payment = client.get_merchant_payment(&quote.ref_id).unwrap();
    assert_eq!(payment.payer, payer);
    assert_eq!(payment.amount, 1_000_000);
    assert_eq!(payment.platform_fee_amount, 10_000);

    assert_eq!(client.get_platform_fee_accrued(&token), 10_000);

    let token_client = token::TokenClient::new(&env, &token);
    assert_eq!(token_client.balance(&contract_id), 1_000_000);

    // Same ref_id cannot be replayed even with a fresh valid signature.
    let replay_sig = sign_quote(&env, &contract_id, &backend_key, &quote);
    let replay = client.try_process_merchant_payment(&payer, &quote, &replay_sig);
    assert_eq!(replay, Err(Ok(Error::RefConsumed)));
}

#[test]
fn test_process_merchant_payment_expired_quote() {
    let env = Env::default();
    let (client, owner, contract_id, backend_key) = setup(&env);

    let payer = Address::generate(&env);
    let token = setup_token(&env, &owner);
    mint(&env, &token, &payer, 10_000_000);

    env.ledger().set_timestamp(1_000_000);
    let quote = default_quote(&env, &token, "quote-expired", 999_999);
    let signature = sign_quote(&env, &contract_id, &backend_key, &quote);

    let result = client.try_process_merchant_payment(&payer, &quote, &signature);
    assert_eq!(result, Err(Ok(Error::QuoteExpired)));
}

#[test]
#[should_panic]
fn test_process_merchant_payment_bad_signature_panics() {
    let env = Env::default();
    let (client, owner, contract_id, _backend_key) = setup(&env);

    let payer = Address::generate(&env);
    let token = setup_token(&env, &owner);
    mint(&env, &token, &payer, 10_000_000);
    client.add_allowed_payment_token(&owner, &token);

    let (wrong_key, _) = signing_key(&env);
    let quote = default_quote(&env, &token, "quote-bad-sig", env.ledger().timestamp() + 1000);
    let signature = sign_quote(&env, &contract_id, &wrong_key, &quote);

    client.process_merchant_payment(&payer, &quote, &signature);
}

#[test]
fn test_deposit_points_requires_allowed_token() {
    let env = Env::default();
    let (client, owner, _contract_id, _backend_key) = setup(&env);

    let payer = Address::generate(&env);
    let token = setup_token(&env, &owner);
    mint(&env, &token, &payer, 1_000_000);

    let ref_id = String::from_str(&env, "point-ref-1");
    let not_allowed = client.try_deposit_points(&payer, &token, &ref_id, &1000);
    assert_eq!(not_allowed, Err(Ok(Error::TokenNotAllowed)));

    client.add_allowed_payment_token(&owner, &token);
    let deposit_id = client.deposit_points(&payer, &token, &ref_id, &1000);
    assert_eq!(deposit_id, 1);

    let record = client.get_point_deposit(&deposit_id).unwrap();
    assert_eq!(record.amount, 1000);
    assert_eq!(record.wallet_address, payer);
}

#[test]
fn test_create_transaction_requires_allowed_token() {
    let env = Env::default();
    let (client, owner, _contract_id, _backend_key) = setup(&env);

    let payer = Address::generate(&env);
    let token = setup_token(&env, &owner);
    mint(&env, &token, &payer, 10_000_000);

    let params = crate::types::CreateTransactionParams {
        booking_id: String::from_str(&env, "booking-1"),
        exchange_rate_id: 1,
        product_variant_id: String::from_str(&env, "variant-1"),
        ref_id: String::from_str(&env, "ref-1"),
        token: token.clone(),
        amount: 400_000,
    };

    let not_allowed = client.try_create_transaction(&payer, &params);
    assert_eq!(not_allowed, Err(Ok(Error::TokenNotAllowed)));

    client.add_allowed_payment_token(&owner, &token);
    let tx_id = client.create_transaction(&payer, &params);
    assert_eq!(tx_id, 1);
}

#[test]
fn test_process_merchant_payment_requires_allowed_token() {
    let env = Env::default();
    let (client, owner, contract_id, backend_key) = setup(&env);

    let payer = Address::generate(&env);
    let token = setup_token(&env, &owner);
    mint(&env, &token, &payer, 10_000_000);

    let quote = default_quote(&env, &token, "quote-not-allowed", env.ledger().timestamp() + 1000);
    let signature = sign_quote(&env, &contract_id, &backend_key, &quote);

    let not_allowed = client.try_process_merchant_payment(&payer, &quote, &signature);
    assert_eq!(not_allowed, Err(Ok(Error::TokenNotAllowed)));

    client.add_allowed_payment_token(&owner, &token);
    client.process_merchant_payment(&payer, &quote, &signature);
    assert!(client.get_merchant_payment(&quote.ref_id).is_some());
}

#[test]
fn test_treasury_sweeps() {
    let env = Env::default();
    let (client, owner, contract_id, backend_key) = setup(&env);

    let payer = Address::generate(&env);
    let recipient = Address::generate(&env);
    let token = setup_token(&env, &owner);
    mint(&env, &token, &payer, 10_000_000);
    client.add_allowed_payment_token(&owner, &token);

    let quote = default_quote(&env, &token, "quote-treasury", env.ledger().timestamp() + 1000);
    let signature = sign_quote(&env, &contract_id, &backend_key, &quote);
    client.process_merchant_payment(&payer, &quote, &signature);

    // Sweeps fail closed until a cap is configured.
    let uncapped = client.try_sweep_platform_fees(&owner, &token, &recipient, &10_000);
    assert_eq!(uncapped, Err(Ok(Error::SweepCapNotSet)));
    raise_sweep_cap(&client, &owner, &token, SWEEP_CAP_UNLIMITED);

    // Fee sweep is bounded by accrued fees.
    let over = client.try_sweep_platform_fees(&owner, &token, &recipient, &20_000);
    assert_eq!(over, Err(Ok(Error::FeeAmountInvalid)));

    client.sweep_platform_fees(&owner, &token, &recipient, &10_000);
    assert_eq!(client.get_platform_fee_accrued(&token), 0);

    let token_client = token::TokenClient::new(&env, &token);
    assert_eq!(token_client.balance(&recipient), 10_000);
    assert_eq!(token_client.balance(&contract_id), 1_000_000 - 10_000);

    // Backing sweep moves the remaining merchant-payment principal.
    client.sweep_merchant_backing(&owner, &token, &recipient, &990_000);
    assert_eq!(token_client.balance(&contract_id), 0);
    assert_eq!(token_client.balance(&recipient), 1_000_000);
}

#[test]
fn test_withdrawal_timelock_flow() {
    let env = Env::default();
    let (client, owner, contract_id, backend_key) = setup(&env);

    let payer = Address::generate(&env);
    let recipient = Address::generate(&env);
    let token = setup_token(&env, &owner);
    mint(&env, &token, &payer, 10_000_000);
    client.add_allowed_payment_token(&owner, &token);

    let quote = default_quote(&env, &token, "quote-withdraw", env.ledger().timestamp() + 1000);
    let signature = sign_quote(&env, &contract_id, &backend_key, &quote);
    client.process_merchant_payment(&payer, &quote, &signature);

    // Withdrawals draw on the sweep cap like every other exit, so it is set
    // first, while the delay is still 0.
    raise_sweep_cap(&client, &owner, &token, SWEEP_CAP_UNLIMITED);
    client.set_withdrawal_delay(&owner, &3600);

    // Immediate withdraw is blocked once a delay is configured.
    let blocked = client.try_withdraw(&owner, &token, &recipient, &1000);
    assert_eq!(blocked, Err(Ok(Error::TimelockActive)));

    let nonce = client.queue_withdrawal(&owner, &token, &recipient, &500_000);
    assert_eq!(nonce, 1);

    let too_early = client.try_execute_withdrawal(&owner, &nonce);
    assert_eq!(too_early, Err(Ok(Error::TimelockNotExpired)));

    env.ledger().set_timestamp(env.ledger().timestamp() + 3601);
    client.execute_withdrawal(&owner, &nonce);

    let token_client = token::TokenClient::new(&env, &token);
    assert_eq!(token_client.balance(&recipient), 500_000);

    let already = client.try_execute_withdrawal(&owner, &nonce);
    assert_eq!(already, Err(Ok(Error::AlreadyExecuted)));
}

#[test]
fn test_sweep_cap_rate_limits_and_resets() {
    let env = Env::default();
    let (client, owner, contract_id, backend_key) = setup(&env);

    let payer = Address::generate(&env);
    let recipient = Address::generate(&env);
    let token = setup_token(&env, &owner);
    mint(&env, &token, &payer, 10_000_000);
    client.add_allowed_payment_token(&owner, &token);

    let quote = default_quote(&env, &token, "quote-cap", env.ledger().timestamp() + 1000);
    let signature = sign_quote(&env, &contract_id, &backend_key, &quote);
    client.process_merchant_payment(&payer, &quote, &signature);

    raise_sweep_cap(&client, &owner, &token, 100_000);

    client.sweep_merchant_backing(&owner, &token, &recipient, &60_000);

    // 60_000 consumed this window; 50_000 more would breach the 100_000 cap.
    let over = client.try_sweep_merchant_backing(&owner, &token, &recipient, &50_000);
    assert_eq!(over, Err(Ok(Error::SweepCapExceeded)));

    let token_client = token::TokenClient::new(&env, &token);
    assert_eq!(token_client.balance(&recipient), 60_000);

    // A fresh window restores the full allowance.
    env.ledger()
        .set_timestamp(env.ledger().timestamp() + SWEEP_WINDOW);
    client.sweep_merchant_backing(&owner, &token, &recipient, &100_000);
    assert_eq!(token_client.balance(&recipient), 160_000);
}

#[test]
fn test_sweep_cap_raise_is_queued_lower_is_immediate() {
    let env = Env::default();
    let (client, owner, _contract_id, _backend_key) = setup(&env);
    let token = setup_token(&env, &owner);

    raise_sweep_cap(&client, &owner, &token, 100_000);
    assert_eq!(client.get_sweep_cap(&token), 100_000);

    // Raising in a single call is rejected — that would defeat the rate limit.
    let direct = client.try_set_sweep_cap(&owner, &token, &200_000);
    assert_eq!(direct, Err(Ok(Error::NotALoosening)));

    // Lowering is immediate.
    client.set_sweep_cap(&owner, &token, &10_000);
    assert_eq!(client.get_sweep_cap(&token), 10_000);
}

/// The original bypass: set_withdrawal_delay(0) then withdraw() in one
/// transaction made the timelock decorative. Lowering is now queued behind the
/// delay currently in force.
#[test]
fn test_withdrawal_delay_cannot_be_lowered_instantly() {
    let env = Env::default();
    let (client, owner, _contract_id, _backend_key) = setup(&env);

    client.set_withdrawal_delay(&owner, &3600);

    let direct = client.try_set_withdrawal_delay(&owner, &0);
    assert_eq!(direct, Err(Ok(Error::NotALoosening)));
    assert_eq!(client.get_config().withdrawal_delay, 3600);

    client.queue_withdrawal_delay(&owner, &0);

    let too_early = client.try_apply_withdrawal_delay(&owner);
    assert_eq!(too_early, Err(Ok(Error::TimelockNotExpired)));
    assert_eq!(client.get_config().withdrawal_delay, 3600);

    env.ledger().set_timestamp(env.ledger().timestamp() + 3601);
    client.apply_withdrawal_delay(&owner);
    assert_eq!(client.get_config().withdrawal_delay, 0);
}

#[test]
fn test_withdrawal_delay_raise_is_immediate_and_cancellable() {
    let env = Env::default();
    let (client, owner, _contract_id, _backend_key) = setup(&env);

    client.set_withdrawal_delay(&owner, &1800);
    assert_eq!(client.get_config().withdrawal_delay, 1800);
    client.set_withdrawal_delay(&owner, &3600);
    assert_eq!(client.get_config().withdrawal_delay, 3600);

    client.queue_withdrawal_delay(&owner, &600);
    client.cancel_withdrawal_delay(&owner);

    env.ledger().set_timestamp(env.ledger().timestamp() + 7200);
    let cancelled = client.try_apply_withdrawal_delay(&owner);
    assert_eq!(cancelled, Err(Ok(Error::NoPendingChange)));
    assert_eq!(client.get_config().withdrawal_delay, 3600);
}

// ── Fixes ported from EVM 2.3.0 ───────────────────────────────────────────
// Section numbers refer to the Olympix scan of the EVM contract, answered in
// contract/evm/docs/olympix-bugpocer-response-2.2.0.md. The same weaknesses
// existed here.

/// A live chain's clock, so `T0 - SWEEP_WINDOW` style arithmetic never wraps.
const T0: u64 = 1_790_000_000;

/// The contract holding `float` of a fresh token, minted straight to it so no
/// platform fee is accrued, with the clock at T0.
fn funded(env: &Env, float: i128) -> (TakumiPayClient<'_>, Address, Address, Address, Address) {
    let (client, owner, contract_id, _key) = setup(env);
    env.ledger().set_timestamp(T0);
    let token = setup_token(env, &owner);
    mint(env, &token, &contract_id, float);
    let recipient = Address::generate(env);
    (client, owner, contract_id, token, recipient)
}

#[derive(Clone, Copy)]
enum Exit {
    SweepPlatformFees,
    SweepMerchantBacking,
    Withdraw,
    ExecuteWithdrawal,
}

#[allow(clippy::too_many_arguments)]
fn try_exit(
    client: &TakumiPayClient,
    exit: Exit,
    owner: &Address,
    token: &Address,
    recipient: &Address,
    amount: i128,
    nonce: u64,
) -> Result<(), Error> {
    let result = match exit {
        Exit::SweepPlatformFees => client.try_sweep_platform_fees(owner, token, recipient, &amount),
        Exit::SweepMerchantBacking => client.try_sweep_merchant_backing(owner, token, recipient, &amount),
        Exit::Withdraw => client.try_withdraw(owner, token, recipient, &amount),
        Exit::ExecuteWithdrawal => client.try_execute_withdrawal(owner, &nonce),
    };
    match result {
        Ok(_) => Ok(()),
        Err(Ok(error)) => Err(error),
        Err(Err(_)) => panic!("host error"),
    }
}

/// 5.2.2: the report's attack path. A small exit s at W, cap - s at
/// W + 1 day - 1s, then a full cap at W + 1 day: the third must fail, because
/// the trailing 24 hours still hold cap - s.
fn assert_no_boundary_burst(exit: Exit) {
    let env = Env::default();
    let (client, owner, contract_id, backend_key) = setup(&env);
    env.ledger().set_timestamp(T0);
    let token = setup_token(&env, &owner);
    let recipient = Address::generate(&env);
    let cap: i128 = 100_000;
    let s: i128 = 10_000;
    raise_sweep_cap(&client, &owner, &token, cap);

    let mut nonces = [0u64; 3];
    match exit {
        Exit::SweepPlatformFees => {
            let payer = Address::generate(&env);
            mint(&env, &token, &payer, 1_000_000);
            client.add_allowed_payment_token(&owner, &token);
            let mut quote = default_quote(&env, &token, "fees", T0 + 1000);
            quote.platform_fee_amount = quote.amount;
            let sig = sign_quote(&env, &contract_id, &backend_key, &quote);
            client.process_merchant_payment(&payer, &quote, &sig);
        }
        Exit::ExecuteWithdrawal => {
            mint(&env, &token, &contract_id, 1_000_000);
            client.set_withdrawal_delay(&owner, &3600);
            for (i, amount) in [s, cap - s, cap].iter().enumerate() {
                nonces[i] = client.queue_withdrawal(&owner, &token, &recipient, amount);
            }
            env.ledger().set_timestamp(T0 + 3600);
        }
        _ => mint(&env, &token, &contract_id, 1_000_000),
    }

    let w = env.ledger().timestamp();
    try_exit(&client, exit, &owner, &token, &recipient, s, nonces[0]).unwrap();
    env.ledger().set_timestamp(w + SWEEP_WINDOW - 1);
    try_exit(&client, exit, &owner, &token, &recipient, cap - s, nonces[1]).unwrap();

    env.ledger().set_timestamp(w + SWEEP_WINDOW);
    assert_eq!(client.get_sweep_allowance(&token), s);
    assert_eq!(
        try_exit(&client, exit, &owner, &token, &recipient, cap, nonces[2]),
        Err(Error::SweepCapExceeded)
    );
    assert_eq!(token::TokenClient::new(&env, &token).balance(&recipient), cap);
}

#[test]
fn test_no_boundary_burst_sweep_platform_fees() {
    assert_no_boundary_burst(Exit::SweepPlatformFees);
}

#[test]
fn test_no_boundary_burst_sweep_merchant_backing() {
    assert_no_boundary_burst(Exit::SweepMerchantBacking);
}

#[test]
fn test_no_boundary_burst_withdraw() {
    assert_no_boundary_burst(Exit::Withdraw);
}

#[test]
fn test_no_boundary_burst_execute_withdrawal() {
    assert_no_boundary_burst(Exit::ExecuteWithdrawal);
}

/// Withdrawals used to skip the cap entirely; now they fail closed without one
/// and share the allowance with the sweeps.
#[test]
fn test_withdraw_draws_on_the_sweep_cap() {
    let env = Env::default();
    let (client, owner, _contract_id, token, recipient) = funded(&env, 1_000_000);

    let uncapped = client.try_withdraw(&owner, &token, &recipient, &1);
    assert_eq!(uncapped, Err(Ok(Error::SweepCapNotSet)));

    raise_sweep_cap(&client, &owner, &token, 100_000);
    client.sweep_merchant_backing(&owner, &token, &recipient, &60_000);
    let over = client.try_withdraw(&owner, &token, &recipient, &50_000);
    assert_eq!(over, Err(Ok(Error::SweepCapExceeded)));
    client.withdraw(&owner, &token, &recipient, &40_000);
}

#[test]
fn test_each_exit_frees_its_share_exactly_a_day_later() {
    let env = Env::default();
    let (client, owner, _contract_id, token, recipient) = funded(&env, 1_000_000);
    raise_sweep_cap(&client, &owner, &token, 240_000);

    client.sweep_merchant_backing(&owner, &token, &recipient, &100_000);
    env.ledger().set_timestamp(T0 + 6 * 3600);
    client.sweep_merchant_backing(&owner, &token, &recipient, &140_000);
    assert_eq!(client.get_sweep_allowance(&token), 0);

    env.ledger().set_timestamp(T0 + SWEEP_WINDOW - 1);
    let early = client.try_sweep_merchant_backing(&owner, &token, &recipient, &1);
    assert_eq!(early, Err(Ok(Error::SweepCapExceeded)));

    env.ledger().set_timestamp(T0 + SWEEP_WINDOW);
    assert_eq!(client.get_sweep_allowance(&token), 100_000);
    env.ledger().set_timestamp(T0 + SWEEP_WINDOW + 6 * 3600);
    assert_eq!(client.get_sweep_allowance(&token), 240_000);
}

#[test]
fn test_sweep_log_holds_sixteen_exits_per_day() {
    let env = Env::default();
    let (client, owner, _contract_id, token, recipient) = funded(&env, 1_000_000);
    raise_sweep_cap(&client, &owner, &token, 1_000_000);

    for i in 0..16u64 {
        env.ledger().set_timestamp(T0 + i * 3600);
        client.sweep_merchant_backing(&owner, &token, &recipient, &1);
    }
    assert_eq!(client.get_sweep_allowance(&token), 0);
    let full = client.try_sweep_merchant_backing(&owner, &token, &recipient, &1);
    assert_eq!(full, Err(Ok(Error::SweepLogFull)));

    env.ledger().set_timestamp(T0 + SWEEP_WINDOW);
    assert_eq!(client.get_sweep_allowance(&token), 1_000_000 - 15);
    client.sweep_merchant_backing(&owner, &token, &recipient, &1);
}

/// 5.2.1: a cap raise queued while the delay was 0 waits the full delay once the
/// delay is raised.
#[test]
fn test_delay_raise_rearms_queued_cap_raise() {
    let env = Env::default();
    let (client, owner, _contract_id, token, _recipient) = funded(&env, 0);

    client.queue_sweep_cap(&owner, &token, &SWEEP_CAP_UNLIMITED);
    client.set_withdrawal_delay(&owner, &3600);
    assert_eq!(client.get_withdrawal_delay_raised_at(), T0);

    env.ledger().set_timestamp(T0 + 3599);
    let early = client.try_apply_sweep_cap(&owner, &token);
    assert_eq!(early, Err(Ok(Error::TimelockNotExpired)));

    env.ledger().set_timestamp(T0 + 3600);
    client.apply_sweep_cap(&owner, &token);
    assert_eq!(client.get_sweep_cap(&token), SWEEP_CAP_UNLIMITED);
}

/// 5.2.1: a cut queued under a 1h delay cannot undo a later raise to 7 days once
/// the hour is up.
#[test]
fn test_delay_raise_rearms_pending_delay_cut() {
    let env = Env::default();
    let (client, owner, _contract_id, _token, _recipient) = funded(&env, 0);

    client.set_withdrawal_delay(&owner, &3600);
    client.queue_withdrawal_delay(&owner, &0);
    env.ledger().set_timestamp(T0 + 600);
    client.set_withdrawal_delay(&owner, &(7 * SWEEP_WINDOW));

    env.ledger().set_timestamp(T0 + 3600);
    let early = client.try_apply_withdrawal_delay(&owner);
    assert_eq!(early, Err(Ok(Error::TimelockNotExpired)));

    env.ledger().set_timestamp(T0 + 600 + 7 * SWEEP_WINDOW);
    client.apply_withdrawal_delay(&owner);
    assert_eq!(client.get_config().withdrawal_delay, 0);
}

/// 5.2.1: queued withdrawals are re-armed the same way.
#[test]
fn test_delay_raise_rearms_queued_withdrawal() {
    let env = Env::default();
    let (client, owner, _contract_id, token, recipient) = funded(&env, 1_000_000);
    raise_sweep_cap(&client, &owner, &token, SWEEP_CAP_UNLIMITED);

    client.set_withdrawal_delay(&owner, &3600);
    let nonce = client.queue_withdrawal(&owner, &token, &recipient, &500_000);
    env.ledger().set_timestamp(T0 + 600);
    client.set_withdrawal_delay(&owner, &SWEEP_WINDOW);

    env.ledger().set_timestamp(T0 + 3600);
    let early = client.try_execute_withdrawal(&owner, &nonce);
    assert_eq!(early, Err(Ok(Error::TimelockNotExpired)));

    env.ledger().set_timestamp(T0 + 600 + SWEEP_WINDOW);
    client.execute_withdrawal(&owner, &nonce);
    assert_eq!(token::TokenClient::new(&env, &token).balance(&recipient), 500_000);
}

/// Setting the delay to its current value restarts the clock on what is queued.
#[test]
fn test_reasserting_delay_restarts_clock() {
    let env = Env::default();
    let (client, owner, _contract_id, token, _recipient) = funded(&env, 0);

    client.set_withdrawal_delay(&owner, &3600);
    client.queue_sweep_cap(&owner, &token, &100_000);
    env.ledger().set_timestamp(T0 + 1800);
    client.set_withdrawal_delay(&owner, &3600);

    env.ledger().set_timestamp(T0 + 3600);
    let early = client.try_apply_sweep_cap(&owner, &token);
    assert_eq!(early, Err(Ok(Error::TimelockNotExpired)));

    env.ledger().set_timestamp(T0 + 1800 + 3600);
    client.apply_sweep_cap(&owner, &token);
}

/// 5.2.4: the brake cancels a queued raise, in one call.
#[test]
fn test_brake_cancels_queued_raise() {
    let env = Env::default();
    let (client, owner, contract_id, token, _recipient) = funded(&env, 0);
    raise_sweep_cap(&client, &owner, &token, 100_000);
    client.set_withdrawal_delay(&owner, &3600);
    client.queue_sweep_cap(&owner, &token, &SWEEP_CAP_UNLIMITED);

    client.set_sweep_cap(&owner, &token, &0);
    let cancelled = PendingSweepCapCancelled { token: token.clone() }.to_xdr(&env, &contract_id);
    assert!(env.events().all().events().contains(&cancelled));

    env.ledger().set_timestamp(T0 + 3600);
    let gone = client.try_apply_sweep_cap(&owner, &token);
    assert_eq!(gone, Err(Ok(Error::NoPendingChange)));
    assert_eq!(client.get_sweep_cap(&token), 0);
}

/// Pays one default merchant quote (1_000_000, of which 10_000 is fee) into a
/// fresh contract with an unlimited cap.
fn with_fees(env: &Env) -> (TakumiPayClient<'_>, Address, Address, Address, Address) {
    let (client, owner, contract_id, backend_key) = setup(env);
    let token = setup_token(env, &owner);
    let payer = Address::generate(env);
    let recipient = Address::generate(env);
    mint(env, &token, &payer, 1_000_000);
    client.add_allowed_payment_token(&owner, &token);
    let quote = default_quote(env, &token, "fee-ledger", env.ledger().timestamp() + 1000);
    let sig = sign_quote(env, &contract_id, &backend_key, &quote);
    client.process_merchant_payment(&payer, &quote, &sig);
    raise_sweep_cap(&client, &owner, &token, SWEEP_CAP_UNLIMITED);
    (client, owner, contract_id, token, recipient)
}

/// 5.2.5b: the backing sweep cannot take the balance behind accrued fees.
#[test]
fn test_merchant_backing_reserves_accrued_fees() {
    let env = Env::default();
    let (client, owner, contract_id, token, recipient) = with_fees(&env);

    let over = client.try_sweep_merchant_backing(&owner, &token, &recipient, &1_000_000);
    assert_eq!(over, Err(Ok(Error::InsufficientBalance)));

    client.sweep_merchant_backing(&owner, &token, &recipient, &990_000);
    client.sweep_platform_fees(&owner, &token, &recipient, &10_000);
    assert_eq!(token::TokenClient::new(&env, &token).balance(&contract_id), 0);
}

/// 5.2.5a/c: a withdrawal that takes fee-backed balance books those fees as
/// swept to its recipient, so the ledger never claims fees that already left.
#[test]
fn test_withdraw_books_the_fees_it_took_as_swept() {
    let env = Env::default();
    let (client, owner, contract_id, token, recipient) = with_fees(&env);

    client.withdraw(&owner, &token, &recipient, &995_000);
    // events().all() covers only the last invocation, so check before reading.
    let swept = PlatformFeesSwept {
        token: token.clone(),
        recipient: recipient.clone(),
        amount: 5_000,
    }
    .to_xdr(&env, &contract_id);
    assert!(env.events().all().events().contains(&swept));
    assert_eq!(client.get_platform_fee_accrued(&token), 5_000);

    client.withdraw(&owner, &token, &recipient, &5_000);
    assert_eq!(client.get_platform_fee_accrued(&token), 0);
}

#[test]
fn test_withdraw_above_fees_leaves_ledger_alone() {
    let env = Env::default();
    let (client, owner, _contract_id, token, recipient) = with_fees(&env);

    client.withdraw(&owner, &token, &recipient, &990_000);
    assert_eq!(client.get_platform_fee_accrued(&token), 10_000);
    client.sweep_platform_fees(&owner, &token, &recipient, &10_000);
}

#[test]
fn test_execute_withdrawal_keeps_fee_ledger_backed() {
    let env = Env::default();
    let (client, owner, _contract_id, token, recipient) = with_fees(&env);

    client.set_withdrawal_delay(&owner, &3600);
    let nonce = client.queue_withdrawal(&owner, &token, &recipient, &1_000_000);
    env.ledger().set_timestamp(env.ledger().timestamp() + 3600);
    client.execute_withdrawal(&owner, &nonce);
    assert_eq!(client.get_platform_fee_accrued(&token), 0);
}
