// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TakumiPay.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// ERC-20 whose decimals() can be set, and changed later, to stand in for any alias token.
contract DecimalsToken is ERC20 {
    uint8 private _decimals;

    constructor(uint8 decimals_) ERC20("Token", "TKN") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function setDecimals(uint8 decimals_) external {
        _decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Regression tests for the Olympix BugPoCer scan of 2.2.0 (commit af071e0).
///         Test names carry the report's section numbers; the dispositions are in
///         docs/olympix-bugpocer-response-2.2.0.md.
///
///         Time is read with vm.getBlockTimestamp(), never block.timestamp: with via_ir
///         the optimizer may reuse a block.timestamp read from before a vm.warp, so
///         `vm.warp(block.timestamp + x)` twice in one test can land on the same time.
contract TakumiPayAuditFixesTest is Test {
    TakumiPay public wallet;
    DecimalsToken public usdc;

    address public owner;
    uint256 internal signerKey = 0xA11CE;
    address public payer;
    address public recipient;

    bytes32 internal constant UPGRADE_KEY = keccak256("upgrade");
    uint256 internal constant UNLIMITED = type(uint256).max;

    uint256 private _refNonce;

    function setUp() public {
        owner = address(this);
        payer = makeAddr("payer");
        recipient = makeAddr("recipient");

        wallet = _deploy(address(0));
        usdc = new DecimalsToken(6);
        wallet.addAllowedPaymentToken(address(usdc));
        usdc.mint(payer, 1_000_000e6);
        vm.prank(payer);
        usdc.approve(address(wallet), type(uint256).max);
    }

    // ====== Helpers ======

    function _deploy(address aliasToken) internal returns (TakumiPay) {
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(new TakumiPay()),
            abi.encodeCall(TakumiPay.initialize, (owner, vm.addr(signerKey), aliasToken))
        );
        return TakumiPay(payable(address(proxy)));
    }

    /// Queue + apply, which lands at once only while withdrawalDelay is 0.
    function _setSweepCap(address token, uint256 cap) internal {
        wallet.queueSweepCap(token, cap);
        wallet.applySweepCap(token);
    }

    /// Puts `amount` of usdc in the contract through a booking.
    function _fund(uint256 amount) internal {
        vm.prank(payer);
        wallet.createTransaction("b", 1, "v", address(usdc), string.concat("fund-", vm.toString(++_refNonce)), amount);
    }

    function _payMerchant(string memory refId, uint256 amount, uint256 fee) internal {
        TakumiPay.QuoteCommitment memory quote = TakumiPay.QuoteCommitment({
            refId: refId,
            merchantId: "merchant-001",
            tokenAddress: address(usdc),
            amount: amount,
            platformFeeAmount: fee,
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
        vm.prank(payer);
        wallet.processMerchantPayment(quote, abi.encodePacked(r, s, v));
    }

    function _implementation() internal view returns (address) {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        return address(uint160(uint256(vm.load(address(wallet), slot))));
    }

    // ====== 5.1.1: a squatted quote refId leaves the merchant record intact ======

    /// The PoC's sequence: a 1-unit booking claims the quote's ULID first, then the
    /// payer pays. Both succeed by design. The merchant record, which is all that
    /// settlement reads, names the real payer and the quoted amount; the booking under
    /// the same string is a separate record that the API would reject on amount.
    function test_5_1_1_bookingSquat_merchantRecordStillNamesPayer() public {
        string memory ulid = "01HZXK3V8Q7M2N4P6R8T0W2Y4A";
        address attacker = makeAddr("attacker");
        usdc.mint(attacker, 1);
        vm.startPrank(attacker);
        usdc.approve(address(wallet), 1);
        wallet.createTransaction("b", 1, "v", address(usdc), ulid, 1);
        vm.stopPrank();

        _payMerchant(ulid, 10e6, 0.5e6);

        TakumiPay.MerchantPayment memory payment = wallet.getMerchantPaymentByRef(ulid);
        assertEq(payment.payer, payer);
        assertEq(payment.amount, 10e6);
        TakumiPay.Transaction memory squat = wallet.getTransactionByRef(ulid);
        assertEq(squat.walletAddress, attacker);
        assertEq(squat.amount, 1);
    }

    function test_5_1_1_depositSquat_merchantRecordStillNamesPayer() public {
        string memory ulid = "01HZXK3V8Q7M2N4P6R8T0W2Y4B";
        address attacker = makeAddr("attacker");
        usdc.mint(attacker, 1);
        vm.startPrank(attacker);
        usdc.approve(address(wallet), 1);
        wallet.depositPoints(address(usdc), ulid, 1);
        vm.stopPrank();

        _payMerchant(ulid, 10e6, 0.5e6);

        assertEq(wallet.getMerchantPaymentByRef(ulid).payer, payer);
        assertEq(wallet.getPointDepositByRef(ulid).walletAddress, attacker);
    }

    // ====== 5.1.2: rescueNativeDust stays dust whatever the alias is ======

    /// The report's path on a non-Arc chain: alias unset, so the owner key points it at
    /// a token reporting 0 decimals, which used to make the "dust" up to 1e18 - 1 wei.
    function test_5_1_2_revert_rescueNativeDust_zeroDecimalAlias() public {
        DecimalsToken evil = new DecimalsToken(0);
        wallet.setNativeAliasToken(address(evil));
        vm.deal(address(wallet), 1 ether - 1);

        vm.expectRevert(TakumiPay.AliasDecimalsUnsupported.selector);
        wallet.rescueNativeDust(recipient);
        assertEq(address(wallet).balance, 1 ether - 1);
    }

    /// decimals() is read at call time, so an alias that passed as 6 decimals and
    /// later reports fewer is refused too.
    function test_5_1_2_revert_rescueNativeDust_aliasLowersDecimalsLater() public {
        DecimalsToken shifty = new DecimalsToken(6);
        wallet.setNativeAliasToken(address(shifty));
        shifty.setDecimals(5);
        vm.deal(address(wallet), 1 ether - 1);

        vm.expectRevert(TakumiPay.AliasDecimalsUnsupported.selector);
        wallet.rescueNativeDust(recipient);
    }

    function testFuzz_5_1_2_rescueNativeDust_neverReaches1e12(uint8 aliasDecimals, uint256 balance) public {
        aliasDecimals = uint8(bound(aliasDecimals, 0, 30));
        balance = bound(balance, 0, 1e30);
        wallet.setNativeAliasToken(address(new DecimalsToken(aliasDecimals)));
        vm.deal(address(wallet), balance);

        if (aliasDecimals < 6) {
            vm.expectRevert(TakumiPay.AliasDecimalsUnsupported.selector);
            wallet.rescueNativeDust(recipient);
            return;
        }
        uint256 dust = aliasDecimals >= 18 ? 0 : balance % 10 ** (18 - aliasDecimals);
        if (dust == 0) {
            vm.expectRevert(TakumiPay.ZeroAmount.selector);
            wallet.rescueNativeDust(recipient);
            return;
        }
        wallet.rescueNativeDust(recipient);
        assertEq(recipient.balance, dust);
        assertLt(recipient.balance, 1e12);
    }

    // ====== 5.2.1: raising the delay reaches entries queued under a shorter one ======

    /// 5.2.1f: an upgrade queued while the delay was 0 (runbook steps 1-3) used to stay
    /// instantly applicable after step 4 raised the delay.
    function test_5_2_1_delayRaise_rearmsUpgradeQueuedAtZeroDelay() public {
        address impl = address(new TakumiPay());
        wallet.queueUpgrade(impl);
        uint256 raisedAt = vm.getBlockTimestamp();
        wallet.setWithdrawalDelay(1 days);
        assertEq(wallet.withdrawalDelayRaisedAt(), raisedAt);

        vm.expectRevert(TakumiPay.TimelockNotExpired.selector);
        wallet.upgradeToAndCall(impl, "");

        vm.warp(raisedAt + 1 days - 1);
        vm.expectRevert(TakumiPay.TimelockNotExpired.selector);
        wallet.upgradeToAndCall(impl, "");

        vm.warp(raisedAt + 1 days);
        wallet.upgradeToAndCall(impl, "");
        assertEq(_implementation(), impl);
    }

    /// 5.2.1c/g: an unlimited cap raise left pending from setup.
    function test_5_2_1_delayRaise_rearmsCapRaiseQueuedAtZeroDelay() public {
        wallet.queueSweepCap(address(usdc), UNLIMITED);
        uint256 raisedAt = vm.getBlockTimestamp();
        wallet.setWithdrawalDelay(1 days);

        vm.warp(raisedAt + 1 days - 1);
        vm.expectRevert(TakumiPay.TimelockNotExpired.selector);
        wallet.applySweepCap(address(usdc));

        vm.warp(raisedAt + 1 days);
        wallet.applySweepCap(address(usdc));
        assertEq(wallet.sweepCap(address(usdc)), UNLIMITED);
    }

    /// 5.2.1b/d/e: a cut to 0 queued under a 1h delay must not undo a later raise to
    /// 7 days once the hour is up.
    function test_5_2_1_delayRaise_rearmsPendingDelayCut() public {
        wallet.setWithdrawalDelay(1 hours);
        wallet.queueWithdrawalDelay(0);

        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        uint256 raisedAt = vm.getBlockTimestamp();
        wallet.setWithdrawalDelay(7 days);

        vm.warp(raisedAt + 1 hours);
        vm.expectRevert(TakumiPay.TimelockNotExpired.selector);
        wallet.applyWithdrawalDelay();

        vm.warp(raisedAt + 7 days - 1);
        vm.expectRevert(TakumiPay.TimelockNotExpired.selector);
        wallet.applyWithdrawalDelay();

        vm.warp(raisedAt + 7 days);
        wallet.applyWithdrawalDelay();
        assertEq(wallet.withdrawalDelay(), 0);
    }

    /// 5.2.1a: queued withdrawals are re-armed the same way.
    function test_5_2_1_delayRaise_rearmsQueuedWithdrawal() public {
        _setSweepCap(address(usdc), 100e6);
        _fund(10e6);
        wallet.setWithdrawalDelay(1 days);
        bytes32 id = wallet.queueWithdrawal(address(usdc), recipient, 5e6);

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        uint256 raisedAt = vm.getBlockTimestamp();
        wallet.setWithdrawalDelay(7 days);

        vm.warp(raisedAt + 1 days); // the request's own unlock time has passed
        vm.expectRevert(TakumiPay.TimelockNotExpired.selector);
        wallet.executeWithdrawal(id);

        vm.warp(raisedAt + 7 days);
        wallet.executeWithdrawal(id);
        assertEq(usdc.balanceOf(recipient), 5e6);
    }

    /// Calling setWithdrawalDelay with the current value restarts the clock on what is
    /// queued without changing the delay.
    function test_5_2_1_reassertingDelay_restartsClock() public {
        wallet.setWithdrawalDelay(1 days);
        address impl = address(new TakumiPay());
        wallet.queueUpgrade(impl);

        vm.warp(vm.getBlockTimestamp() + 12 hours);
        uint256 reassertedAt = vm.getBlockTimestamp();
        wallet.setWithdrawalDelay(1 days);
        assertEq(wallet.withdrawalDelay(), 1 days);

        vm.warp(reassertedAt + 12 hours); // the entry's own unlock time has passed
        vm.expectRevert(TakumiPay.TimelockNotExpired.selector);
        wallet.upgradeToAndCall(impl, "");

        vm.warp(reassertedAt + 1 days);
        wallet.upgradeToAndCall(impl, "");
    }

    /// Entries queued after the raise unlock exactly when they always did.
    function test_5_2_1_entryQueuedAfterRaise_unlocksOnItsOwnTime() public {
        wallet.setWithdrawalDelay(1 days);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        wallet.queueSweepCap(address(usdc), 1e6);

        vm.warp(vm.getBlockTimestamp() + 1 days - 1);
        vm.expectRevert(TakumiPay.TimelockNotExpired.selector);
        wallet.applySweepCap(address(usdc));

        vm.warp(vm.getBlockTimestamp() + 1);
        wallet.applySweepCap(address(usdc));
        assertEq(wallet.sweepCap(address(usdc)), 1e6);
    }

    // ====== 5.2.2: no 24h span sees more than the cap leave ======

    enum Exit {
        SweepPlatformFees,
        RecoverToken,
        Withdraw,
        SweepMerchantBacking,
        ExecuteWithdrawal,
        WithdrawAll
    }

    /// Prepares `exit` so that three calls of `amounts[i]` are possible, then returns
    /// the ids of any queued withdrawals. Everything is funded far beyond the cap, so
    /// only the cap can stop an exit.
    function _prepareExit(Exit exit, uint256[3] memory amounts) internal returns (bytes32[3] memory ids) {
        if (exit == Exit.SweepPlatformFees) {
            _payMerchant("fees", 100e6, 100e6);
        } else if (exit == Exit.ExecuteWithdrawal) {
            _fund(100e6);
            wallet.setWithdrawalDelay(1 hours);
            for (uint256 i = 0; i < 3; i++) {
                ids[i] = wallet.queueWithdrawal(address(usdc), recipient, amounts[i]);
            }
            vm.warp(vm.getBlockTimestamp() + 1 hours);
        } else if (exit != Exit.WithdrawAll) {
            _fund(100e6);
        }
    }

    function _exit(Exit exit, uint256 amount, bytes32 id) internal {
        address t = address(usdc);
        if (exit == Exit.SweepPlatformFees) wallet.sweepPlatformFees(t, recipient, amount);
        else if (exit == Exit.RecoverToken) wallet.recoverToken(t, recipient, amount);
        else if (exit == Exit.Withdraw) wallet.withdraw(t, recipient, amount);
        else if (exit == Exit.SweepMerchantBacking) wallet.sweepMerchantBacking(t, recipient, amount);
        else if (exit == Exit.ExecuteWithdrawal) wallet.executeWithdrawal(id);
        else {
            _fund(amount); // withdrawAll takes the whole balance, so hold exactly `amount`
            wallet.withdrawAll(t, recipient);
        }
    }

    /// The report's attack path (5.2.2d spells it out): a small exit s opens the old
    /// window at W, cap - s leaves at W + 1 day - 1s, then a full cap at W + 1 day. The
    /// third exit must fail, because the trailing 24 hours still hold cap - s.
    function _assertNoBoundaryBurst(Exit exit) internal {
        uint256 cap = 10e6;
        uint256 s = 1e6;
        uint256[3] memory amounts = [s, cap - s, cap];
        _setSweepCap(address(usdc), cap); // before _prepareExit, which may set a delay
        bytes32[3] memory ids = _prepareExit(exit, amounts);

        uint256 w = vm.getBlockTimestamp();
        _exit(exit, s, ids[0]);
        vm.warp(w + 1 days - 1);
        _exit(exit, cap - s, ids[1]);

        vm.warp(w + 1 days);
        assertEq(wallet.sweepAllowance(address(usdc)), s, "only the expired exit's share is back");
        vm.expectRevert(TakumiPay.SweepCapExceeded.selector);
        this.exitExternally(exit, cap, ids[2]);
        assertEq(usdc.balanceOf(recipient), cap, "exactly one cap left in the trailing 24h");
    }

    /// External hop so vm.expectRevert sees the exit as the next call even when _exit
    /// funds first.
    function exitExternally(Exit exit, uint256 amount, bytes32 id) external {
        _exit(exit, amount, id);
    }

    function test_5_2_2a_noBoundaryBurst_sweepPlatformFees() public {
        _assertNoBoundaryBurst(Exit.SweepPlatformFees);
    }

    function test_5_2_2b_noBoundaryBurst_recoverToken() public {
        _assertNoBoundaryBurst(Exit.RecoverToken);
    }

    function test_5_2_2c_noBoundaryBurst_withdraw() public {
        _assertNoBoundaryBurst(Exit.Withdraw);
    }

    function test_5_2_2d_noBoundaryBurst_sweepMerchantBacking() public {
        _assertNoBoundaryBurst(Exit.SweepMerchantBacking);
    }

    function test_5_2_2e_noBoundaryBurst_executeWithdrawal() public {
        _assertNoBoundaryBurst(Exit.ExecuteWithdrawal);
    }

    function test_5_2_2f_noBoundaryBurst_withdrawAll() public {
        _assertNoBoundaryBurst(Exit.WithdrawAll);
    }

    /// Each exit's share of the cap comes back exactly 24 hours after it was made.
    function test_5_2_2_eachExitFreesItsShareExactly24hLater() public {
        _fund(100e6);
        _setSweepCap(address(usdc), 24e6);

        uint256 t = vm.getBlockTimestamp();
        wallet.sweepMerchantBacking(address(usdc), recipient, 10e6);
        vm.warp(t + 6 hours);
        wallet.sweepMerchantBacking(address(usdc), recipient, 14e6);
        assertEq(wallet.sweepAllowance(address(usdc)), 0);

        vm.warp(t + 1 days - 1);
        assertEq(wallet.sweepAllowance(address(usdc)), 0);
        vm.expectRevert(TakumiPay.SweepCapExceeded.selector);
        wallet.sweepMerchantBacking(address(usdc), recipient, 1);

        vm.warp(t + 1 days);
        assertEq(wallet.sweepAllowance(address(usdc)), 10e6);
        vm.warp(t + 1 days + 6 hours);
        assertEq(wallet.sweepAllowance(address(usdc)), 24e6);
    }

    /// The invariant itself: across a random mix of capped exits at random times, no
    /// two exits less than 24 hours apart, together with everything between them, ever
    /// add up to more than the cap.
    function testFuzz_5_2_2_noDaySeesMoreThanTheCap(uint256 seed) public {
        uint256 cap = 10e6;
        _fund(10_000e6);
        _setSweepCap(address(usdc), cap);

        uint256 n = 32;
        uint256[] memory at = new uint256[](n);
        uint256[] memory out = new uint256[](n);
        uint256 count;
        for (uint256 i = 0; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(vm.getBlockTimestamp() + r % 8 hours);
            uint256 amount = 1 + (r >> 64) % cap;
            bool ok;
            if ((r >> 128) % 2 == 0) {
                try wallet.sweepMerchantBacking(address(usdc), recipient, amount) {
                    ok = true;
                } catch {}
            } else {
                try wallet.withdraw(address(usdc), recipient, amount) {
                    ok = true;
                } catch {}
            }
            if (ok) {
                at[count] = vm.getBlockTimestamp();
                out[count] = amount;
                count++;
            }
        }

        for (uint256 i = 0; i < count; i++) {
            uint256 sum;
            for (uint256 j = i; j < count && at[j] < at[i] + 1 days; j++) {
                sum += out[j];
                assertLe(sum, cap);
            }
        }
    }

    /// A live log entry is never overwritten: the 17th exit inside 24 hours waits for
    /// the oldest one to expire.
    function test_5_2_2_logHoldsSixteenExitsPerDay() public {
        _fund(100e6);
        _setSweepCap(address(usdc), 100e6);

        uint256 t = vm.getBlockTimestamp();
        for (uint256 i = 0; i < 16; i++) {
            vm.warp(t + i * 1 hours);
            wallet.sweepMerchantBacking(address(usdc), recipient, 1e6);
        }
        assertEq(wallet.sweepAllowance(address(usdc)), 0, "full log reports nothing left");
        vm.expectRevert(TakumiPay.SweepLogFull.selector);
        wallet.sweepMerchantBacking(address(usdc), recipient, 1e6);

        vm.warp(t + 1 days);
        assertEq(wallet.sweepAllowance(address(usdc)), 85e6);
        wallet.sweepMerchantBacking(address(usdc), recipient, 1e6);
    }

    /// Lowering the cap below what the trailing 24 hours already hold stops exits until
    /// those exits expire.
    function test_5_2_2_loweringCapBelowUsage_holdsExits() public {
        _fund(100e6);
        _setSweepCap(address(usdc), 10e6);
        wallet.sweepMerchantBacking(address(usdc), recipient, 10e6);
        wallet.setSweepCap(address(usdc), 1e6);

        vm.warp(vm.getBlockTimestamp() + 12 hours);
        assertEq(wallet.sweepAllowance(address(usdc)), 0);

        vm.warp(vm.getBlockTimestamp() + 12 hours);
        assertEq(wallet.sweepAllowance(address(usdc)), 1e6);
    }

    function test_5_2_2_hugeCap_doesNotOverflow() public {
        _fund(100e6);
        uint256 cap = UNLIMITED - 1;
        _setSweepCap(address(usdc), cap);
        wallet.sweepMerchantBacking(address(usdc), recipient, 10e6);
        assertEq(wallet.sweepAllowance(address(usdc)), cap - 10e6);
        wallet.sweepMerchantBacking(address(usdc), recipient, 10e6);

        // Amounts are packed into 192 bits; anything wider is refused, not truncated.
        vm.expectRevert(TakumiPay.SweepCapExceeded.selector);
        wallet.recoverToken(address(usdc), recipient, uint256(1) << 192);
    }

    function test_5_2_2_sweepAllowance_unsetAndUnlimited() public {
        assertEq(wallet.sweepAllowance(address(usdc)), 0, "unset cap fails closed");
        _setSweepCap(address(usdc), UNLIMITED);
        assertEq(wallet.sweepAllowance(address(usdc)), UNLIMITED);
    }

    // ====== 5.2.4: the brake cancels a queued raise ======

    function test_5_2_4_brakeCancelsQueuedRaise() public {
        _setSweepCap(address(usdc), 10e6);
        wallet.setWithdrawalDelay(1 days);
        wallet.queueSweepCap(address(usdc), UNLIMITED);

        bytes32 key = keccak256(abi.encode("sweepCap", address(usdc)));
        vm.expectEmit(true, false, false, false);
        emit TakumiPay.PendingChangeCancelled(key);
        vm.expectEmit(true, false, false, true);
        emit TakumiPay.SweepCapUpdated(address(usdc), 0);
        wallet.setSweepCap(address(usdc), 0);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert(TakumiPay.NoPendingChange.selector);
        wallet.applySweepCap(address(usdc));
        assertEq(wallet.sweepCap(address(usdc)), 0);
    }

    function test_5_2_4_brakeWithNothingQueued_emitsOnlyTheCapUpdate() public {
        _setSweepCap(address(usdc), 10e6);
        vm.recordLogs();
        wallet.setSweepCap(address(usdc), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], TakumiPay.SweepCapUpdated.selector);
    }

    // ====== 5.2.5: the fee ledger stays backed ======

    /// 5.2.5b: the non-fee sweep cannot take what backs accrued fees.
    function test_5_2_5b_merchantBackingCannotTakeAccruedFees() public {
        _setSweepCap(address(usdc), UNLIMITED);
        _payMerchant("m-1", 10e6, 0.5e6);

        vm.expectRevert(TakumiPay.InsufficientBalance.selector);
        wallet.sweepMerchantBacking(address(usdc), recipient, 10e6);

        wallet.sweepMerchantBacking(address(usdc), recipient, 9.5e6);
        wallet.sweepPlatformFees(address(usdc), recipient, 0.5e6);
        assertEq(usdc.balanceOf(address(wallet)), 0);
        assertEq(wallet.platformFeeAccrued(address(usdc)), 0);
    }

    /// 5.2.5a/c: a whole-treasury exit that takes fee-backed balance books those fees
    /// as swept to its recipient, so the ledger never claims fees that already left.
    function test_5_2_5c_withdrawAll_booksTheFeesItTookAsSwept() public {
        _setSweepCap(address(usdc), UNLIMITED);
        _payMerchant("m-1", 10e6, 0.5e6);

        vm.expectEmit(true, true, false, true, address(wallet));
        emit TakumiPay.PlatformFeesSwept(address(usdc), recipient, 0.5e6);
        wallet.withdrawAll(address(usdc), recipient);
        assertEq(wallet.platformFeeAccrued(address(usdc)), 0);

        // New float is float again, not fees counted twice.
        _fund(1e6);
        wallet.sweepMerchantBacking(address(usdc), recipient, 1e6);
    }

    /// Only the part of the fees that actually left is booked.
    function test_5_2_5a_partialWithdraw_booksOnlyTheFeesItTook() public {
        _setSweepCap(address(usdc), UNLIMITED);
        _payMerchant("m-1", 10e6, 0.5e6);

        vm.expectEmit(true, true, false, true, address(wallet));
        emit TakumiPay.PlatformFeesSwept(address(usdc), recipient, 0.3e6);
        wallet.withdraw(address(usdc), recipient, 9.8e6);
        assertEq(wallet.platformFeeAccrued(address(usdc)), 0.2e6);
        wallet.sweepPlatformFees(address(usdc), recipient, 0.2e6);
    }

    /// A whole-treasury exit that leaves the fee-backed balance alone books nothing.
    function test_5_2_5a_withdrawAboveFees_leavesLedgerAlone() public {
        _setSweepCap(address(usdc), UNLIMITED);
        _payMerchant("m-1", 10e6, 0.5e6);

        vm.recordLogs();
        wallet.withdraw(address(usdc), recipient, 9.5e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != TakumiPay.PlatformFeesSwept.selector);
        }
        assertEq(wallet.platformFeeAccrued(address(usdc)), 0.5e6);
    }

    function test_5_2_5a_executeWithdrawalAndRecoverToken_keepLedgerBacked() public {
        _setSweepCap(address(usdc), UNLIMITED);
        _payMerchant("m-1", 10e6, 0.5e6);

        wallet.recoverToken(address(usdc), recipient, 9.6e6);
        assertEq(wallet.platformFeeAccrued(address(usdc)), 0.4e6);

        wallet.setWithdrawalDelay(1 days);
        bytes32 id = wallet.queueWithdrawal(address(usdc), recipient, 0.4e6);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        wallet.executeWithdrawal(id);
        assertEq(wallet.platformFeeAccrued(address(usdc)), 0);
    }

    /// 5.2.5b's knock-on: a native fee ledger emptied by a withdrawal no longer blocks
    /// setNativeAliasToken.
    function test_5_2_5_nativeWithdrawAll_unblocksNativeAlias() public {
        wallet.addAllowedPaymentToken(address(0));
        _setSweepCap(address(0), UNLIMITED);
        vm.store(
            address(wallet), keccak256(abi.encode(address(0), uint256(24))), bytes32(uint256(0.01 ether))
        ); // platformFeeAccrued[native], slot 24
        vm.deal(address(wallet), 0.01 ether);
        assertEq(wallet.platformFeeAccrued(address(0)), 0.01 ether);

        wallet.withdrawAll(address(0), recipient);
        assertEq(wallet.platformFeeAccrued(address(0)), 0);

        wallet.removeAllowedPaymentToken(address(0));
        wallet.setSweepCap(address(0), 0);
        wallet.setNativeAliasToken(address(usdc));
    }

    // ====== 5.2.9: the upgrade queue is bound to code ======

    function test_5_2_9_revert_queueUpgrade_addressWithoutCode() public {
        vm.expectRevert(TakumiPay.NoImplementationCode.selector);
        wallet.queueUpgrade(makeAddr("counterfactual"));
    }

    function test_5_2_9_queueStoresCodehash() public {
        address impl = address(new TakumiPay());
        wallet.queueUpgrade(impl);
        assertEq(bytes32(wallet.getPendingChange(UPGRADE_KEY).value), impl.codehash);
    }

    /// vm.etch stands in for any way the code at the queued address could change
    /// after queuing: what runs must be what waited out the delay.
    function test_5_2_9_revert_upgrade_whenCodeChangedAfterQueue() public {
        wallet.setWithdrawalDelay(1 days);
        address impl = address(new TakumiPay());
        wallet.queueUpgrade(impl);

        vm.etch(impl, address(new TakumiPay()).code);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert(TakumiPay.UpgradeNotQueued.selector);
        wallet.upgradeToAndCall(impl, "");
    }
}
