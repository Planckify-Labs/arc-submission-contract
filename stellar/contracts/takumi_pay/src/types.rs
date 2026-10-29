use soroban_sdk::{contracttype, Address, BytesN, String};

/// Mirrors the Solana/EVM sibling contracts' MAX_STRING_LEN — bounds the
/// merchant/booking/ref identifiers so a caller can't grow storage unbounded.
pub const MAX_STRING_LEN: u32 = 64;

/// Mirrors MAX_WITHDRAWAL_DELAY on the Solana and EVM contracts (7 days).
pub const MAX_WITHDRAWAL_DELAY: u64 = 7 * 24 * 60 * 60;

/// Persistent-storage TTL bump applied to every record this contract writes,
/// so ledgers don't archive it out from under us. ~30 days at 5s/ledger.
pub const PERSISTENT_BUMP_TO: u32 = 535_680;
pub const PERSISTENT_BUMP_THRESHOLD: u32 = 518_400;

/// Instance-storage TTL bump for the Config singleton. Same window as above;
/// if this ever lapses the whole contract becomes unreadable.
pub const INSTANCE_BUMP_TO: u32 = 535_680;
pub const INSTANCE_BUMP_THRESHOLD: u32 = 518_400;

#[contracttype]
#[derive(Clone)]
pub enum DataKey {
    /// Singleton config, lives in instance storage.
    Config,
    /// admin address -> marker. Presence in persistent storage == is admin.
    Admin(Address),
    /// token address -> max per-transaction amount (0 / absent = unbounded).
    SpendingLimit(Address),
    /// tx_id -> TransactionRecord.
    TxRecord(u64),
    /// sha256(ref_id) -> replay marker for create_transaction.
    RefRecord(BytesN<32>),
    /// sha256(ref_id) -> MerchantPayment. Presence == quote already consumed.
    MerchantPayment(BytesN<32>),
    /// token address -> accrued platform fee (i128).
    PlatformFee(Address),
    /// deposit_id -> PointDepositRecord.
    PointDeposit(u64),
    /// sha256(ref_id) -> replay marker for deposit_points.
    PointRef(BytesN<32>),
    /// token address -> marker. Presence == allowed for payments and point
    /// deposits (create_transaction + process_merchant_payment + deposit_points).
    AllowedPaymentToken(Address),
    /// nonce -> WithdrawalRequest.
    Withdrawal(u64),
    /// token -> max that may leave in any SWEEP_WINDOW. Absent or 0 blocks every
    /// exit entirely.
    SweepCap(Address),
    /// token -> Vec<SweepExit>: the capped exits made in the trailing
    /// SWEEP_WINDOW, at most SWEEP_LOG_SIZE of them.
    SweepLog(Address),
    /// Ledger timestamp `set_withdrawal_delay` last ran at (instance storage).
    /// Queued loosenings and withdrawals also wait the full current delay from
    /// then, so raising the delay reaches entries queued under a shorter one.
    DelayRaisedAt,
    /// Queued reduction of the withdrawal delay.
    PendingWithdrawalDelay,
    /// token -> queued increase of the sweep cap.
    PendingSweepCap(Address),
}

/// Span the treasury sweep cap holds over (24h).
///
/// Sweeps deliberately bypass the withdrawal timelock — merchant float has to
/// settle daily and a 7-day queue would break that. The cap gives back what the
/// timelock was there for: a leaked owner key can move at most `SweepCap` in any
/// 24 hours, visibly, instead of emptying the contract in one transaction.
pub const SWEEP_WINDOW: u64 = 24 * 60 * 60;

/// Most capped exits one token can make within SWEEP_WINDOW.
pub const SWEEP_LOG_SIZE: u32 = 16;

/// One capped exit, kept in the token's SweepLog until it is SWEEP_WINDOW old.
#[contracttype]
#[derive(Clone)]
pub struct SweepExit {
    pub at: u64,
    pub amount: i128,
}

/// Sentinel meaning "no cap". Must be set explicitly — it is not the default.
pub const SWEEP_CAP_UNLIMITED: i128 = i128::MAX;

/// A queued security-loosening change. Raising a sweep cap or lowering the
/// withdrawal delay weakens a control, so it is itself subject to the delay
/// currently in force — otherwise an owner key that leaks could just set the
/// delay to 0 and withdraw in the same transaction.
#[contracttype]
#[derive(Clone)]
pub struct PendingDelay {
    pub value: u64,
    pub unlock_time: u64,
}

#[contracttype]
#[derive(Clone)]
pub struct PendingCap {
    pub value: i128,
    pub unlock_time: u64,
}

#[contracttype]
#[derive(Clone)]
pub struct Config {
    pub owner: Address,
    pub pending_owner: Option<Address>,
    /// Raw Ed25519 public key of the off-chain backend signer that produces
    /// merchant-quote signatures. Deliberately not a Stellar `Address` — the
    /// backend is a pure signing key, not an on-chain account (same role as
    /// `backendSigner` on EVM and `backend_signer` on Solana).
    pub backend_signer: BytesN<32>,
    pub paused: bool,
    pub point_deposits_paused: bool,
    pub tx_counter: u64,
    pub point_deposit_counter: u64,
    pub withdrawal_delay: u64,
    pub withdrawal_nonce: u64,
}

#[contracttype]
#[derive(Clone)]
pub struct CreateTransactionParams {
    pub booking_id: String,
    pub exchange_rate_id: u64,
    pub product_variant_id: String,
    pub ref_id: String,
    pub token: Address,
    pub amount: i128,
}

#[contracttype]
#[derive(Clone)]
pub struct TransactionRecord {
    pub tx_id: u64,
    pub wallet_address: Address,
    pub token: Address,
    pub booking_id: String,
    pub exchange_rate_id: u64,
    pub product_variant_id: String,
    pub ref_id: String,
    pub amount: i128,
    pub timestamp: u64,
}

/// The backend-signed quote a payer submits to `process_merchant_payment`.
/// Signed as part of `QuoteMessage` (see merchant.rs) so the signature binds
/// to this network and this contract instance — the Soroban analogue of an
/// EIP-712 domain separator.
#[contracttype]
#[derive(Clone)]
pub struct MerchantQuote {
    pub ref_id: String,
    pub merchant_id: String,
    pub token: Address,
    pub amount: i128,
    pub platform_fee_amount: i128,
    pub fiat_amount_minor: u64,
    pub fiat_currency: BytesN<3>,
    pub exchange_rate_id: u64,
    pub expires_at: u64,
}

#[contracttype]
#[derive(Clone)]
pub struct MerchantPayment {
    pub payer: Address,
    pub token: Address,
    pub merchant_id: String,
    pub ref_id: String,
    pub amount: i128,
    pub platform_fee_amount: i128,
    pub fiat_amount_minor: u64,
    pub fiat_currency: BytesN<3>,
    pub exchange_rate_id: u64,
    pub timestamp: u64,
}

#[contracttype]
#[derive(Clone)]
pub struct PointDepositRecord {
    pub deposit_id: u64,
    pub wallet_address: Address,
    pub token: Address,
    pub amount: i128,
    pub ref_id: String,
    pub timestamp: u64,
}

#[contracttype]
#[derive(Clone)]
pub struct WithdrawalRequest {
    pub token: Address,
    pub recipient: Address,
    pub amount: i128,
    pub unlock_time: u64,
    pub executed: bool,
    pub cancelled: bool,
    pub nonce: u64,
}

pub fn validate_string_len(s: &String) -> bool {
    let len = s.len();
    len > 0 && len <= MAX_STRING_LEN
}
