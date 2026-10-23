// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TakumiPay.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("MockUSDC", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract TakumiPayMerchantTest is Test {
    TakumiPay public wallet;
    MockUSDC public usdc;

    address public owner = address(0x1);
    uint256 public signerKey = 0xA11CE;
    address public signer;
    address public payer = address(0x3);

    function setUp() public {
        signer = vm.addr(signerKey);

        // Deploy behind proxy — owner and backend signer are set in one initialize
        TakumiPay impl = new TakumiPay();
        bytes memory initData = abi.encodeCall(TakumiPay.initialize, (owner, signer, address(0)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);

        wallet = TakumiPay(payable(address(proxy)));

        // Setup mock USDC
        usdc = new MockUSDC();
        usdc.mint(payer, 1_000_000e6);
        vm.prank(payer);
        usdc.approve(address(wallet), type(uint256).max);

        // Every payment entrypoint is allowlist-gated, native included.
        vm.startPrank(owner);
        wallet.addAllowedPaymentToken(address(usdc));
        wallet.addAllowedPaymentToken(address(0));
        vm.stopPrank();

        // Sweeps fail closed until a cap is configured.
        _setSweepCap(address(usdc), type(uint256).max);
        _setSweepCap(address(0), type(uint256).max);
    }

    /// Raising a sweep cap is a two-step queue/apply (both legs land in the same
    /// block while withdrawalDelay is 0); lowering is a single immediate call.
    function _setSweepCap(address token, uint256 cap) internal {
        vm.startPrank(owner);
        if (cap > wallet.sweepCap(token)) {
            wallet.queueSweepCap(token, cap);
            wallet.applySweepCap(token);
        } else {
            wallet.setSweepCap(token, cap);
        }
        vm.stopPrank();
    }

    // ====== Helpers ======

    function _signQuote(TakumiPay.QuoteCommitment memory quote)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                wallet.QUOTE_TYPEHASH(),
                keccak256(bytes(quote.refId)),
                keccak256(bytes(quote.merchantId)),
                quote.tokenAddress,
                quote.amount,
                quote.platformFeeAmount,
                quote.fiatAmountMinor,
                quote.fiatCurrency,
                quote.exchangeRateId,
                quote.expiresAt
            )
        );

        bytes32 domainSeparator = wallet.DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signQuoteWithKey(TakumiPay.QuoteCommitment memory quote, uint256 privateKey)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                wallet.QUOTE_TYPEHASH(),
                keccak256(bytes(quote.refId)),
                keccak256(bytes(quote.merchantId)),
                quote.tokenAddress,
                quote.amount,
                quote.platformFeeAmount,
                quote.fiatAmountMinor,
                quote.fiatCurrency,
                quote.exchangeRateId,
                quote.expiresAt
            )
        );

        bytes32 domainSeparator = wallet.DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _defaultQuote() internal view returns (TakumiPay.QuoteCommitment memory) {
        return TakumiPay.QuoteCommitment({
            refId: "test-ref-001",
            merchantId: "merchant-001",
            tokenAddress: address(usdc),
            amount: 10e6,
            platformFeeAmount: 0.5e6,
            fiatAmountMinor: 150000,
            fiatCurrency: bytes3("IDR"),
            exchangeRateId: 1,
            expiresAt: block.timestamp + 900
        });
    }

    function _defaultNativeQuote() internal view returns (TakumiPay.QuoteCommitment memory) {
        return TakumiPay.QuoteCommitment({
            refId: "native-ref-001",
            merchantId: "merchant-001",
            tokenAddress: address(0),
            amount: 1 ether,
            platformFeeAmount: 0.01 ether,
            fiatAmountMinor: 5000000,
            fiatCurrency: bytes3("IDR"),
            exchangeRateId: 2,
            expiresAt: block.timestamp + 900
        });
    }

    // ====== processMerchantPayment: Happy Path (ERC-20) ======

    function test_processMerchantPayment_happyPath() public {
        TakumiPay.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);

        uint256 payerBefore = usdc.balanceOf(payer);
        uint256 walletBefore = usdc.balanceOf(address(wallet));

        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);

        // Token transferred
        assertEq(usdc.balanceOf(payer), payerBefore - quote.amount);
        assertEq(usdc.balanceOf(address(wallet)), walletBefore + quote.amount);

        // Payment stored
        TakumiPay.MerchantPayment memory payment = wallet.getMerchantPaymentByRef("test-ref-001");
        assertEq(payment.payer, payer);
        assertEq(payment.tokenAddress, address(usdc));
        assertEq(payment.amount, 10e6);
        assertEq(payment.platformFeeAmount, 0.5e6);
        assertEq(payment.fiatAmountMinor, 150000);
        assertEq(payment.fiatCurrency, bytes3("IDR"));
        assertEq(payment.exchangeRateId, 1);
        assertEq(keccak256(bytes(payment.merchantId)), keccak256(bytes("merchant-001")));
        assertEq(keccak256(bytes(payment.refId)), keccak256(bytes("test-ref-001")));

        // Fee accrued
        assertEq(wallet.platformFeeAccrued(address(usdc)), 0.5e6);
    }

    // ====== processMerchantPayment: Native Token ======

    function test_processMerchantPayment_nativeToken() public {
        TakumiPay.QuoteCommitment memory quote = _defaultNativeQuote();
        bytes memory sig = _signQuote(quote);

        vm.deal(payer, 10 ether);
        uint256 walletBefore = address(wallet).balance;

        vm.prank(payer);
        wallet.processMerchantPayment{value: 1 ether}(quote, sig);

        assertEq(address(wallet).balance, walletBefore + 1 ether);

        TakumiPay.MerchantPayment memory payment = wallet.getMerchantPaymentByRef("native-ref-001");
        assertEq(payment.payer, payer);
        assertEq(payment.tokenAddress, address(0));
        assertEq(payment.amount, 1 ether);
        assertEq(payment.platformFeeAmount, 0.01 ether);

        assertEq(wallet.platformFeeAccrued(address(0)), 0.01 ether);
    }

    // ====== processMerchantPayment: Emits Event ======

    function test_processMerchantPayment_emitsEvent() public {
        TakumiPay.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);

        vm.expectEmit(true, true, true, true);
        emit TakumiPay.MerchantPaymentProcessed(
            "test-ref-001",
            "merchant-001",
            payer,
            "test-ref-001",
            "merchant-001",
            address(usdc),
            10e6,
            0.5e6,
            150000,
            1
        );

        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);
    }

    // ====== Revert: QuoteExpired ======

    function test_revert_quoteExpired() public {
        TakumiPay.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);

        // Warp past expiry
        vm.warp(quote.expiresAt + 1);

        vm.prank(payer);
        vm.expectRevert(TakumiPay.QuoteExpired.selector);
        wallet.processMerchantPayment(quote, sig);
    }

    // ====== Revert: RefConsumed ======

    function test_revert_refConsumed() public {
        TakumiPay.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);

        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);

        // Second call with same refId should revert
        vm.prank(payer);
        vm.expectRevert(TakumiPay.RefConsumed.selector);
        wallet.processMerchantPayment(quote, sig);
    }

    // ====== Revert: BadQuote (wrong signer) ======

    function test_revert_badQuote_wrongSigner() public {
        TakumiPay.QuoteCommitment memory quote = _defaultQuote();
        uint256 wrongKey = 0xBEEF;
        bytes memory sig = _signQuoteWithKey(quote, wrongKey);

        vm.prank(payer);
        vm.expectRevert(TakumiPay.BadQuote.selector);
        wallet.processMerchantPayment(quote, sig);
    }

    // ====== Revert: FeeExceedsAmount ======

    function test_revert_feeExceedsAmount() public {
        TakumiPay.QuoteCommitment memory quote = _defaultQuote();
        quote.platformFeeAmount = quote.amount + 1; // fee > amount
        bytes memory sig = _signQuote(quote);

        vm.prank(payer);
        vm.expectRevert(TakumiPay.FeeExceedsAmount.selector);
        wallet.processMerchantPayment(quote, sig);
    }

    // ====== Revert: NativeAmountMismatch ======

    function test_revert_nativeAmountMismatch() public {
        TakumiPay.QuoteCommitment memory quote = _defaultNativeQuote();
        bytes memory sig = _signQuote(quote);

        vm.deal(payer, 10 ether);
        vm.prank(payer);
        vm.expectRevert(TakumiPay.NativeAmountMismatch.selector);
        // Send wrong amount
        wallet.processMerchantPayment{value: 0.5 ether}(quote, sig);
    }

    // ====== Revert: UnexpectedNative ======

    function test_revert_unexpectedNative() public {
        TakumiPay.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);

        vm.deal(payer, 1 ether);
        vm.prank(payer);
        vm.expectRevert(TakumiPay.UnexpectedNative.selector);
        // Send ETH with ERC-20 quote
        wallet.processMerchantPayment{value: 0.1 ether}(quote, sig);
    }

    // ====== Revert: Contract Paused ======

    function test_revert_processMerchantPayment_whenPaused() public {
        TakumiPay.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);

        vm.prank(owner);
        wallet.setPaused(true);

        vm.prank(payer);
        vm.expectRevert(TakumiPay.ContractPaused.selector);
        wallet.processMerchantPayment(quote, sig);
    }

    // ====== sweepPlatformFees: Happy Path ======

    function test_sweepPlatformFees() public {
        // First create a payment to accrue fees
        TakumiPay.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);
        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);

        address treasury = makeAddr("treasury");
        uint256 accrued = wallet.platformFeeAccrued(address(usdc));
        assertEq(accrued, 0.5e6);

        vm.prank(owner);
        wallet.sweepPlatformFees(address(usdc), treasury, 0.5e6);

        assertEq(usdc.balanceOf(treasury), 0.5e6);
        assertEq(wallet.platformFeeAccrued(address(usdc)), 0);
    }

    // ====== sweepPlatformFees: Emits Event ======

    function test_sweepPlatformFees_emitsEvent() public {
        TakumiPay.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);
        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);

        address treasury = makeAddr("treasury");

        vm.expectEmit(true, true, false, true);
        emit TakumiPay.PlatformFeesSwept(address(usdc), treasury, 0.5e6);

        vm.prank(owner);
        wallet.sweepPlatformFees(address(usdc), treasury, 0.5e6);
    }

    // ====== Revert: sweepPlatformFees exceeds accrued ======

    function test_revert_sweepPlatformFees_exceedsAccrued() public {
        // No fees accrued yet
        vm.prank(owner);
        vm.expectRevert(TakumiPay.FeeAmountInvalid.selector);
        wallet.sweepPlatformFees(address(usdc), makeAddr("treasury"), 1);
    }

    function test_revert_sweepPlatformFees_zeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(TakumiPay.FeeAmountInvalid.selector);
        wallet.sweepPlatformFees(address(usdc), makeAddr("treasury"), 0);
    }

    function test_revert_sweepPlatformFees_notOwner() public {
        vm.prank(payer);
        vm.expectRevert(TakumiPay.NotOwner.selector);
        wallet.sweepPlatformFees(address(usdc), payer, 1);
    }

    // ====== sweepMerchantBacking: Happy Path ======

    function test_sweepMerchantBacking() public {
        // Create a payment so wallet holds funds
        TakumiPay.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);
        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);

        // Sweep the merchant backing (amount minus fee)
        address merchant = makeAddr("merchant");
        uint256 merchantAmount = quote.amount - quote.platformFeeAmount;

        vm.prank(owner);
        wallet.sweepMerchantBacking(address(usdc), merchant, merchantAmount);

        assertEq(usdc.balanceOf(merchant), merchantAmount);
    }

    // ====== sweepMerchantBacking: Emits Event ======

    function test_sweepMerchantBacking_emitsEvent() public {
        TakumiPay.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);
        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);

        address merchant = makeAddr("merchant");

        vm.expectEmit(true, true, false, true);
        emit TakumiPay.MerchantBackingSwept(address(usdc), merchant, 9.5e6);

        vm.prank(owner);
        wallet.sweepMerchantBacking(address(usdc), merchant, 9.5e6);
    }

    // ====== sweepMerchantBacking: Native Token ======

    function test_sweepMerchantBacking_nativeToken() public {
        TakumiPay.QuoteCommitment memory quote = _defaultNativeQuote();
        bytes memory sig = _signQuote(quote);

        vm.deal(payer, 10 ether);
        vm.prank(payer);
        wallet.processMerchantPayment{value: 1 ether}(quote, sig);

        address merchant = makeAddr("merchant");
        uint256 merchantBefore = merchant.balance;

        vm.prank(owner);
        wallet.sweepMerchantBacking(address(0), merchant, 0.99 ether);

        assertEq(merchant.balance, merchantBefore + 0.99 ether);
    }

    function test_revert_sweepMerchantBacking_notOwner() public {
        vm.prank(payer);
        vm.expectRevert(TakumiPay.NotOwner.selector);
        wallet.sweepMerchantBacking(address(usdc), payer, 1);
    }

    function test_revert_sweepMerchantBacking_zeroRecipient() public {
        // Fund the contract so the balance precondition holds and this test
        // isolates the zero-recipient rejection.
        TakumiPay.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);
        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);

        vm.prank(owner);
        vm.expectRevert(TakumiPay.ZeroRecipient.selector);
        wallet.sweepMerchantBacking(address(usdc), address(0), 1);
    }

    // ====== rotateBackendSigner ======

    function test_rotateBackendSigner() public {
        address newSigner = makeAddr("newSigner");

        vm.prank(owner);
        wallet.rotateBackendSigner(newSigner);

        assertEq(wallet.backendSigner(), newSigner);
    }

    function test_rotateBackendSigner_emitsEvent() public {
        address newSigner = makeAddr("newSigner");

        vm.expectEmit(true, true, false, false);
        emit TakumiPay.BackendSignerRotated(signer, newSigner);

        vm.prank(owner);
        wallet.rotateBackendSigner(newSigner);
    }

    function test_rotateBackendSigner_newSignerWorks_oldDoesNot() public {
        uint256 newSignerKey = 0xDEAD;
        address newSignerAddr = vm.addr(newSignerKey);

        vm.prank(owner);
        wallet.rotateBackendSigner(newSignerAddr);

        // Quote signed by new signer should work
        TakumiPay.QuoteCommitment memory quote = TakumiPay.QuoteCommitment({
            refId: "rotated-ref-001",
            merchantId: "merchant-001",
            tokenAddress: address(usdc),
            amount: 5e6,
            platformFeeAmount: 0.25e6,
            fiatAmountMinor: 75000,
            fiatCurrency: bytes3("IDR"),
            exchangeRateId: 1,
            expiresAt: block.timestamp + 900
        });
        bytes memory newSig = _signQuoteWithKey(quote, newSignerKey);

        vm.prank(payer);
        wallet.processMerchantPayment(quote, newSig);

        // Quote signed by old signer should fail
        TakumiPay.QuoteCommitment memory quote2 = TakumiPay.QuoteCommitment({
            refId: "rotated-ref-002",
            merchantId: "merchant-001",
            tokenAddress: address(usdc),
            amount: 5e6,
            platformFeeAmount: 0.25e6,
            fiatAmountMinor: 75000,
            fiatCurrency: bytes3("IDR"),
            exchangeRateId: 1,
            expiresAt: block.timestamp + 900
        });
        bytes memory oldSig = _signQuoteWithKey(quote2, signerKey);

        vm.prank(payer);
        vm.expectRevert(TakumiPay.BadQuote.selector);
        wallet.processMerchantPayment(quote2, oldSig);
    }

    function test_revert_rotateBackendSigner_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(TakumiPay.ZeroSigner.selector);
        wallet.rotateBackendSigner(address(0));
    }

    function test_revert_rotateBackendSigner_notOwner() public {
        vm.prank(payer);
        vm.expectRevert(TakumiPay.NotOwner.selector);
        wallet.rotateBackendSigner(makeAddr("newSigner"));
    }

    // ====== getMerchantPaymentByRef ======

    function test_getMerchantPaymentByRef() public {
        TakumiPay.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);

        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);

        TakumiPay.MerchantPayment memory payment = wallet.getMerchantPaymentByRef("test-ref-001");

        assertEq(payment.payer, payer);
        assertEq(payment.tokenAddress, address(usdc));
        assertEq(payment.amount, 10e6);
        assertEq(payment.platformFeeAmount, 0.5e6);
        assertEq(payment.fiatAmountMinor, 150000);
        assertEq(payment.fiatCurrency, bytes3("IDR"));
        assertEq(payment.exchangeRateId, 1);
        assertEq(payment.timestamp, block.timestamp);
        assertEq(keccak256(bytes(payment.merchantId)), keccak256(bytes("merchant-001")));
        assertEq(keccak256(bytes(payment.refId)), keccak256(bytes("test-ref-001")));
    }

    function test_revert_getMerchantPaymentByRef_unknown() public {
        vm.expectRevert(TakumiPay.PaymentNotFound.selector);
        wallet.getMerchantPaymentByRef("unknown-ref");
    }

    // ====== version ======

    function test_version() public view {
        assertEq(wallet.version(), "2.2.0");
    }

    // ====== Booking and merchant flows coexist ======

    function test_bookingAndMerchantFlowsCoexist() public {
        MockUSDC usdc2 = new MockUSDC();
        usdc2.mint(payer, 1000e6);

        vm.prank(owner);
        wallet.addAllowedPaymentToken(address(usdc2));

        vm.startPrank(payer);
        usdc2.approve(address(wallet), 100e6);
        wallet.createTransaction("booking-001", 1, "variant-001", address(usdc2), "tx-ref-001", 100e6);
        vm.stopPrank();

        assertEq(wallet.txCounter(), 1);

        // Owner can still manage admins
        vm.prank(owner);
        wallet.addAdmin(makeAddr("admin2"));
        assertTrue(wallet.isAdmin(makeAddr("admin2")));

        assertEq(wallet.owner(), owner);
    }

    // ====== refId idempotency across flows ======

    /// A refId consumed by a merchant payment cannot be reused by the unsigned flows.
    function test_revert_bookingAndDeposit_reuseMerchantRefId() public {
        TakumiPay.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);
        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);

        vm.startPrank(payer);
        vm.expectRevert(TakumiPay.RefConsumed.selector);
        wallet.createTransaction("booking-001", 1, "variant-001", address(usdc), quote.refId, 1e6);

        vm.expectRevert(TakumiPay.RefConsumed.selector);
        wallet.depositPoints(address(usdc), quote.refId, 1e6);
        vm.stopPrank();
    }

    /// The reverse is deliberately not checked: otherwise anyone watching a pending
    /// merchant payment could front-run it with a booking under the quote's refId and
    /// make the signed quote permanently unpayable.
    function test_merchantPayment_cannotBeBlockedByBookingFrontRun() public {
        TakumiPay.QuoteCommitment memory quote = _defaultQuote();
        address attacker = makeAddr("attacker");
        usdc.mint(attacker, 1e6);

        vm.startPrank(attacker);
        usdc.approve(address(wallet), 1e6);
        wallet.createTransaction("b", 1, "v", address(usdc), quote.refId, 1e6);
        vm.stopPrank();

        bytes memory sig = _signQuote(quote);
        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);
        assertEq(wallet.getMerchantPaymentByRef(quote.refId).payer, payer);
    }

    // ====== initialize cannot be called twice ======

    function test_revert_initialize_cannotReinitialize() public {
        vm.prank(owner);
        vm.expectRevert();
        wallet.initialize(owner, makeAddr("anotherSigner"), address(0));
    }

    // ====== Sweep platform fees with native token ======

    function test_sweepPlatformFees_nativeToken() public {
        TakumiPay.QuoteCommitment memory quote = _defaultNativeQuote();
        bytes memory sig = _signQuote(quote);

        vm.deal(payer, 10 ether);
        vm.prank(payer);
        wallet.processMerchantPayment{value: 1 ether}(quote, sig);

        address treasury = makeAddr("treasury");
        uint256 accrued = wallet.platformFeeAccrued(address(0));
        assertEq(accrued, 0.01 ether);

        uint256 treasuryBefore = treasury.balance;

        vm.prank(owner);
        wallet.sweepPlatformFees(address(0), treasury, 0.01 ether);

        assertEq(treasury.balance, treasuryBefore + 0.01 ether);
        assertEq(wallet.platformFeeAccrued(address(0)), 0);
    }

    // ====== Partial fee sweep ======

    function test_sweepPlatformFees_partialSweep() public {
        TakumiPay.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);
        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);

        address treasury = makeAddr("treasury");

        // Sweep half the fees
        vm.prank(owner);
        wallet.sweepPlatformFees(address(usdc), treasury, 0.25e6);

        assertEq(usdc.balanceOf(treasury), 0.25e6);
        assertEq(wallet.platformFeeAccrued(address(usdc)), 0.25e6);

        // Sweep remaining
        vm.prank(owner);
        wallet.sweepPlatformFees(address(usdc), treasury, 0.25e6);

        assertEq(usdc.balanceOf(treasury), 0.5e6);
        assertEq(wallet.platformFeeAccrued(address(usdc)), 0);
    }

    // ====== Multiple payments accumulate fees ======

    function test_multipleMerchantPayments_accumulateFees() public {
        TakumiPay.QuoteCommitment memory quote1 = _defaultQuote();
        bytes memory sig1 = _signQuote(quote1);
        vm.prank(payer);
        wallet.processMerchantPayment(quote1, sig1);

        TakumiPay.QuoteCommitment memory quote2 = TakumiPay.QuoteCommitment({
            refId: "test-ref-002",
            merchantId: "merchant-002",
            tokenAddress: address(usdc),
            amount: 20e6,
            platformFeeAmount: 1e6,
            fiatAmountMinor: 300000,
            fiatCurrency: bytes3("IDR"),
            exchangeRateId: 3,
            expiresAt: block.timestamp + 900
        });
        bytes memory sig2 = _signQuote(quote2);
        vm.prank(payer);
        wallet.processMerchantPayment(quote2, sig2);

        assertEq(wallet.platformFeeAccrued(address(usdc)), 0.5e6 + 1e6);
    }

    // ====== Zero fee payment works ======

    function test_processMerchantPayment_zeroFee() public {
        TakumiPay.QuoteCommitment memory quote = TakumiPay.QuoteCommitment({
            refId: "zero-fee-ref",
            merchantId: "merchant-001",
            tokenAddress: address(usdc),
            amount: 10e6,
            platformFeeAmount: 0,
            fiatAmountMinor: 150000,
            fiatCurrency: bytes3("IDR"),
            exchangeRateId: 1,
            expiresAt: block.timestamp + 900
        });
        bytes memory sig = _signQuote(quote);

        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);

        assertEq(wallet.platformFeeAccrued(address(usdc)), 0);

        TakumiPay.MerchantPayment memory payment = wallet.getMerchantPaymentByRef("zero-fee-ref");
        assertEq(payment.amount, 10e6);
        assertEq(payment.platformFeeAmount, 0);
    }

    // ====== backendSigner is set after initialization ======

    function test_backendSigner_setAfterInit() public view {
        assertEq(wallet.backendSigner(), signer);
    }

    // ====== Payment token allowlist (parity with Stellar AllowedPaymentToken) ======

    function test_revert_processMerchantPayment_tokenNotAllowed() public {
        MockUSDC rogue = new MockUSDC();
        rogue.mint(payer, 1000e6);
        vm.prank(payer);
        rogue.approve(address(wallet), type(uint256).max);

        TakumiPay.QuoteCommitment memory quote = _defaultQuote();
        quote.tokenAddress = address(rogue);
        bytes memory sig = _signQuote(quote);

        vm.prank(payer);
        vm.expectRevert(TakumiPay.TokenNotAllowed.selector);
        wallet.processMerchantPayment(quote, sig);
    }

    /// Native is gated by the same allowlist — de-allowlisting address(0) blocks it.
    function test_processMerchantPayment_nativeRequiresAllowlist() public {
        vm.prank(owner);
        wallet.removeAllowedPaymentToken(address(0));

        TakumiPay.QuoteCommitment memory quote = _defaultNativeQuote();
        bytes memory sig = _signQuote(quote);

        vm.deal(payer, 10 ether);
        vm.prank(payer);
        vm.expectRevert(TakumiPay.TokenNotAllowed.selector);
        wallet.processMerchantPayment{value: 1 ether}(quote, sig);

        // Re-allowlisting restores it
        vm.prank(owner);
        wallet.addAllowedPaymentToken(address(0));

        vm.prank(payer);
        wallet.processMerchantPayment{value: 1 ether}(quote, sig);
        assertEq(wallet.platformFeeAccrued(address(0)), 0.01 ether);
    }

    // ====== Quote validation (parity with Stellar merchant.rs) ======

    function test_revert_processMerchantPayment_zeroAmount() public {
        TakumiPay.QuoteCommitment memory quote = _defaultQuote();
        quote.amount = 0;
        quote.platformFeeAmount = 0;
        bytes memory sig = _signQuote(quote);

        vm.prank(payer);
        vm.expectRevert(TakumiPay.ZeroAmount.selector);
        wallet.processMerchantPayment(quote, sig);
    }

    function test_revert_processMerchantPayment_refIdTooLong() public {
        TakumiPay.QuoteCommitment memory quote = _defaultQuote();
        // 65 chars — one past MAX_STRING_LENGTH
        quote.refId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        assertEq(bytes(quote.refId).length, 65);
        bytes memory sig = _signQuote(quote);

        vm.prank(payer);
        vm.expectRevert(TakumiPay.InvalidStringLength.selector);
        wallet.processMerchantPayment(quote, sig);
    }

    function test_revert_processMerchantPayment_emptyMerchantId() public {
        TakumiPay.QuoteCommitment memory quote = _defaultQuote();
        quote.merchantId = "";
        bytes memory sig = _signQuote(quote);

        vm.prank(payer);
        vm.expectRevert(TakumiPay.InvalidStringLength.selector);
        wallet.processMerchantPayment(quote, sig);
    }

    // ====== sweepMerchantBacking guards (parity with Stellar treasury.rs) ======

    function test_revert_sweepMerchantBacking_insufficientBalance() public {
        TakumiPay.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);
        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);

        // Contract holds 10e6; asking for more must revert before any transfer
        vm.prank(owner);
        vm.expectRevert(TakumiPay.InsufficientBalance.selector);
        wallet.sweepMerchantBacking(address(usdc), makeAddr("treasury"), 10e6 + 1);
    }

    function test_revert_sweepMerchantBacking_zeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(TakumiPay.ZeroAmount.selector);
        wallet.sweepMerchantBacking(address(usdc), makeAddr("treasury"), 0);
    }

    // ====== Sweep rate limit ======

    function _fundContract() internal {
        TakumiPay.QuoteCommitment memory quote = _defaultQuote();
        bytes memory sig = _signQuote(quote);
        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);
    }

    /// An unconfigured cap must fail closed — this is the property that makes the
    /// rate limit a real control rather than an opt-in suggestion.
    function test_revert_sweep_capNotSet() public {
        MockUSDC other = new MockUSDC();
        other.mint(address(wallet), 1000e6);

        vm.prank(owner);
        vm.expectRevert(TakumiPay.SweepCapNotSet.selector);
        wallet.sweepMerchantBacking(address(other), makeAddr("treasury"), 1e6);
    }

    function test_revert_sweep_capExceeded() public {
        _fundContract();
        _setSweepCap(address(usdc), 4e6);

        address treasury = makeAddr("treasury");

        vm.prank(owner);
        wallet.sweepMerchantBacking(address(usdc), treasury, 3e6);

        // 3e6 already consumed this window; 2e6 more would breach the 4e6 cap
        vm.prank(owner);
        vm.expectRevert(TakumiPay.SweepCapExceeded.selector);
        wallet.sweepMerchantBacking(address(usdc), treasury, 2e6);

        assertEq(usdc.balanceOf(treasury), 3e6);
    }

    function test_sweepCap_resetsAfterWindow() public {
        _fundContract();
        _setSweepCap(address(usdc), 4e6);

        address treasury = makeAddr("treasury");

        vm.prank(owner);
        wallet.sweepMerchantBacking(address(usdc), treasury, 4e6);

        vm.prank(owner);
        vm.expectRevert(TakumiPay.SweepCapExceeded.selector);
        wallet.sweepMerchantBacking(address(usdc), treasury, 1e6);

        // A fresh window restores the full allowance
        vm.warp(block.timestamp + 1 days);
        vm.prank(owner);
        wallet.sweepMerchantBacking(address(usdc), treasury, 4e6);

        assertEq(usdc.balanceOf(treasury), 8e6);
    }

    /// Raising a cap is a loosening, so it cannot be done in one call.
    function test_revert_setSweepCap_cannotRaiseDirectly() public {
        _setSweepCap(address(usdc), 1e6);

        vm.prank(owner);
        vm.expectRevert(TakumiPay.NotALoosening.selector);
        wallet.setSweepCap(address(usdc), 2e6);
    }

    function test_setSweepCap_loweringIsImmediate() public {
        _setSweepCap(address(usdc), 10e6);

        vm.prank(owner);
        wallet.setSweepCap(address(usdc), 1e6);
        assertEq(wallet.sweepCap(address(usdc)), 1e6);
    }

    // ====== Withdrawal delay cannot be lowered instantly ======

    /// The original bypass: setWithdrawalDelay(0) followed by withdraw() in one
    /// transaction made the timelock decorative. Lowering is now queued.
    function test_revert_setWithdrawalDelay_cannotLowerDirectly() public {
        vm.startPrank(owner);
        wallet.setWithdrawalDelay(7 days);

        vm.expectRevert(TakumiPay.NotALoosening.selector);
        wallet.setWithdrawalDelay(0);
        vm.stopPrank();

        assertEq(wallet.withdrawalDelay(), 7 days);
    }

    function test_setWithdrawalDelay_raisingIsImmediate() public {
        vm.startPrank(owner);
        wallet.setWithdrawalDelay(1 days);
        assertEq(wallet.withdrawalDelay(), 1 days);
        wallet.setWithdrawalDelay(7 days);
        assertEq(wallet.withdrawalDelay(), 7 days);
        vm.stopPrank();
    }

    function test_withdrawalDelay_reductionRequiresWaitingOutTheDelay() public {
        vm.startPrank(owner);
        wallet.setWithdrawalDelay(7 days);
        wallet.queueWithdrawalDelay(0);

        // Not yet — the reduction is subject to the delay currently in force
        vm.expectRevert(TakumiPay.TimelockNotExpired.selector);
        wallet.applyWithdrawalDelay();
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days);
        vm.prank(owner);
        wallet.applyWithdrawalDelay();
        assertEq(wallet.withdrawalDelay(), 0);
    }

    function test_cancelPendingChange() public {
        vm.startPrank(owner);
        wallet.setWithdrawalDelay(7 days);
        wallet.queueWithdrawalDelay(0);
        wallet.cancelPendingChange(keccak256("withdrawalDelay"));

        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(TakumiPay.NoPendingChange.selector);
        wallet.applyWithdrawalDelay();
        vm.stopPrank();

        assertEq(wallet.withdrawalDelay(), 7 days);
    }
}
