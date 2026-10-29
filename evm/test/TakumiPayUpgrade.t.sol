// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TakumiPay.sol";
import "./legacy/TakumiPay210.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract UpgradeUsdc is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice The 2.1.0 -> 2.3.0 upgrade, without a fork. Every live proxy runs 2.1.0
///         (deployments/*.json), so setUp builds one the way the runbook configures it
///         and gives it traffic: bookings, a batch, a point deposit, a merchant payment
///         with a fee, a sweep part-way through its window, a delay, a queued withdrawal
///         and a queued cap raise. Each test then upgrades it with the single owner call
///         2.1.0 allows. TakumiPayUpgrade.fork.t.sol rehearses the same upgrade on forks
///         of the live proxies.
///
///         Time is read with vm.getBlockTimestamp(); see TakumiPayAuditFixes.t.sol.
contract TakumiPayUpgradeTest is Test {
    TakumiPay210 internal legacy; // the proxy through the 2.1.0 ABI
    TakumiPay internal wallet; // the same proxy through the 2.3.0 ABI
    UpgradeUsdc internal usdc;

    address internal owner;
    uint256 internal signerKey = 0xA11CE;
    address internal payer;
    address internal admin;
    address internal recipient;

    uint256 internal t0;
    bytes32 internal withdrawalId;

    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// owner (0) through __gap's last slot: slots 0-29 + a 45-slot gap in 2.1.0,
    /// slots 0-31 + a 43-slot gap in 2.3.0.
    uint256 internal constant LAST_SLOT = 74;

    function setUp() public {
        // A live chain's clock. At forge's default of 1, 2.1.0's first sweep would not
        // stamp a window start (1 < 0 + 1 days), which no real chain can hit.
        vm.warp(1_790_000_000);
        owner = address(this);
        payer = makeAddr("payer");
        admin = makeAddr("admin");
        recipient = makeAddr("recipient");

        legacy = _deploy210();
        wallet = TakumiPay(payable(address(legacy)));

        usdc = new UpgradeUsdc();
        usdc.mint(payer, 1_000e6);
        vm.prank(payer);
        usdc.approve(address(legacy), type(uint256).max);

        // Runbook steps 2-3 while the delay is 0.
        legacy.addAllowedPaymentToken(address(usdc));
        legacy.queueSweepCap(address(usdc), 50e6);
        legacy.applySweepCap(address(usdc));
        legacy.addAdmin(admin);
        legacy.setMaxTransactionAmount(address(usdc), 1_000e6);

        vm.startPrank(payer);
        legacy.createTransaction("booking-1", 7, "variant-1", address(usdc), "ref-b1", 20e6);
        TakumiPay210.TransactionParams[] memory batch = new TakumiPay210.TransactionParams[](2);
        batch[0] = TakumiPay210.TransactionParams("booking-2", 7, "variant-2", address(usdc), "ref-b2", 5e6);
        batch[1] = TakumiPay210.TransactionParams("booking-3", 8, "variant-3", address(usdc), "ref-b3", 5e6);
        legacy.createTransactionBatch(batch);
        legacy.depositPoints(address(usdc), "ref-d1", 30e6);
        vm.stopPrank();
        _payMerchant("ref-m1", 40e6, 2e6);

        t0 = vm.getBlockTimestamp();
        legacy.sweepMerchantBacking(address(usdc), recipient, 30e6);

        // Step 4, then state that is still queued when the upgrade lands.
        legacy.setWithdrawalDelay(1 days);
        withdrawalId = legacy.queueWithdrawal(address(usdc), recipient, 5e6);
        legacy.queueSweepCap(address(usdc), 80e6);

        vm.warp(t0 + 6 hours);
    }

    // ====== Helpers ======

    function _deploy210() internal returns (TakumiPay210) {
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(new TakumiPay210()), abi.encodeCall(TakumiPay210.initialize, (owner, vm.addr(signerKey)))
        );
        return TakumiPay210(payable(address(proxy)));
    }

    function _upgrade() internal returns (address impl) {
        impl = address(new TakumiPay());
        legacy.upgradeToAndCall(impl, ""); // 2.1.0 authorizes the owner with no queue
    }

    function _signedQuote(string memory refId, uint256 amount, uint256 fee)
        internal
        view
        returns (TakumiPay.QuoteCommitment memory quote, bytes memory sig)
    {
        quote = TakumiPay.QuoteCommitment({
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
        sig = abi.encodePacked(r, s, v);
    }

    /// Pays through whichever implementation is live: the quote struct and its ABI
    /// encoding are the same in 2.1.0 and 2.3.0.
    function _payMerchant(string memory refId, uint256 amount, uint256 fee) internal {
        (TakumiPay.QuoteCommitment memory quote, bytes memory sig) = _signedQuote(refId, amount, fee);
        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);
    }

    function _slots() internal view returns (bytes32[] memory slots) {
        slots = new bytes32[](LAST_SLOT + 1);
        for (uint256 i = 0; i <= LAST_SLOT; i++) {
            slots[i] = vm.load(address(wallet), bytes32(i));
        }
    }

    function _withdrawal(bytes32 id) internal view returns (bytes memory) {
        (address token, address to, uint256 amount, uint256 unlockTime, bool executed, bool cancelled) =
            wallet.withdrawalRequests(id);
        return abi.encode(token, to, amount, unlockTime, executed, cancelled);
    }

    /// Everything a client or the owner can read, through getters both versions share.
    function _state() internal view returns (bytes memory) {
        address t = address(usdc);
        return bytes.concat(
            abi.encode(
                wallet.owner(),
                wallet.pendingOwner(),
                wallet.backendSigner(),
                wallet.paused(),
                wallet.pointDepositsPaused(),
                wallet.withdrawalDelay(),
                wallet.nativeAliasToken(),
                wallet.DOMAIN_SEPARATOR()
            ),
            abi.encode(wallet.getAllAdmins(), wallet.getAllowedPaymentTokens(), wallet.maxTransactionAmount(t)),
            abi.encode(
                wallet.txCounter(),
                wallet.pointDepositCounter(),
                wallet.getTransactionByRef("ref-b1"),
                wallet.getTransactionByRef("ref-b3"),
                wallet.getPointDepositByRef("ref-d1"),
                wallet.getMerchantPaymentByRef("ref-m1")
            ),
            abi.encode(
                wallet.platformFeeAccrued(t), wallet.sweepCap(t), wallet.sweptInWindow(t), wallet.sweepWindowStart(t)
            ),
            abi.encode(wallet.getPendingChange(keccak256(abi.encode("sweepCap", t))), _withdrawal(withdrawalId)),
            abi.encode(wallet.getTransactionsByAddress(payer, 0, 10), wallet.getPointDepositsByAddress(payer, 0, 10))
        );
    }

    // ====== State ======

    function test_upgrade_preservesEveryReadableValue() public {
        assertEq(wallet.version(), "2.1.0");
        bytes memory before = _state();

        address impl = _upgrade();

        assertEq(wallet.version(), "2.3.0");
        assertEq(address(uint160(uint256(vm.load(address(wallet), IMPLEMENTATION_SLOT)))), impl);
        assertEq(_state(), before);
        assertEq(wallet.withdrawalDelayRaisedAt(), 0);
    }

    /// The upgrade only rewrites the implementation slot. owner through the end of
    /// __gap read the same afterwards, and slots 30-74 (2.1.0's whole __gap, which
    /// now holds withdrawalDelayRaisedAt, _sweepLog's mapping slot and a 43-slot
    /// __gap) are still empty.
    function test_upgrade_leavesEveryContractSlotUntouched() public {
        bytes32[] memory before = _slots();
        _upgrade();
        bytes32[] memory afterUpgrade = _slots();

        for (uint256 i = 0; i <= LAST_SLOT; i++) {
            assertEq(afterUpgrade[i], before[i]);
        }
        for (uint256 i = 30; i <= LAST_SLOT; i++) {
            assertEq(afterUpgrade[i], bytes32(0));
        }
    }

    /// withdrawalDelayRaisedAt lands at slot 30: right after nativeAliasToken (29), in
    /// what was the first slot of 2.1.0's __gap.
    function test_upgrade_newSlotIsTheFirstGapSlot() public {
        _upgrade();
        vm.warp(t0 + 7 hours);
        wallet.setWithdrawalDelay(2 days);

        assertEq(uint256(vm.load(address(wallet), bytes32(uint256(30)))), t0 + 7 hours);
        assertEq(wallet.withdrawalDelayRaisedAt(), t0 + 7 hours);
        assertEq(uint256(vm.load(address(wallet), bytes32(uint256(7)))), 2 days); // withdrawalDelay
    }

    // ====== Behaviour carried across the upgrade ======

    /// Entries queued under 2.1.0 keep their unlock time: the re-arm slot is 0 until
    /// the delay is next set.
    function test_upgrade_queuedEntriesKeepTheirUnlockTime() public {
        _upgrade();

        vm.warp(t0 + 1 days - 1);
        vm.expectRevert(TakumiPay.TimelockNotExpired.selector);
        wallet.executeWithdrawal(withdrawalId);
        vm.expectRevert(TakumiPay.TimelockNotExpired.selector);
        wallet.applySweepCap(address(usdc));

        vm.warp(t0 + 1 days);
        wallet.executeWithdrawal(withdrawalId);
        wallet.applySweepCap(address(usdc));
        assertEq(wallet.sweepCap(address(usdc)), 80e6);
    }

    /// The 30e6 swept at t0 under 2.1.0's fixed window carries over. 2.3.0 cannot know
    /// when inside that window it left, so it counts all of it until it is certainly
    /// outside every trailing 24 hours (window start + 2 days). Together with what can
    /// leave after the upgrade, the 24 hours after t0 see exactly one cap.
    function test_upgrade_sweepUsageCarriesOver() public {
        _upgrade();
        assertEq(wallet.sweepAllowance(address(usdc)), 20e6);

        vm.expectRevert(TakumiPay.SweepCapExceeded.selector);
        wallet.sweepMerchantBacking(address(usdc), recipient, 20e6 + 1);
        wallet.sweepMerchantBacking(address(usdc), recipient, 20e6);
        assertEq(usdc.balanceOf(recipient), 50e6);

        // The 20e6 exit expires a day after it was made; the legacy total two days
        // after its window opened.
        vm.warp(t0 + 6 hours + 1 days);
        assertEq(wallet.sweepAllowance(address(usdc)), 20e6);
        vm.warp(t0 + 2 days);
        assertEq(wallet.sweepAllowance(address(usdc)), 50e6);
    }

    /// The API signs quotes against the proxy's EIP-712 domain, which the upgrade must
    /// not move: a quote signed before the upgrade still settles after it.
    function test_upgrade_quoteSignedBeforeStillSettles() public {
        (TakumiPay.QuoteCommitment memory quote, bytes memory sig) = _signedQuote("ref-m2", 10e6, 0.5e6);
        bytes32 domain = wallet.DOMAIN_SEPARATOR();

        _upgrade();
        assertEq(wallet.DOMAIN_SEPARATOR(), domain);

        vm.prank(payer);
        wallet.processMerchantPayment(quote, sig);
        assertEq(wallet.platformFeeAccrued(address(usdc)), 2.5e6);
    }

    /// From 2.3.0 on, the next upgrade is queued, bound to its code and timelocked.
    function test_upgrade_nextUpgradeIsQueuedAndTimelocked() public {
        _upgrade();
        address next = address(new TakumiPay());

        vm.expectRevert(TakumiPay.UpgradeNotQueued.selector);
        wallet.upgradeToAndCall(next, "");

        wallet.queueUpgrade(next);
        vm.expectRevert(TakumiPay.TimelockNotExpired.selector);
        wallet.upgradeToAndCall(next, "");

        vm.warp(vm.getBlockTimestamp() + 1 days);
        wallet.upgradeToAndCall(next, "");
        assertEq(address(uint160(uint256(vm.load(address(wallet), IMPLEMENTATION_SLOT)))), next);
    }

    /// Arc's 2.1.0 proxy set its alias with setNativeAliasToken after deployment. After
    /// the upgrade native stays closed and the bounded dust rescue works.
    function test_upgrade_aliasedProxy_keepsNativeClosed() public {
        TakumiPay210 arc = _deploy210();
        arc.setNativeAliasToken(address(usdc));
        vm.deal(address(arc), 3e12 + 99);
        arc.upgradeToAndCall(address(new TakumiPay()), "");

        TakumiPay upgraded = TakumiPay(payable(address(arc)));
        assertEq(upgraded.nativeAliasToken(), address(usdc));
        vm.expectRevert(TakumiPay.NativeDisabledOnAliasChain.selector);
        upgraded.addAllowedPaymentToken(address(0));

        upgraded.rescueNativeDust(recipient);
        assertEq(recipient.balance, 99);
        assertEq(address(arc).balance, 3e12);
    }
}
