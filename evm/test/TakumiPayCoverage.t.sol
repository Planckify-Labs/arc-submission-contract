// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TakumiPay.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

interface ITokenHook {
    function onTokenMove() external;
}

/// 6-decimal ERC-20 that calls a hook once, on its next balance move after being armed.
contract HookToken is ERC20 {
    address public hook;

    constructor() ERC20("Hook", "HOOK") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address hook_) external {
        hook = hook_;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        address h = hook;
        if (h != address(0)) {
            hook = address(0);
            ITokenHook(h).onTokenMove();
        }
    }
}

/// @notice Kills the mutants that survived the Olympix mutation run of 2.2.0. See
///         "Mutation testing" in docs/olympix-bugpocer-response-2.2.0.md. Each section
///         names the 2.2.0 lines whose mutants it kills.
///
///         Time is read with vm.getBlockTimestamp(); see TakumiPayAuditFixes.t.sol.
contract TakumiPayCoverageTest is Test, ITokenHook {
    TakumiPay public wallet;
    HookToken public token;

    address public owner;
    uint256 internal signerKey = 0xA11CE;
    address public payer;
    address public stranger;
    address public recipient;

    uint256 internal constant UNLIMITED = type(uint256).max;

    // Re-entry probe: the call made from inside a token or native callback, and how it
    // ended. The test contract is the owner, so owner-only functions are re-entered as
    // the owner and reach nonReentrant rather than stopping at onlyOwner.
    address internal _reentryTarget;
    bytes internal _reentryCall;
    bool internal _reentryAttempted;
    bool internal _reentrySucceeded;
    bytes internal _reentryRevert;

    function setUp() public {
        owner = address(this);
        payer = makeAddr("payer");
        stranger = makeAddr("stranger");
        recipient = makeAddr("recipient");

        wallet = _deploy(address(0));
        token = new HookToken();
        wallet.addAllowedPaymentToken(address(token));
        wallet.queueSweepCap(address(token), UNLIMITED);
        wallet.applySweepCap(address(token));

        token.mint(payer, 1_000_000e6);
        vm.prank(payer);
        token.approve(address(wallet), type(uint256).max);
    }

    // ====== Helpers ======

    function _deploy(address aliasToken) internal returns (TakumiPay) {
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(new TakumiPay()),
            abi.encodeCall(TakumiPay.initialize, (owner, vm.addr(signerKey), aliasToken))
        );
        return TakumiPay(payable(address(proxy)));
    }

    function _book(string memory refId, uint256 amount) internal {
        vm.prank(payer);
        wallet.createTransaction("b", 1, "v", address(token), refId, amount);
    }

    function _quote(string memory refId) internal view returns (TakumiPay.QuoteCommitment memory quote, bytes memory sig) {
        quote = TakumiPay.QuoteCommitment({
            refId: refId,
            merchantId: "merchant-001",
            tokenAddress: address(token),
            amount: 10e6,
            platformFeeAmount: 0.5e6,
            fiatAmountMinor: 150000,
            fiatCurrency: bytes3("IDR"),
            exchangeRateId: 1,
            expiresAt: vm.getBlockTimestamp() + 900
        });
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
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", wallet.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _armReentry(address target, bytes memory call) internal {
        _reentryTarget = target;
        _reentryCall = call;
        _reentryAttempted = false;
    }

    function onTokenMove() external {
        _reenter();
    }

    receive() external payable {
        if (_reentryCall.length != 0) _reenter();
    }

    function _reenter() internal {
        bytes memory call = _reentryCall;
        delete _reentryCall;
        _reentryAttempted = true;
        (_reentrySucceeded, _reentryRevert) = _reentryTarget.call(call);
    }

    function _assertReentryBlocked() internal view {
        assertTrue(_reentryAttempted, "callback never fired");
        assertFalse(_reentrySucceeded, "re-entered");
        assertEq(_reentryRevert, abi.encodeWithSelector(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector));
    }

    function _expectNotOwner(bytes memory call) internal {
        vm.prank(stranger);
        (bool ok, bytes memory ret) = address(wallet).call(call);
        assertFalse(ok, "stranger got through");
        assertEq(ret, abi.encodeWithSelector(TakumiPay.NotOwner.selector));
    }

    // ====== Initialization (400, 402, 403) ======
    // These mutants break every setUp, so the suite already fails on them; the tool
    // scored them as survivors. Pinned explicitly here anyway.

    function test_revert_initialize_twice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        wallet.initialize(owner, vm.addr(signerKey), address(0));
    }

    function test_revert_initialize_implementationDirectly() public {
        TakumiPay impl = new TakumiPay();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(owner, vm.addr(signerKey), address(0));
    }

    function test_revert_initialize_zeroOwner() public {
        address impl = address(new TakumiPay());
        vm.expectRevert(TakumiPay.ZeroAddress.selector);
        new ERC1967Proxy(impl, abi.encodeCall(TakumiPay.initialize, (address(0), vm.addr(signerKey), address(0))));
    }

    function test_revert_initialize_zeroSigner() public {
        address impl = address(new TakumiPay());
        vm.expectRevert(TakumiPay.ZeroSigner.selector);
        new ERC1967Proxy(impl, abi.encodeCall(TakumiPay.initialize, (owner, address(0), address(0))));
    }

    // ====== Access control (469, 769, 780, 816, 821, 842, 848, 853, 859, 887, 912, 925, 963, 972) ======

    /// Every owner-only function, not only the ones the mutation run flagged.
    function test_onlyOwner_rejectsStrangerEverywhere() public {
        address t = address(token);
        _expectNotOwner(abi.encodeCall(TakumiPay.transferOwnership, (stranger)));
        _expectNotOwner(abi.encodeCall(TakumiPay.cancelOwnershipTransfer, ()));
        _expectNotOwner(abi.encodeCall(TakumiPay.setMaxTransactionAmount, (t, 1)));
        _expectNotOwner(abi.encodeCall(TakumiPay.sweepPlatformFees, (t, recipient, 1)));
        _expectNotOwner(abi.encodeCall(TakumiPay.sweepMerchantBacking, (t, recipient, 1)));
        _expectNotOwner(abi.encodeCall(TakumiPay.rotateBackendSigner, (stranger)));
        _expectNotOwner(abi.encodeCall(TakumiPay.withdraw, (t, recipient, 1)));
        _expectNotOwner(abi.encodeCall(TakumiPay.withdrawAll, (t, recipient)));
        _expectNotOwner(abi.encodeCall(TakumiPay.setWithdrawalDelay, (1 days)));
        _expectNotOwner(abi.encodeCall(TakumiPay.queueWithdrawalDelay, (0)));
        _expectNotOwner(abi.encodeCall(TakumiPay.applyWithdrawalDelay, ()));
        _expectNotOwner(abi.encodeCall(TakumiPay.setSweepCap, (t, 0)));
        _expectNotOwner(abi.encodeCall(TakumiPay.queueSweepCap, (address(0), 1)));
        _expectNotOwner(abi.encodeCall(TakumiPay.applySweepCap, (t)));
        _expectNotOwner(abi.encodeCall(TakumiPay.cancelPendingChange, (keccak256("upgrade"))));
        _expectNotOwner(abi.encodeCall(TakumiPay.queueWithdrawal, (t, recipient, 1)));
        _expectNotOwner(abi.encodeCall(TakumiPay.executeWithdrawal, (bytes32(uint256(1)))));
        _expectNotOwner(abi.encodeCall(TakumiPay.cancelWithdrawal, (bytes32(uint256(1)))));
        _expectNotOwner(abi.encodeCall(TakumiPay.recoverToken, (t, recipient, 1)));
        _expectNotOwner(abi.encodeCall(TakumiPay.addAdmin, (stranger)));
        _expectNotOwner(abi.encodeCall(TakumiPay.removeAdmin, (stranger)));
        _expectNotOwner(abi.encodeCall(TakumiPay.setNativeAliasToken, (t)));
        _expectNotOwner(abi.encodeCall(TakumiPay.rescueNativeDust, (recipient)));
        _expectNotOwner(abi.encodeCall(TakumiPay.addAllowedPaymentToken, (address(0))));
        _expectNotOwner(abi.encodeCall(TakumiPay.removeAllowedPaymentToken, (t)));
        _expectNotOwner(abi.encodeCall(TakumiPay.queueUpgrade, (address(wallet))));
        _expectNotOwner(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(new TakumiPay()), "")));
    }

    function test_onlyAdminOrOwner_rejectsStranger() public {
        vm.startPrank(stranger);
        vm.expectRevert(TakumiPay.NotAdminOrOwner.selector);
        wallet.setPaused(true);
        vm.expectRevert(TakumiPay.NotAdminOrOwner.selector);
        wallet.setPointDepositsPaused(true);
        vm.stopPrank();
    }

    // ====== Instant exits close once a delay is set (772, 782, 939) ======

    function test_instantExits_closedOnceDelayIsSet() public {
        _book("fund", 10e6);
        wallet.setWithdrawalDelay(1 days);

        vm.expectRevert(TakumiPay.TimelockActive.selector);
        wallet.withdraw(address(token), recipient, 1e6);
        vm.expectRevert(TakumiPay.TimelockActive.selector);
        wallet.withdrawAll(address(token), recipient);
        vm.expectRevert(TakumiPay.TimelockActive.selector);
        wallet.recoverToken(address(token), recipient, 1e6);
    }

    // ====== Re-entrancy (498, 512, 633, 711, 724, 769, 780, 912, 936, 1087, 1193) ======

    function test_reentry_createTransaction() public {
        _armReentry(
            address(wallet), abi.encodeCall(TakumiPay.createTransaction, ("b", 1, "v", address(token), "inner", 1))
        );
        token.arm(address(this));
        _book("outer", 1e6);
        _assertReentryBlocked();
    }

    function test_reentry_createTransactionBatch() public {
        TakumiPay.TransactionParams[] memory params = new TakumiPay.TransactionParams[](1);
        params[0] = TakumiPay.TransactionParams("b", 1, "v", address(token), "outer", 1e6);
        _armReentry(address(wallet), abi.encodeCall(TakumiPay.createTransactionBatch, (params)));
        token.arm(address(this));
        vm.prank(payer);
        wallet.createTransactionBatch(params);
        _assertReentryBlocked();
    }

    function test_reentry_processMerchantPayment() public {
        (TakumiPay.QuoteCommitment memory quote, bytes memory sig) = _quote("m-outer");
        _armReentry(address(wallet), abi.encodeCall(TakumiPay.processMerchantPayment, (quote, sig)));
        token.arm(address(this));
        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);
        _assertReentryBlocked();
    }

    function test_reentry_depositPoints() public {
        _armReentry(address(wallet), abi.encodeCall(TakumiPay.depositPoints, (address(token), "inner", 1)));
        token.arm(address(this));
        vm.prank(payer);
        wallet.depositPoints(address(token), "outer", 1e6);
        _assertReentryBlocked();
    }

    function test_reentry_sweepPlatformFees() public {
        (TakumiPay.QuoteCommitment memory quote, bytes memory sig) = _quote("m-1");
        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);

        _armReentry(address(wallet), abi.encodeCall(TakumiPay.sweepPlatformFees, (address(token), recipient, 0.1e6)));
        token.arm(address(this));
        wallet.sweepPlatformFees(address(token), recipient, 0.2e6);
        _assertReentryBlocked();
    }

    function test_reentry_sweepMerchantBacking() public {
        _book("fund", 10e6);
        _armReentry(address(wallet), abi.encodeCall(TakumiPay.sweepMerchantBacking, (address(token), recipient, 1e6)));
        token.arm(address(this));
        wallet.sweepMerchantBacking(address(token), recipient, 1e6);
        _assertReentryBlocked();
    }

    function test_reentry_withdraw() public {
        _book("fund", 10e6);
        _armReentry(address(wallet), abi.encodeCall(TakumiPay.withdraw, (address(token), recipient, 1e6)));
        token.arm(address(this));
        wallet.withdraw(address(token), recipient, 1e6);
        _assertReentryBlocked();
    }

    function test_reentry_withdrawAll() public {
        _book("fund", 10e6);
        _armReentry(address(wallet), abi.encodeCall(TakumiPay.withdrawAll, (address(token), recipient)));
        token.arm(address(this));
        wallet.withdrawAll(address(token), recipient);
        _assertReentryBlocked();
    }

    function test_reentry_executeWithdrawal() public {
        _book("fund", 10e6);
        wallet.setWithdrawalDelay(1 days);
        bytes32 first = wallet.queueWithdrawal(address(token), recipient, 1e6);
        bytes32 second = wallet.queueWithdrawal(address(token), recipient, 1e6);
        vm.warp(vm.getBlockTimestamp() + 1 days);

        _armReentry(address(wallet), abi.encodeCall(TakumiPay.executeWithdrawal, (second)));
        token.arm(address(this));
        wallet.executeWithdrawal(first);
        _assertReentryBlocked();
    }

    function test_reentry_recoverToken() public {
        _book("fund", 10e6);
        _armReentry(address(wallet), abi.encodeCall(TakumiPay.recoverToken, (address(token), recipient, 1)));
        token.arm(address(this));
        wallet.recoverToken(address(token), recipient, 1e6);
        _assertReentryBlocked();
    }

    /// Native leg: the dust goes to this contract, whose receive() re-enters.
    function test_reentry_rescueNativeDust() public {
        TakumiPay aliased = _deploy(address(new HookToken()));
        vm.deal(address(aliased), 5e12 + 777);

        _armReentry(address(aliased), abi.encodeCall(TakumiPay.rescueNativeDust, (address(this))));
        aliased.rescueNativeDust(address(this));
        _assertReentryBlocked();
        assertEq(address(aliased).balance, 5e12);
    }

    // ====== Events (472, 612, 796, 823, 845, 856, 862, 876, 922, 958, 969, 988) ======

    function test_event_ownershipTransferCancelled() public {
        wallet.transferOwnership(stranger);
        vm.expectEmit(true, false, false, false, address(wallet));
        emit TakumiPay.OwnershipTransferCancelled(stranger);
        wallet.cancelOwnershipTransfer();
    }

    function test_event_transactionCreated() public {
        vm.expectEmit(true, true, true, true, address(wallet));
        emit TakumiPay.TransactionCreated(1, payer, address(token), "b", 1, "v", vm.getBlockTimestamp(), "ref-ev", 2e6);
        _book("ref-ev", 2e6);
    }

    function test_event_withdraw() public {
        _book("fund", 10e6);
        vm.expectEmit(true, true, false, true, address(wallet));
        emit TakumiPay.Withdraw(recipient, address(token), 1e6);
        wallet.withdraw(address(token), recipient, 1e6);
    }

    function test_event_applyWithdrawalDelay() public {
        wallet.setWithdrawalDelay(1 hours);
        wallet.queueWithdrawalDelay(0);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.expectEmit(false, false, false, true, address(wallet));
        emit TakumiPay.WithdrawalDelayUpdated(0);
        wallet.applyWithdrawalDelay();
    }

    function test_event_setSweepCap() public {
        vm.expectEmit(true, false, false, true, address(wallet));
        emit TakumiPay.SweepCapUpdated(address(token), 5e6);
        wallet.setSweepCap(address(token), 5e6);
    }

    function test_event_queueAndApplySweepCap() public {
        address other = address(new HookToken());
        bytes32 key = keccak256(abi.encode("sweepCap", other));

        vm.expectEmit(true, false, false, true, address(wallet));
        emit TakumiPay.PendingChangeQueued(key, 7e6, vm.getBlockTimestamp());
        wallet.queueSweepCap(other, 7e6);

        vm.expectEmit(true, false, false, true, address(wallet));
        emit TakumiPay.SweepCapUpdated(other, 7e6);
        wallet.applySweepCap(other);
    }

    function test_event_cancelPendingChange() public {
        address other = address(new HookToken());
        bytes32 key = keccak256(abi.encode("sweepCap", other));
        wallet.queueSweepCap(other, 7e6);

        vm.expectEmit(true, false, false, false, address(wallet));
        emit TakumiPay.PendingChangeCancelled(key);
        wallet.cancelPendingChange(key);
    }

    function test_event_withdrawalExecuted() public {
        _book("fund", 10e6);
        wallet.setWithdrawalDelay(1 days);
        bytes32 id = wallet.queueWithdrawal(address(token), recipient, 1e6);
        vm.warp(vm.getBlockTimestamp() + 1 days);

        vm.expectEmit(true, false, false, false, address(wallet));
        emit TakumiPay.WithdrawalExecuted(id);
        wallet.executeWithdrawal(id);
    }

    function test_event_nativeDeposit() public {
        vm.deal(stranger, 1 ether);
        vm.expectEmit(true, false, false, true, address(wallet));
        emit TakumiPay.NativeDeposit(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(wallet).call{value: 1 ether}("");
        assertTrue(ok);
    }

    function test_event_addAndRemoveAdmin() public {
        vm.expectEmit(true, false, false, false, address(wallet));
        emit TakumiPay.AdminAdded(stranger);
        wallet.addAdmin(stranger);

        vm.expectEmit(true, false, false, false, address(wallet));
        emit TakumiPay.AdminRemoved(stranger);
        wallet.removeAdmin(stranger);
    }

    // ====== Batch spending limit (534, 535) ======

    function test_batch_spendingLimit_appliesPerItem() public {
        wallet.setMaxTransactionAmount(address(token), 5e6);

        TakumiPay.TransactionParams[] memory params = new TakumiPay.TransactionParams[](2);
        params[0] = TakumiPay.TransactionParams("b", 1, "v", address(token), "under", 4e6);
        params[1] = TakumiPay.TransactionParams("b", 1, "v", address(token), "at", 5e6);
        vm.prank(payer);
        wallet.createTransactionBatch(params);

        params = new TakumiPay.TransactionParams[](1);
        params[0] = TakumiPay.TransactionParams("b", 1, "v", address(token), "over", 5e6 + 1);
        vm.prank(payer);
        vm.expectRevert(TakumiPay.ExceedsSpendingLimit.selector);
        wallet.createTransactionBatch(params);
    }

    // ====== Pagination (1011, 1021, 1022, 1025, 1058, 1061) ======

    /// Amounts 1, 2, 3, so a transaction's amount is its position.
    function _bookThree() internal {
        _book("p-1", 1);
        _book("p-2", 2);
        _book("p-3", 3);
    }

    function test_getTransactionsByAddress_pagesWithOffset() public {
        _bookThree();

        TakumiPay.Transaction[] memory page = wallet.getTransactionsByAddress(payer, 1, 10);
        assertEq(page.length, 2);
        assertEq(page[0].amount, 2);
        assertEq(page[1].amount, 3);

        page = wallet.getTransactionsByAddress(payer, 2, 1);
        assertEq(page.length, 1);
        assertEq(page[0].amount, 3);

        assertEq(wallet.getTransactionsByAddress(payer, 3, 10).length, 0);
    }

    function test_revert_getTransactionsByAddress_limitTooLarge() public {
        vm.expectRevert(TakumiPay.LimitTooLarge.selector);
        wallet.getTransactionsByAddress(payer, 0, 501);
    }

    function test_getTransactionsInRange_pagesWithOffset() public {
        _bookThree();

        TakumiPay.Transaction[] memory page = wallet.getTransactionsInRange(0, type(uint256).max, 1, 10);
        assertEq(page.length, 2);
        assertEq(page[0].amount, 2);
        assertEq(page[1].amount, 3);
    }

    // ====== Allowlist swap-and-pop (1247) ======

    function test_removeAllowedPaymentToken_fromTheMiddle() public {
        address a = address(new HookToken());
        address b = address(new HookToken());
        address c = address(new HookToken());
        wallet.addAllowedPaymentToken(a);
        wallet.addAllowedPaymentToken(b);
        wallet.addAllowedPaymentToken(c);

        wallet.removeAllowedPaymentToken(b);
        address[] memory list = wallet.getAllowedPaymentTokens();
        assertEq(list.length, 3);
        assertEq(list[0], address(token));
        assertEq(list[1], a);
        assertEq(list[2], c, "the last entry moves into the gap");
        assertFalse(wallet.isAllowedPaymentToken(b));

        // c's index was updated by the move, so removing it now works too.
        wallet.removeAllowedPaymentToken(c);
        list = wallet.getAllowedPaymentTokens();
        assertEq(list.length, 2);
        assertEq(list[1], a);
    }
}
