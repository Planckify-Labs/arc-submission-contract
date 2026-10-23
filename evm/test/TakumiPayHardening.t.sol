// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TakumiPay.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract Usdc6 is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Regression tests for the fixes from the Arc Studio security review of 2.1.0
///         (findings C-1, H-1, H-2, M-3, L-1, L-2, L-3).
contract TakumiPayHardeningTest is Test {
    TakumiPay public wallet;
    Usdc6 public usdc;

    address public owner;
    address public user1;
    address public recipient;

    bytes32 internal constant UPGRADE_KEY = keccak256("upgrade");

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        recipient = makeAddr("recipient");

        wallet = _deploy(address(0));
        usdc = new Usdc6();
        wallet.addAllowedPaymentToken(address(usdc));
        usdc.mint(user1, 1_000_000e6);
        vm.deal(user1, 100 ether);
    }

    function _deploy(address aliasToken) internal returns (TakumiPay) {
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(new TakumiPay()),
            abi.encodeCall(TakumiPay.initialize, (owner, makeAddr("backendSigner"), aliasToken))
        );
        return TakumiPay(payable(address(proxy)));
    }

    function _setSweepCap(address token, uint256 cap) internal {
        wallet.queueSweepCap(token, cap);
        wallet.applySweepCap(token);
    }

    // ====== Deployability ======

    /// EIP-170 caps runtime code at 24,576 bytes, and Arc enforces it. Forge does
    /// not apply the cap to contracts deployed inside tests, so an oversized
    /// implementation passes every other test and only fails at deploy time — as
    /// the first cut of 2.2.0 did, 552 bytes over.
    function test_implementationFitsUnderEip170() public {
        assertLe(address(new TakumiPay()).code.length, 24_576);
    }

    // ====== C-1: alias is set atomically at initialization ======

    function test_initialize_setsAliasAtomically() public {
        TakumiPay aliased = _deploy(address(usdc));
        assertEq(aliased.nativeAliasToken(), address(usdc));
        assertTrue(aliased.isNativeAliased());

        vm.expectRevert(TakumiPay.NativeDisabledOnAliasChain.selector);
        aliased.addAllowedPaymentToken(address(0));
    }

    function test_initialize_emitsAliasEvent() public {
        TakumiPay impl = new TakumiPay();
        vm.expectEmit(true, false, false, false);
        emit TakumiPay.NativeAliasTokenSet(address(usdc));
        new ERC1967Proxy(
            address(impl), abi.encodeCall(TakumiPay.initialize, (owner, makeAddr("backendSigner"), address(usdc)))
        );
    }

    function test_initialize_noAlias_onNormalChain() public view {
        assertEq(wallet.nativeAliasToken(), address(0));
        assertFalse(wallet.isNativeAliased());
    }

    function test_revert_initialize_arcMainnetWithoutAlias() public {
        vm.chainId(5042);
        TakumiPay impl = new TakumiPay();
        vm.expectRevert(TakumiPay.NativeAliasRequired.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(TakumiPay.initialize, (owner, makeAddr("backendSigner"), address(0)))
        );
    }

    function test_revert_initialize_arcTestnetWithoutAlias() public {
        vm.chainId(5042002);
        TakumiPay impl = new TakumiPay();
        vm.expectRevert(TakumiPay.NativeAliasRequired.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(TakumiPay.initialize, (owner, makeAddr("backendSigner"), address(0)))
        );
    }

    function test_initialize_arcWithAlias() public {
        vm.chainId(5042);
        TakumiPay aliased = _deploy(address(usdc));
        assertEq(aliased.nativeAliasToken(), address(usdc));
    }

    // ====== H-1: upgrades go through the pending-change queue ======

    function test_revert_upgrade_notQueued() public {
        address impl = address(new TakumiPay());
        vm.expectRevert(TakumiPay.UpgradeNotQueued.selector);
        wallet.upgradeToAndCall(impl, "");
    }

    function test_revert_upgrade_differentImplementationThanQueued() public {
        wallet.queueUpgrade(address(new TakumiPay()));
        address other = address(new TakumiPay());
        vm.expectRevert(TakumiPay.UpgradeNotQueued.selector);
        wallet.upgradeToAndCall(other, "");
    }

    function test_upgrade_waitsOutWithdrawalDelay() public {
        wallet.setWithdrawalDelay(1 days);
        address impl = address(new TakumiPay());

        vm.expectEmit(true, false, false, true);
        emit TakumiPay.UpgradeQueued(impl, block.timestamp + 1 days);
        wallet.queueUpgrade(impl);

        vm.expectRevert(TakumiPay.TimelockNotExpired.selector);
        wallet.upgradeToAndCall(impl, "");

        vm.warp(block.timestamp + 1 days - 1);
        vm.expectRevert(TakumiPay.TimelockNotExpired.selector);
        wallet.upgradeToAndCall(impl, "");

        vm.warp(block.timestamp + 1);
        wallet.upgradeToAndCall(impl, "");
        assertEq(_implementation(), impl);
        assertEq(wallet.owner(), owner);
    }

    function test_upgrade_queueIsSingleUse() public {
        address impl = address(new TakumiPay());
        wallet.queueUpgrade(impl);
        wallet.upgradeToAndCall(impl, "");

        vm.expectRevert(TakumiPay.UpgradeNotQueued.selector);
        wallet.upgradeToAndCall(impl, "");
    }

    function test_upgrade_cancelled() public {
        address impl = address(new TakumiPay());
        wallet.queueUpgrade(impl);
        wallet.cancelPendingChange(UPGRADE_KEY);

        vm.expectRevert(TakumiPay.UpgradeNotQueued.selector);
        wallet.upgradeToAndCall(impl, "");
    }

    function test_revert_queueUpgrade_notOwner() public {
        address impl = address(new TakumiPay());
        vm.prank(user1);
        vm.expectRevert(TakumiPay.NotOwner.selector);
        wallet.queueUpgrade(impl);
    }

    function test_revert_queueUpgrade_zeroAddress() public {
        vm.expectRevert(TakumiPay.ZeroAddress.selector);
        wallet.queueUpgrade(address(0));
    }

    function test_revert_upgrade_notOwner_evenWhenQueued() public {
        address impl = address(new TakumiPay());
        wallet.queueUpgrade(impl);
        vm.prank(user1);
        vm.expectRevert(TakumiPay.NotOwner.selector);
        wallet.upgradeToAndCall(impl, "");
    }

    function _implementation() internal view returns (address) {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        return address(uint160(uint256(vm.load(address(wallet), slot))));
    }

    // ====== H-2: aliasing refuses to strand native state ======

    /// Seeds platformFeeAccrued[native] directly rather than signing a merchant quote;
    /// the quote path itself is covered in TakumiPayMerchant.t.sol.
    function _accrueNativeFee() internal {
        vm.store(
            address(wallet),
            keccak256(abi.encode(address(0), uint256(_platformFeeAccruedSlot()))),
            bytes32(uint256(0.01 ether))
        );
        vm.deal(address(wallet), 0.01 ether);
        assertEq(wallet.platformFeeAccrued(address(0)), 0.01 ether);
    }

    function _platformFeeAccruedSlot() internal pure returns (uint256) {
        // From `forge inspect TakumiPay storageLayout`. The getter assert in
        // _accrueNativeFee fails loudly if the layout ever moves it.
        return 24;
    }

    function test_revert_setNativeAliasToken_withAccruedNativeFees() public {
        _accrueNativeFee();
        vm.expectRevert(TakumiPay.NativeFeesOutstanding.selector);
        wallet.setNativeAliasToken(address(usdc));
    }

    function test_revert_setNativeAliasToken_withNativeSweepCap() public {
        _setSweepCap(address(0), 1 ether);
        vm.expectRevert(TakumiPay.NativeSweepCapSet.selector);
        wallet.setNativeAliasToken(address(usdc));
    }

    function test_setNativeAliasToken_afterDrainingNativeState() public {
        _accrueNativeFee();
        _setSweepCap(address(0), 1 ether);

        wallet.sweepPlatformFees(address(0), recipient, 0.01 ether);
        wallet.setSweepCap(address(0), 0);

        wallet.setNativeAliasToken(address(usdc));
        assertEq(wallet.nativeAliasToken(), address(usdc));
        assertEq(recipient.balance, 0.01 ether);
    }

    // ====== M-3: sub-unit native dust is recoverable ======

    function test_rescueNativeDust_sendsOnlyTheSubUnitRemainder() public {
        TakumiPay aliased = _deploy(address(usdc));
        vm.deal(address(aliased), 5e12 + 123_456); // 5 USDC base units + dust

        vm.expectEmit(true, false, false, true);
        emit TakumiPay.NativeDustRescued(recipient, 123_456);
        aliased.rescueNativeDust(recipient);

        assertEq(recipient.balance, 123_456);
        assertEq(address(aliased).balance, 5e12, "whole units untouched");
    }

    function testFuzz_rescueNativeDust_neverMovesAWholeUnit(uint256 balance) public {
        balance = bound(balance, 1, 1e30);
        TakumiPay aliased = _deploy(address(usdc));
        vm.deal(address(aliased), balance);

        if (balance % 1e12 == 0) {
            vm.expectRevert(TakumiPay.ZeroAmount.selector);
            aliased.rescueNativeDust(recipient);
            return;
        }
        aliased.rescueNativeDust(recipient);
        assertEq(address(aliased).balance / 1e12, balance / 1e12);
        assertLt(recipient.balance, 1e12);
    }

    function test_revert_rescueNativeDust_whenNotAliased() public {
        vm.deal(address(wallet), 1);
        vm.expectRevert(TakumiPay.NativeNotAliased.selector);
        wallet.rescueNativeDust(recipient);
    }

    function test_revert_rescueNativeDust_notOwner() public {
        TakumiPay aliased = _deploy(address(usdc));
        vm.prank(user1);
        vm.expectRevert(TakumiPay.NotOwner.selector);
        aliased.rescueNativeDust(recipient);
    }

    function test_revert_rescueNativeDust_zeroRecipient() public {
        TakumiPay aliased = _deploy(address(usdc));
        vm.expectRevert(TakumiPay.ZeroAddress.selector);
        aliased.rescueNativeDust(address(0));
    }

    // ====== L-1: getTransactionsInRange matches a brute-force scan ======

    function testFuzz_getTransactionsInRange_matchesLinearScan(
        uint256 seed,
        uint256 n,
        uint256 startOffset,
        uint256 span,
        uint256 offset,
        uint256 limit
    ) public {
        n = bound(n, 0, 30);
        uint256 t0 = block.timestamp;
        uint256[] memory stamps = new uint256[](n);

        vm.startPrank(user1);
        usdc.approve(address(wallet), type(uint256).max);
        for (uint256 i = 0; i < n; i++) {
            // 0-3s gaps, so many txs share a timestamp
            vm.warp(block.timestamp + uint256(keccak256(abi.encode(seed, i))) % 4);
            stamps[i] = block.timestamp;
            wallet.createTransaction("b", 1, "v", address(usdc), vm.toString(i), i + 1);
        }
        vm.stopPrank();

        uint256 start = t0 + bound(startOffset, 0, 3 * n + 2);
        uint256 end = start + bound(span, 0, 3 * n + 2);
        offset = bound(offset, 0, n + 1);
        limit = bound(limit, 0, n + 1);

        uint256[] memory expected = new uint256[](n);
        uint256 matched;
        uint256 filled;
        for (uint256 i = 0; i < n; i++) {
            if (stamps[i] >= start && stamps[i] <= end) {
                if (matched >= offset && filled < limit) expected[filled++] = i + 1; // amount == id
                matched++;
            }
        }

        TakumiPay.Transaction[] memory got = wallet.getTransactionsInRange(start, end, offset, limit);
        assertEq(got.length, filled);
        for (uint256 i = 0; i < filled; i++) {
            assertEq(got[i].amount, expected[i]);
        }
    }

    function test_getTransactionsInRange_maxEnd() public {
        vm.startPrank(user1);
        usdc.approve(address(wallet), 2);
        wallet.createTransaction("b", 1, "v", address(usdc), "r1", 1);
        vm.warp(block.timestamp + 10);
        wallet.createTransaction("b", 1, "v", address(usdc), "r2", 1);
        vm.stopPrank();

        assertEq(wallet.getTransactionsInRange(0, type(uint256).max, 0, 10).length, 2);
        assertEq(wallet.getTransactionsInRange(block.timestamp, type(uint256).max, 0, 10).length, 1);
    }

    function test_getTransactionsInRange_empty() public view {
        assertEq(wallet.getTransactionsInRange(0, type(uint256).max, 0, 10).length, 0);
    }

    // ====== L-2: createTransaction uses custom errors ======

    function test_revert_createTransaction_nativeAmountMismatch() public {
        wallet.addAllowedPaymentToken(address(0));
        vm.prank(user1);
        vm.expectRevert(TakumiPay.NativeAmountMismatch.selector);
        wallet.createTransaction{value: 0.5 ether}("b", 1, "v", address(0), "r", 1 ether);
    }

    function test_revert_createTransaction_unexpectedNative() public {
        vm.prank(user1);
        vm.expectRevert(TakumiPay.UnexpectedNative.selector);
        wallet.createTransaction{value: 1}("b", 1, "v", address(usdc), "r", 1e6);
    }

    // ====== L-3: withdrawal ids use non-packed encoding ======

    function test_queueWithdrawal_idIsAbiEncoded() public {
        wallet.setWithdrawalDelay(1 days);
        bytes32 id = wallet.queueWithdrawal(address(usdc), recipient, 5e6);
        assertEq(id, keccak256(abi.encode(address(usdc), recipient, uint256(5e6), block.timestamp, uint256(1))));
    }
}
