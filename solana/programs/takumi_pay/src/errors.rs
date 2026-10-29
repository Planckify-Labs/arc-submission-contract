use anchor_lang::prelude::*;

#[error_code]
pub enum TakumiPayError {
    #[msg("Not the contract owner")]
    NotOwner,
    #[msg("Not an admin or owner")]
    NotAdminOrOwner,
    #[msg("Contract is paused")]
    ContractPaused,
    #[msg("Point deposits are paused")]
    PointDepositsPaused,
    #[msg("Zero address not allowed")]
    ZeroAddress,
    #[msg("Amount must be greater than zero")]
    ZeroAmount,
    #[msg("Already the owner")]
    AlreadyOwner,
    #[msg("Not the pending owner")]
    NotPendingOwner,
    #[msg("No pending ownership transfer")]
    NoPendingTransfer,
    #[msg("Quote has expired")]
    QuoteExpired,
    #[msg("Reference ID already consumed")]
    RefConsumed,
    #[msg("Invalid quote signature")]
    BadQuote,
    #[msg("Platform fee exceeds payment amount")]
    FeeExceedsAmount,
    #[msg("Fee amount invalid")]
    FeeAmountInvalid,
    #[msg("Backend signer cannot be zero")]
    ZeroSigner,
    #[msg("Recipient cannot be zero")]
    ZeroRecipient,
    #[msg("Amount exceeds spending limit")]
    AmountExceedsLimit,
    #[msg("Timelock is active, use queue/execute")]
    TimelockActive,
    #[msg("Insufficient balance")]
    InsufficientBalance,
    #[msg("Withdrawal delay exceeds maximum")]
    DelayExceedsMax,
    #[msg("Withdrawal delay must be set before queuing")]
    NoDelaySet,
    #[msg("Withdrawal timelock not yet expired")]
    TimelockNotExpired,
    #[msg("Withdrawal already executed")]
    AlreadyExecuted,
    #[msg("Withdrawal already cancelled")]
    AlreadyCancelled,
    #[msg("Token not allowed for point deposits")]
    TokenNotAllowed,
    #[msg("Invalid string length")]
    InvalidStringLength,
    #[msg("Ref ID hash mismatch")]
    InvalidRefIdHash,
    #[msg("Missing Ed25519 signature instruction")]
    MissingEd25519Instruction,
    #[msg("Invalid Ed25519 instruction data")]
    InvalidEd25519Instruction,
    #[msg("Withdrawal type mismatch")]
    WithdrawalTypeMismatch,
    #[msg("Arithmetic overflow")]
    Overflow,
    #[msg("Sweep cap not set for this token — sweeps fail closed until configured")]
    SweepCapNotSet,
    #[msg("Sweep would exceed the per-window cap")]
    SweepCapExceeded,
    #[msg("Not a tightening — loosening a control must be queued")]
    NotALoosening,
    #[msg("No pending change queued")]
    NoPendingChange,
    #[msg("Pending change is still timelocked")]
    PendingChangeLocked,
    #[msg("Sixteen capped exits already left this token in the last 24 hours")]
    SweepLogFull,
    #[msg("Account is already at the current layout")]
    AlreadyMigrated,
}
