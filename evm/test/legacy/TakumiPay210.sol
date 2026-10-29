// Verbatim copy of src/TakumiPay.sol at commit 6dcc1c8 — the 2.1.0 implementation every
// live proxy runs (see deployments/*.json) — with only the contract renamed to TakumiPay210.
// TakumiPayUpgrade.t.sol upgrades from it, so the upgrade path is tested without a fork.
// Do not edit: it must stay byte-for-byte the deployed logic.
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title TakumiPay
/// @notice Payment contract supporting ERC20 + native token transactions, merchant
///         payments against backend-signed EIP-712 quotes, and point deposits.
///         Deployed behind a UUPS proxy for upgradeability.
/// @dev Storage layout must never be reordered between upgrades. Append new slots only.
///      Storage gap __gap reserves 50 slots for future extensions.
///
///      Every OpenZeppelin base here (Initializable, UUPSUpgradeable,
///      ReentrancyGuardUpgradeable, EIP712Upgradeable) uses ERC-7201 namespaced
///      storage, so none of them consume sequential slots — this contract's state
///      starts at slot 0.
contract TakumiPay210 is Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable, EIP712Upgradeable {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // ====== Roles ======

    address public owner;
    address public pendingOwner; // two-step ownership transfer
    mapping(address => bool) private admins;
    address[] private adminList;
    mapping(address => uint256) private adminListIndex; // 1-based index for O(1) removal

    // ====== Global Pause ======

    bool public paused;

    // ====== Spending Limits ======

    mapping(address => uint256) public maxTransactionAmount; // token => max amount (0 = no limit)

    // ====== Withdrawal Timelock ======

    uint256 public withdrawalDelay;
    uint256 public constant MAX_WITHDRAWAL_DELAY = 7 days;
    uint256 private withdrawalNonce;

    // ====== Input Validation ======

    /// @dev Mirrors MAX_STRING_LEN on the Stellar and Solana sibling contracts.
    uint256 public constant MAX_STRING_LENGTH = 64;
    uint256 public constant MAX_PAGINATION_LIMIT = 500;

    struct WithdrawalRequest {
        address token;
        address to;
        uint256 amount;
        uint256 unlockTime;
        bool executed;
        bool cancelled;
    }

    mapping(bytes32 => WithdrawalRequest) public withdrawalRequests;

    // ====== Transactions ======

    uint256 public txCounter;

    struct Transaction {
        address walletAddress;
        address tokenAddress; // address(0) = native token (ETH, MATIC, etc.)
        string bookingId;
        uint256 exchangeRateId;
        string productVariantId;
        uint256 timestamp;
        string refId;
        uint256 amount;
    }

    struct TransactionParams {
        string bookingId;
        uint256 exchangeRateId;
        string productVariantId;
        address tokenAddress;
        string refId;
        uint256 amount;
    }

    mapping(uint256 => Transaction) public transactions;
    mapping(address => uint256[]) private userTransactions;
    mapping(string => uint256) private refToTx;

    // ====== Point Deposits ======

    uint256 public pointDepositCounter;

    struct PointDeposit {
        address walletAddress;
        address tokenAddress;
        uint256 amount;
        string refId;
        uint256 timestamp;
    }

    mapping(uint256 => PointDeposit) public pointDeposits;
    mapping(string => uint256) private pointRefToDeposit;
    mapping(address => uint256[]) private userPointDeposits;

    // ====== Payment Token Allowlist ======
    // A single allowlist gates every entrypoint that moves value in:
    // createTransaction, createTransactionBatch, processMerchantPayment and
    // depositPoints. Native (address(0)) is allowlisted explicitly like any
    // other token — there is no implicit bypass.

    mapping(address => bool) public allowedPaymentTokens;
    address[] private allowedPaymentTokenList;
    mapping(address => uint256) private allowedPaymentTokenListIndex; // 1-based index for O(1) removal
    bool public pointDepositsPaused;

    // ====== Merchant Payments ======

    struct QuoteCommitment {
        string  refId;
        string  merchantId;
        address tokenAddress;
        uint256 amount;
        uint256 platformFeeAmount;
        uint256 fiatAmountMinor;
        bytes3  fiatCurrency;
        uint256 exchangeRateId;
        uint256 expiresAt;
    }

    struct MerchantPayment {
        address payer;
        address tokenAddress;
        string  merchantId;
        string  refId;
        uint256 amount;
        uint256 platformFeeAmount;
        uint256 fiatAmountMinor;
        bytes3  fiatCurrency;
        uint256 exchangeRateId;
        uint256 timestamp;
    }

    address public backendSigner;
    mapping(bytes32 => bool) private _consumedRefs;
    mapping(bytes32 => MerchantPayment) private _payments;
    mapping(address => uint256) public platformFeeAccrued;

    // ====== Sweep Rate Limit ======
    // Treasury sweeps deliberately bypass the withdrawal timelock — merchant float
    // has to settle daily, and a 7-day queue would break that. A per-token rolling
    // cap gives back the property the timelock was there for: an owner key that
    // leaks can only drain `sweepCap` per window, and every window is visible
    // on-chain, instead of emptying the contract in one transaction.

    uint256 public constant SWEEP_WINDOW = 1 days;
    /// @dev Sentinel meaning "no cap". Set explicitly — it is not the default.
    uint256 public constant SWEEP_CAP_UNLIMITED = type(uint256).max;

    /// @dev token => max sweepable per window. 0 (the default) blocks sweeps
    ///      entirely. Unlike `maxTransactionAmount`, where 0 means "no limit",
    ///      this is a security control, so an unconfigured value must fail closed.
    mapping(address => uint256) public sweepCap;
    mapping(address => uint256) public sweptInWindow;
    mapping(address => uint256) public sweepWindowStart;

    // ====== Pending Security-Loosening Changes ======
    // Raising a cap or lowering the withdrawal delay weakens a control, so it is
    // itself subject to `withdrawalDelay`. Without this the timelock is decorative:
    // an attacker holding the owner key would just call setWithdrawalDelay(0) and
    // withdraw in the same transaction. Tightening is always immediate.

    struct PendingChange {
        uint256 value;
        uint256 unlockTime;
    }

    mapping(bytes32 => PendingChange) private _pendingChanges;

    // ====== Native Alias Chains ======
    // On most chains the native coin and every ERC-20 are disjoint pools of money,
    // so keying balances and limits by token address is sound. On a stablecoin-native
    // chain like Arc that assumption breaks: the native coin (18 decimals, msg.value)
    // and the USDC ERC-20 (6 decimals) are two views of ONE balance. Keying by address
    // would then split one pot across two ledgers in two unit scales — doubling every
    // sweep cap and desyncing platformFeeAccrued.
    //
    // Setting nativeAliasToken to that ERC-20 declares "address(0) is an alias of this
    // token on this chain" and shuts the native path off entirely: it can no longer be
    // allowlisted for payments, withdrawn, swept or recovered. Nothing becomes
    // unreachable, because the ERC-20 view addresses the same balance in the 6-decimal
    // units the rest of the system already speaks.
    //
    // Left at address(0) — the default, and the case on every other chain — nothing
    // changes and native payments behave exactly as before.

    /// @dev address(0) means "native is its own asset" (normal EVM chains).
    address public nativeAliasToken;

    // ====== Storage Gap ======
    // Reserve slots for future upgrades. Decrement when adding new state variables.

    uint256[45] private __gap;

    // ====== EIP-712 ======

    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "QuoteCommitment(string refId,string merchantId,address tokenAddress,"
        "uint256 amount,uint256 platformFeeAmount,uint256 fiatAmountMinor,"
        "bytes3 fiatCurrency,uint256 exchangeRateId,uint256 expiresAt)"
    );

    // ====== Events ======

    event TransactionCreated(
        uint256 indexed txId,
        address indexed walletAddress,
        address indexed tokenAddress,
        string bookingId,
        uint256 exchangeRateId,
        string productVariantId,
        uint256 timestamp,
        string refId,
        uint256 amount
    );
    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);
    event Withdraw(address indexed to, address indexed token, uint256 amount);
    event NativeDeposit(address indexed from, uint256 amount);
    event ContractPausedToggled(bool paused);
    event MaxTransactionAmountUpdated(address indexed token, uint256 amount);
    event WithdrawalQueued(
        bytes32 indexed withdrawalId,
        address indexed token,
        address indexed to,
        uint256 amount,
        uint256 unlockTime
    );
    event WithdrawalExecuted(bytes32 indexed withdrawalId);
    event WithdrawalCancelled(bytes32 indexed withdrawalId);
    event WithdrawalDelayUpdated(uint256 delay);
    event SweepCapUpdated(address indexed token, uint256 cap);
    event PendingChangeQueued(bytes32 indexed key, uint256 value, uint256 unlockTime);
    event PendingChangeCancelled(bytes32 indexed key);
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);
    event PointDepositCreated(
        uint256 indexed depositId,
        address indexed walletAddress,
        address indexed tokenAddress,
        string refId,
        uint256 amount,
        uint256 timestamp
    );
    event AllowedPaymentTokenAdded(address indexed token);
    event AllowedPaymentTokenRemoved(address indexed token);
    event PointDepositsPausedToggled(bool paused);
    event OwnershipTransferInitiated(address indexed currentOwner, address indexed pendingOwner);
    event OwnershipTransferCancelled(address indexed cancelledPendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event NativeAliasTokenSet(address indexed token);

    /// @notice Emitted on every successful merchant payment.
    /// @dev `refIdHash` / `merchantIdHash` are indexed, so Solidity stores only the
    ///      keccak256 of the value in the topic — filterable but unreadable. The
    ///      non-indexed `refId` / `merchantId` carry the readable values in data so
    ///      log indexers and subgraphs can consume them.
    event MerchantPaymentProcessed(
        string  indexed refIdHash,
        string  indexed merchantIdHash,
        address indexed payer,
        string  refId,
        string  merchantId,
        address tokenAddress,
        uint256 amount,
        uint256 platformFeeAmount,
        uint256 fiatAmountMinor,
        uint256 exchangeRateId
    );
    event PlatformFeesSwept(address indexed token, address indexed recipient, uint256 amount);
    event MerchantBackingSwept(address indexed token, address indexed recipient, uint256 amount);
    event BackendSignerRotated(address indexed previous, address indexed next);

    // ====== Errors ======

    error NotOwner();
    error NotAdminOrOwner();
    error ContractPaused();
    error PointDepositsPaused();
    error ZeroAddress();
    error ZeroAmount();
    error AlreadyOwner();
    error NotPendingOwner();
    error TimelockActive();
    error TokenNotAllowed();
    error InvalidStringLength();
    error InsufficientBalance();
    error QuoteExpired();
    error RefConsumed();
    error BadQuote();
    error FeeExceedsAmount();
    error FeeAmountInvalid();
    error PaymentNotFound();
    error ZeroSigner();
    error ZeroRecipient();
    error SweepCapNotSet();
    error SweepCapExceeded();
    error NotALoosening();
    error NoPendingChange();
    error TimelockNotExpired();
    error NativeAmountMismatch();
    error UnexpectedNative();
    error NativeTransferFailed();
    error NativeAliasAlreadySet();
    error NativeAliasNotAllowlistable();
    error NativeDisabledOnAliasChain();

    // ====== Modifiers ======

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyAdminOrOwner() {
        if (msg.sender != owner && !admins[msg.sender]) revert NotAdminOrOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier whenPointDepositsActive() {
        if (pointDepositsPaused) revert PointDepositsPaused();
        _;
    }

    // ====== Constructor / Initializer ======

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the proxy. Must be called exactly once after deployment.
    /// @param initialOwner Address that will own the contract.
    /// @param initialBackendSigner Address of the backend signer that produces EIP-712 quote signatures.
    function initialize(address initialOwner, address initialBackendSigner) external initializer {
        if (initialOwner == address(0)) revert ZeroAddress();
        if (initialBackendSigner == address(0)) revert ZeroSigner();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __EIP712_init("TakumiPay", "1");
        owner = initialOwner;
        backendSigner = initialBackendSigner;
    }

    // ====== UUPS Upgrade Authorization ======

    /// @dev Only the owner may authorize an implementation upgrade.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Returns the current implementation version string.
    function version() external pure returns (string memory) {
        return "2.1.0";
    }

    /// @notice Returns the EIP-712 domain separator used for quote verification.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ====== Ownership Transfer (two-step pattern) ======
    // Prevents permanently losing the contract to a wrong address.

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        if (newOwner == owner) revert AlreadyOwner();
        pendingOwner = newOwner;
        emit OwnershipTransferInitiated(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previousOwner = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(previousOwner, owner);
    }

    function cancelOwnershipTransfer() external onlyOwner {
        address cancelled = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferCancelled(cancelled);
    }

    // ====== Global Pause ======

    function setPaused(bool _paused) external onlyAdminOrOwner {
        paused = _paused;
        emit ContractPausedToggled(_paused);
    }

    // ====== Spending Limits ======

    function setMaxTransactionAmount(address token, uint256 amount) external onlyOwner {
        maxTransactionAmount[token] = amount;
        emit MaxTransactionAmountUpdated(token, amount);
    }

    // ====== Create Transaction (supports ERC20 + Native) ======

    function createTransaction(
        string calldata bookingId,
        uint256 exchangeRateId,
        string calldata productVariantId,
        address tokenAddress,
        string calldata refId,
        uint256 amount
    ) external payable whenNotPaused nonReentrant {
        _validateStrings(bookingId, productVariantId, refId);
        if (!allowedPaymentTokens[tokenAddress]) revert TokenNotAllowed();
        if (tokenAddress == address(0)) {
            require(msg.value == amount, "Incorrect amount sent");
        } else {
            require(msg.value == 0, "ETH not required for ERC20");
            _pullToken(tokenAddress, msg.sender, amount);
        }
        _recordTransaction(msg.sender, bookingId, exchangeRateId, productVariantId, tokenAddress, refId, amount);
    }

    // ====== Batch Transaction Creation ======

    function createTransactionBatch(TransactionParams[] calldata params) external payable whenNotPaused nonReentrant {
        uint256 len = params.length;
        require(len > 0, "Empty batch");
        require(len <= 20, "Batch too large");

        // Phase 1: Validate all params and compute expected ETH total
        uint256 totalNative = 0;
        for (uint256 i = 0; i < len; i++) {
            require(params[i].amount > 0, "Amount must be greater than 0");
            _validateStrings(params[i].bookingId, params[i].productVariantId, params[i].refId);

            if (!allowedPaymentTokens[params[i].tokenAddress]) revert TokenNotAllowed();

            // Check existing refIds before any transfers
            require(refToTx[params[i].refId] == 0, "refId must be unique");

            if (params[i].tokenAddress == address(0)) {
                totalNative += params[i].amount;
            }

            // Check spending limits upfront
            uint256 maxAmt = maxTransactionAmount[params[i].tokenAddress];
            if (maxAmt > 0) {
                require(params[i].amount <= maxAmt, "Amount exceeds spending limit");
            }
        }
        require(msg.value == totalNative, "Incorrect ETH amount for batch");

        // Phase 2: Check intra-batch duplicate refIds (O(n^2), max 20 items = max 190 iterations)
        for (uint256 i = 0; i < len; i++) {
            for (uint256 j = i + 1; j < len; j++) {
                require(
                    keccak256(bytes(params[i].refId)) != keccak256(bytes(params[j].refId)),
                    "Duplicate refId in batch"
                );
            }
        }

        // Phase 3: Execute all ERC20 transfers
        for (uint256 i = 0; i < len; i++) {
            if (params[i].tokenAddress != address(0)) {
                _pullToken(params[i].tokenAddress, msg.sender, params[i].amount);
            }
        }

        // Phase 4: Record all transactions (state updates after all external calls)
        for (uint256 i = 0; i < len; i++) {
            TransactionParams calldata p = params[i];
            _recordTransactionUnchecked(msg.sender, p.bookingId, p.exchangeRateId, p.productVariantId, p.tokenAddress, p.refId, p.amount);
        }
    }

    function _recordTransaction(
        address sender,
        string calldata bookingId,
        uint256 exchangeRateId,
        string calldata productVariantId,
        address tokenAddress,
        string calldata refId,
        uint256 amount
    ) internal {
        require(refToTx[refId] == 0, "refId must be unique");
        require(amount > 0, "Amount must be greater than 0");

        uint256 maxAmt = maxTransactionAmount[tokenAddress];
        if (maxAmt > 0) {
            require(amount <= maxAmt, "Amount exceeds spending limit");
        }

        _recordTransactionUnchecked(sender, bookingId, exchangeRateId, productVariantId, tokenAddress, refId, amount);
    }

    // Internal writer — assumes all validation already done (used by batch after pre-validation)
    function _recordTransactionUnchecked(
        address sender,
        string calldata bookingId,
        uint256 exchangeRateId,
        string calldata productVariantId,
        address tokenAddress,
        string calldata refId,
        uint256 amount
    ) internal {
        txCounter += 1;
        transactions[txCounter] = Transaction({
            walletAddress: sender,
            tokenAddress: tokenAddress,
            bookingId: bookingId,
            exchangeRateId: exchangeRateId,
            productVariantId: productVariantId,
            timestamp: block.timestamp,
            refId: refId,
            amount: amount
        });

        userTransactions[sender].push(txCounter);
        refToTx[refId] = txCounter;

        emit TransactionCreated(
            txCounter,
            sender,
            tokenAddress,
            bookingId,
            exchangeRateId,
            productVariantId,
            block.timestamp,
            refId,
            amount
        );
    }

    // ====== Merchant Payments ======

    /// @notice Processes a merchant payment using a backend-signed EIP-712 quote.
    /// @param quote The QuoteCommitment struct with payment details.
    /// @param backendSignature The EIP-712 signature produced by backendSigner.
    function processMerchantPayment(
        QuoteCommitment calldata quote,
        bytes calldata backendSignature
    ) external payable whenNotPaused nonReentrant {
        // Cheap validations first, so a malformed quote never pays for an ECDSA recover.
        if (quote.amount == 0) revert ZeroAmount();
        if (quote.platformFeeAmount > quote.amount) revert FeeExceedsAmount();
        if (!_isValidString(quote.refId) || !_isValidString(quote.merchantId)) {
            revert InvalidStringLength();
        }
        if (block.timestamp > quote.expiresAt) revert QuoteExpired();
        if (!allowedPaymentTokens[quote.tokenAddress]) revert TokenNotAllowed();

        bytes32 refKey = keccak256(bytes(quote.refId));
        if (_consumedRefs[refKey]) revert RefConsumed();

        bytes32 structHash = keccak256(abi.encode(
            QUOTE_TYPEHASH,
            keccak256(bytes(quote.refId)),
            keccak256(bytes(quote.merchantId)),
            quote.tokenAddress,
            quote.amount,
            quote.platformFeeAmount,
            quote.fiatAmountMinor,
            quote.fiatCurrency,
            quote.exchangeRateId,
            quote.expiresAt
        ));
        bytes32 digest = _hashTypedDataV4(structHash);
        if (ECDSA.recover(digest, backendSignature) != backendSigner) revert BadQuote();

        if (quote.tokenAddress == address(0)) {
            if (msg.value != quote.amount) revert NativeAmountMismatch();
        } else {
            if (msg.value != 0) revert UnexpectedNative();
            _pullToken(quote.tokenAddress, msg.sender, quote.amount);
        }

        _consumedRefs[refKey] = true;
        _payments[refKey] = MerchantPayment({
            payer:             msg.sender,
            tokenAddress:      quote.tokenAddress,
            merchantId:        quote.merchantId,
            refId:             quote.refId,
            amount:            quote.amount,
            platformFeeAmount: quote.platformFeeAmount,
            fiatAmountMinor:   quote.fiatAmountMinor,
            fiatCurrency:      quote.fiatCurrency,
            exchangeRateId:    quote.exchangeRateId,
            timestamp:         block.timestamp
        });
        platformFeeAccrued[quote.tokenAddress] += quote.platformFeeAmount;

        emit MerchantPaymentProcessed(
            quote.refId,
            quote.merchantId,
            msg.sender,
            quote.refId,
            quote.merchantId,
            quote.tokenAddress,
            quote.amount,
            quote.platformFeeAmount,
            quote.fiatAmountMinor,
            quote.exchangeRateId
        );
    }

    /// @notice Returns the MerchantPayment record for a given refId.
    /// @dev Reverts when the ref was never paid, matching getTransactionByRef.
    function getMerchantPaymentByRef(string calldata refId)
        external view returns (MerchantPayment memory)
    {
        MerchantPayment memory payment = _payments[keccak256(bytes(refId))];
        if (payment.payer == address(0)) revert PaymentNotFound();
        return payment;
    }

    // ====== Treasury ======

    /// @notice Sweeps platform fees (bounded by accrued amount) to a recipient.
    function sweepPlatformFees(address token, address recipient, uint256 amount)
        external onlyOwner nonReentrant
    {
        if (amount == 0 || amount > platformFeeAccrued[token]) revert FeeAmountInvalid();
        _consumeSweepAllowance(token, amount);
        platformFeeAccrued[token] -= amount;
        _transferOutMerchant(token, recipient, amount);
        emit PlatformFeesSwept(token, recipient, amount);
    }

    /// @notice Sweeps merchant backing funds to a recipient (unbounded by fee accrual —
    ///         this is the float backing merchant payouts), subject to the per-window
    ///         sweep cap.
    function sweepMerchantBacking(address token, address recipient, uint256 amount)
        external onlyOwner nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        uint256 balance = token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
        if (amount > balance) revert InsufficientBalance();
        _consumeSweepAllowance(token, amount);
        _transferOutMerchant(token, recipient, amount);
        emit MerchantBackingSwept(token, recipient, amount);
    }

    /// @dev Charges `amount` against the token's rolling per-window sweep allowance.
    ///      An unset cap fails closed.
    function _consumeSweepAllowance(address token, uint256 amount) private {
        _rejectAliasedNative(token);
        uint256 cap = sweepCap[token];
        if (cap == 0) revert SweepCapNotSet();
        if (cap == SWEEP_CAP_UNLIMITED) return;

        uint256 swept = sweptInWindow[token];
        if (block.timestamp >= sweepWindowStart[token] + SWEEP_WINDOW) {
            sweepWindowStart[token] = block.timestamp;
            swept = 0;
        }
        if (swept + amount > cap) revert SweepCapExceeded();
        sweptInWindow[token] = swept + amount;
    }

    // ====== Signer Rotation ======

    /// @notice Rotates the backend signer address. Only callable by owner.
    function rotateBackendSigner(address next) external onlyOwner {
        if (next == address(0)) revert ZeroSigner();
        emit BackendSignerRotated(backendSigner, next);
        backendSigner = next;
    }

    // ====== Withdrawals (ERC20 + Native) ======
    // Note: withdraw/withdrawAll bypass the timelock and are only permitted when
    // withdrawalDelay == 0. When a timelock is configured, use queueWithdrawal +
    // executeWithdrawal for all withdrawals.
    //
    // All of them are additionally bounded by the per-token sweep cap, so raising the
    // amount that can leave the contract in one window always costs a queueSweepCap
    // delay first — including on the timelocked path.

    function withdraw(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (withdrawalDelay > 0) revert TimelockActive();
        _doWithdraw(token, to, amount);
    }

    /// @notice Withdraws the full balance of `token`.
    /// @dev Like every other exit, this now charges the sweep allowance — so it reverts
    ///      with SweepCapExceeded when the balance is larger than what is left in the
    ///      current window. Use `withdraw` for a partial amount in that case.
    function withdrawAll(address token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (withdrawalDelay > 0) revert TimelockActive();
        uint256 balance = token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
        require(balance > 0, "No balance");
        _doWithdraw(token, to, balance);
    }

    /// @dev Every owner-initiated withdrawal funnels through here, and every one of
    ///      them charges the token's rolling sweep allowance. Previously only
    ///      sweepPlatformFees/sweepMerchantBacking were rate-limited, which left
    ///      withdraw/withdrawAll/executeWithdrawal as an uncapped way out of the
    ///      contract — the cap is only a cap if no path skips it.
    function _doWithdraw(address token, address to, uint256 amount) internal {
        _consumeSweepAllowance(token, amount);
        _sendOut(token, to, amount);
        emit Withdraw(to, token, amount);
    }

    // ====== Withdrawal Timelock ======

    bytes32 private constant WITHDRAWAL_DELAY_KEY = keccak256("withdrawalDelay");

    /// @notice Raises the withdrawal delay. Takes effect immediately — tightening a
    ///         control is always safe.
    /// @dev Lowering must go through queueWithdrawalDelay/applyPendingChange so the
    ///      reduction is itself subject to the delay currently in force.
    function setWithdrawalDelay(uint256 delay) external onlyOwner {
        require(delay <= MAX_WITHDRAWAL_DELAY, "Delay exceeds maximum");
        if (delay < withdrawalDelay) revert NotALoosening();
        withdrawalDelay = delay;
        emit WithdrawalDelayUpdated(delay);
    }

    /// @notice Queues a reduction of the withdrawal delay. Callable only to lower it;
    ///         use setWithdrawalDelay to raise.
    function queueWithdrawalDelay(uint256 delay) external onlyOwner {
        if (delay >= withdrawalDelay) revert NotALoosening();
        _queueLoosening(WITHDRAWAL_DELAY_KEY, delay);
    }

    function applyWithdrawalDelay() external onlyOwner {
        withdrawalDelay = _consumePending(WITHDRAWAL_DELAY_KEY);
        emit WithdrawalDelayUpdated(withdrawalDelay);
    }

    // ====== Sweep Cap ======

    function _sweepCapKey(address token) private pure returns (bytes32) {
        return keccak256(abi.encode("sweepCap", token));
    }

    /// @notice Lowers (tightens) a token's sweep cap. Immediate.
    /// @dev Raising must go through queueSweepCap — otherwise the rate limit would be
    ///      one call away from being defeated, the same way an ungated
    ///      setWithdrawalDelay defeats the timelock.
    function setSweepCap(address token, uint256 cap) external onlyOwner {
        if (cap > sweepCap[token]) revert NotALoosening();
        sweepCap[token] = cap;
        emit SweepCapUpdated(token, cap);
    }

    function queueSweepCap(address token, uint256 cap) external onlyOwner {
        if (cap <= sweepCap[token]) revert NotALoosening();
        _queueLoosening(_sweepCapKey(token), cap);
    }

    function applySweepCap(address token) external onlyOwner {
        uint256 cap = _consumePending(_sweepCapKey(token));
        sweepCap[token] = cap;
        emit SweepCapUpdated(token, cap);
    }

    function cancelPendingChange(bytes32 key) external onlyOwner {
        if (_pendingChanges[key].unlockTime == 0) revert NoPendingChange();
        delete _pendingChanges[key];
        emit PendingChangeCancelled(key);
    }

    function getPendingChange(bytes32 key) external view returns (PendingChange memory) {
        return _pendingChanges[key];
    }

    /// @dev Records a security-loosening change, unlockable after the delay currently
    ///      in force. Always two-step, even when withdrawalDelay is 0 — the queue/apply
    ///      pair then completes in the same block, so callers need no special case for
    ///      whether a delay happens to be configured.
    function _queueLoosening(bytes32 key, uint256 value) private {
        uint256 unlockTime = block.timestamp + withdrawalDelay;
        _pendingChanges[key] = PendingChange({value: value, unlockTime: unlockTime});
        emit PendingChangeQueued(key, value, unlockTime);
    }

    function _consumePending(bytes32 key) private returns (uint256 value) {
        PendingChange memory pending = _pendingChanges[key];
        if (pending.unlockTime == 0) revert NoPendingChange();
        if (block.timestamp < pending.unlockTime) revert TimelockNotExpired();
        value = pending.value;
        delete _pendingChanges[key];
    }

    function queueWithdrawal(address token, address to, uint256 amount) external onlyOwner returns (bytes32) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        // Reject at queue time rather than letting it sit for `withdrawalDelay` and
        // then fail in executeWithdrawal.
        _rejectAliasedNative(token);
        require(withdrawalDelay > 0, "Set a withdrawal delay before queuing");

        withdrawalNonce += 1;
        bytes32 withdrawalId = keccak256(abi.encodePacked(token, to, amount, block.timestamp, withdrawalNonce));
        uint256 unlockTime = block.timestamp + withdrawalDelay;

        withdrawalRequests[withdrawalId] = WithdrawalRequest({
            token: token,
            to: to,
            amount: amount,
            unlockTime: unlockTime,
            executed: false,
            cancelled: false
        });

        emit WithdrawalQueued(withdrawalId, token, to, amount, unlockTime);
        return withdrawalId;
    }

    function executeWithdrawal(bytes32 withdrawalId) external onlyOwner nonReentrant {
        WithdrawalRequest storage req = withdrawalRequests[withdrawalId];
        require(req.unlockTime > 0, "Withdrawal not found");
        require(!req.executed, "Already executed");
        require(!req.cancelled, "Already cancelled");
        require(block.timestamp >= req.unlockTime, "Timelock not expired");

        // Effects before interactions (CEI pattern)
        req.executed = true;
        _doWithdraw(req.token, req.to, req.amount);
        emit WithdrawalExecuted(withdrawalId);
    }

    function cancelWithdrawal(bytes32 withdrawalId) external onlyOwner {
        WithdrawalRequest storage req = withdrawalRequests[withdrawalId];
        require(req.unlockTime > 0, "Withdrawal not found");
        require(!req.executed, "Already executed");
        require(!req.cancelled, "Already cancelled");
        req.cancelled = true;
        emit WithdrawalCancelled(withdrawalId);
    }

    // ====== Token Recovery ======

    function recoverToken(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (withdrawalDelay > 0) revert TimelockActive();
        _consumeSweepAllowance(token, amount);
        _sendOut(token, to, amount);
        emit TokenRecovered(token, to, amount);
    }

    // ====== ETH Direct Deposit Handling ======

    /// @dev Deliberately not nonReentrant. The body only emits, so the guard protects
    ///      nothing, while it would make any native value arriving mid-call revert the
    ///      whole transaction — e.g. a contract counterparty refunding native inside a
    ///      payment. Removing it can only widen what succeeds.
    ///
    ///      Note this is hygiene, not an Arc fix: an ERC-20 USDC transfer on Arc moves
    ///      the underlying balance at state level and does NOT invoke the recipient's
    ///      receive(), verified by eth_call against the live node — a transfer to an
    ///      address whose code unconditionally reverts still succeeds, while a plain
    ///      native send to that same address reverts.
    receive() external payable {
        emit NativeDeposit(msg.sender, msg.value);
    }

    // ====== Admin Management ======

    function addAdmin(address admin) external onlyOwner {
        if (admin == address(0)) revert ZeroAddress();
        require(!admins[admin], "Already admin");
        admins[admin] = true;
        adminList.push(admin);
        adminListIndex[admin] = adminList.length; // 1-based index
        emit AdminAdded(admin);
    }

    function removeAdmin(address admin) external onlyOwner {
        require(admins[admin], "Not an admin");
        require(adminListIndex[admin] > 0, "Admin index inconsistency");
        admins[admin] = false;

        // Swap-and-pop to keep array compact and avoid stale entries
        uint256 idx = adminListIndex[admin] - 1; // convert to 0-based
        uint256 lastIdx = adminList.length - 1;
        if (idx != lastIdx) {
            address last = adminList[lastIdx];
            adminList[idx] = last;
            adminListIndex[last] = idx + 1; // update 1-based index
        }
        adminList.pop();
        delete adminListIndex[admin];

        emit AdminRemoved(admin);
    }

    function getAllAdmins() external view returns (address[] memory) {
        return adminList;
    }

    function isAdmin(address admin) external view returns (bool) {
        return admins[admin];
    }

    // ====== Transaction View Functions ======

    function getUserTransactions(uint256 offset, uint256 limit) external view returns (Transaction[] memory) {
        require(limit <= MAX_PAGINATION_LIMIT, "Limit too large");
        return _paginateTx(userTransactions[msg.sender], offset, limit);
    }

    function getTransactionsByAddress(address user, uint256 offset, uint256 limit)
        external
        view
        returns (Transaction[] memory)
    {
        require(limit <= MAX_PAGINATION_LIMIT, "Limit too large");
        return _paginateTx(userTransactions[user], offset, limit);
    }

    function _paginateTx(uint256[] storage txIds, uint256 offset, uint256 limit)
        internal
        view
        returns (Transaction[] memory)
    {
        uint256 total = txIds.length;
        if (offset >= total) return new Transaction[](0);
        uint256 size = _min(limit, total - offset);
        Transaction[] memory result = new Transaction[](size);
        for (uint256 i = 0; i < size; i++) {
            result[i] = transactions[txIds[offset + i]];
        }
        return result;
    }

    function getTransactionByRef(string calldata refId) external view returns (Transaction memory) {
        uint256 txId = refToTx[refId];
        require(txId != 0, "Transaction not found");
        return transactions[txId];
    }

    function getUserTransactionCount(address user) external view returns (uint256) {
        return userTransactions[user].length;
    }

    // Warning: this function iterates all transactions and should only be called off-chain.
    // Enforce a hard cap on `limit` to prevent excessive memory allocation.
    function getTransactionsInRange(uint256 start, uint256 end, uint256 offset, uint256 limit)
        external
        view
        returns (Transaction[] memory)
    {
        require(limit <= MAX_PAGINATION_LIMIT, "Limit too large");
        require(start <= end, "Invalid range");

        // First pass: count matching transactions to size the temp array
        uint256 count = 0;
        for (uint256 i = 1; i <= txCounter; i++) {
            uint256 ts = transactions[i].timestamp;
            if (ts >= start && ts <= end) {
                count++;
            }
        }

        if (offset >= count) return new Transaction[](0);
        uint256 size = _min(limit, count - offset);
        Transaction[] memory result = new Transaction[](size);

        // Second pass: fill result with pagination
        uint256 matched = 0;
        uint256 filled = 0;
        for (uint256 i = 1; i <= txCounter && filled < size; i++) {
            Transaction memory txData = transactions[i];
            if (txData.timestamp >= start && txData.timestamp <= end) {
                if (matched >= offset) {
                    result[filled] = txData;
                    filled++;
                }
                matched++;
            }
        }

        return result;
    }

    // ====== Point Deposit Functions ======

    function depositPoints(address tokenAddress, string calldata refId, uint256 amount)
        external
        whenNotPaused
        whenPointDepositsActive
        nonReentrant
    {
        if (!allowedPaymentTokens[tokenAddress]) revert TokenNotAllowed();
        require(pointRefToDeposit[refId] == 0, "refId already used");
        require(amount > 0, "Amount must be greater than 0");
        if (!_isValidString(refId)) revert InvalidStringLength();

        _pullToken(tokenAddress, msg.sender, amount);

        pointDepositCounter += 1;
        pointDeposits[pointDepositCounter] = PointDeposit({
            walletAddress: msg.sender,
            tokenAddress: tokenAddress,
            amount: amount,
            refId: refId,
            timestamp: block.timestamp
        });

        userPointDeposits[msg.sender].push(pointDepositCounter);
        pointRefToDeposit[refId] = pointDepositCounter;

        emit PointDepositCreated(pointDepositCounter, msg.sender, tokenAddress, refId, amount, block.timestamp);
    }

    // ====== Point Deposit View Functions ======

    function getPointDepositByRef(string calldata refId)
        external
        view
        returns (PointDeposit memory)
    {
        uint256 depositId = pointRefToDeposit[refId];
        require(depositId != 0, "Point deposit not found");
        return pointDeposits[depositId];
    }

    function getPointDepositsByAddress(address user, uint256 offset, uint256 limit)
        external
        view
        returns (PointDeposit[] memory)
    {
        require(limit <= MAX_PAGINATION_LIMIT, "Limit too large");
        return _paginateDeposit(userPointDeposits[user], offset, limit);
    }

    function getUserPointDeposits(uint256 offset, uint256 limit) external view returns (PointDeposit[] memory) {
        require(limit <= MAX_PAGINATION_LIMIT, "Limit too large");
        return _paginateDeposit(userPointDeposits[msg.sender], offset, limit);
    }

    function getUserPointDepositCount(address user) external view returns (uint256) {
        return userPointDeposits[user].length;
    }

    function _paginateDeposit(uint256[] storage ids, uint256 offset, uint256 limit)
        internal
        view
        returns (PointDeposit[] memory)
    {
        uint256 total = ids.length;
        if (offset >= total) return new PointDeposit[](0);
        uint256 size = _min(limit, total - offset);
        PointDeposit[] memory result = new PointDeposit[](size);
        for (uint256 i = 0; i < size; i++) {
            result[i] = pointDeposits[ids[offset + i]];
        }
        return result;
    }

    // ====== Native Alias Configuration ======

    /// @notice Declares that address(0) and `token` are the same asset on this chain,
    ///         and disables the native path everywhere as a result.
    /// @dev Set-once and non-zero only. This is a property of the chain, not a policy
    ///      knob — it never legitimately changes for a live deployment, and making it
    ///      immutable removes it as a target for a compromised owner key. Correcting a
    ///      genuine mistake requires an implementation upgrade.
    ///
    ///      Setting it only ever tightens (it closes a value path), so it takes effect
    ///      immediately rather than going through `withdrawalDelay`.
    function setNativeAliasToken(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (nativeAliasToken != address(0)) revert NativeAliasAlreadySet();
        // Refuse to create a config where one asset is already allowlisted twice.
        if (allowedPaymentTokens[address(0)]) revert NativeAliasNotAllowlistable();
        nativeAliasToken = token;
        emit NativeAliasTokenSet(token);
    }

    /// @notice True when native is an alias of an ERC-20 on this chain, and therefore
    ///         not usable as a token in its own right.
    function isNativeAliased() public view returns (bool) {
        return nativeAliasToken != address(0);
    }

    /// @dev Rejects the native path once an alias is configured. Guards the allowlist
    ///      and every outbound transfer, so the aliased balance is only ever moved and
    ///      accounted through its ERC-20 view.
    function _rejectAliasedNative(address token) private view {
        if (token == address(0) && nativeAliasToken != address(0)) {
            revert NativeDisabledOnAliasChain();
        }
    }

    // ====== Payment Token Allowlist Management ======

    /// @dev address(0) (native) is a valid allowlist entry — it is gated exactly
    ///      like an ERC-20 rather than bypassing the check. The one exception is an
    ///      alias chain (see nativeAliasToken), where allowlisting both address(0) and
    ///      the aliased ERC-20 would hand the same pot of money two independent sets of
    ///      caps and ledgers.
    function addAllowedPaymentToken(address token) external onlyOwner {
        _rejectAliasedNative(token);
        require(!allowedPaymentTokens[token], "Token already allowed");
        allowedPaymentTokens[token] = true;
        allowedPaymentTokenList.push(token);
        allowedPaymentTokenListIndex[token] = allowedPaymentTokenList.length; // 1-based index
        emit AllowedPaymentTokenAdded(token);
    }

    function removeAllowedPaymentToken(address token) external onlyOwner {
        require(allowedPaymentTokens[token], "Token not in allowlist");
        require(allowedPaymentTokenListIndex[token] > 0, "Token index inconsistency");
        allowedPaymentTokens[token] = false;

        // Swap-and-pop to keep array compact and avoid stale entries
        uint256 idx = allowedPaymentTokenListIndex[token] - 1; // convert to 0-based
        uint256 lastIdx = allowedPaymentTokenList.length - 1;
        if (idx != lastIdx) {
            address last = allowedPaymentTokenList[lastIdx];
            allowedPaymentTokenList[idx] = last;
            allowedPaymentTokenListIndex[last] = idx + 1; // update 1-based index
        }
        allowedPaymentTokenList.pop();
        delete allowedPaymentTokenListIndex[token];

        emit AllowedPaymentTokenRemoved(token);
    }

    function getAllowedPaymentTokens() external view returns (address[] memory) {
        return allowedPaymentTokenList;
    }

    function isAllowedPaymentToken(address token) external view returns (bool) {
        return allowedPaymentTokens[token];
    }

    // ====== Point Deposit Pause Control ======

    function setPointDepositsPaused(bool _paused) external onlyAdminOrOwner {
        pointDepositsPaused = _paused;
        emit PointDepositsPausedToggled(_paused);
    }

    // ====== Helpers ======

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev Pulls `amount` of an ERC20 in and asserts the contract actually received
    ///      it. Fee-on-transfer tokens would otherwise leave the recorded amount and
    ///      the real balance out of sync.
    function _pullToken(address token, address from, uint256 amount) internal {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        require(
            IERC20(token).balanceOf(address(this)) - balanceBefore == amount,
            "Fee-on-transfer tokens not supported"
        );
    }

    function _transferOutMerchant(address token, address recipient, uint256 amount) private {
        if (recipient == address(0)) revert ZeroRecipient();
        _sendOut(token, recipient, amount);
    }

    /// @dev Single chokepoint for every outbound value transfer. On an alias chain the
    ///      native path is closed here: the same balance stays fully reachable through
    ///      nativeAliasToken's ERC-20 view, in the 6-decimal units the caps and ledgers
    ///      are denominated in. Only sub-unit dust (< 1e12 native on Arc, i.e. under a
    ///      millionth of a dollar) is not addressable that way.
    function _sendOut(address token, address to, uint256 amount) private {
        _rejectAliasedNative(token);
        if (token == address(0)) {
            if (address(this).balance < amount) revert InsufficientBalance();
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    function _isValidString(string calldata s) internal pure returns (bool) {
        uint256 len = bytes(s).length;
        return len > 0 && len <= MAX_STRING_LENGTH;
    }

    function _validateStrings(string calldata bookingId, string calldata productVariantId, string calldata refId)
        internal
        pure
    {
        require(_isValidString(bookingId), "Invalid bookingId length");
        require(_isValidString(productVariantId), "Invalid productVariantId length");
        require(_isValidString(refId), "Invalid refId length");
    }
}
