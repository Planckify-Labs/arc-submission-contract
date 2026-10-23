// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TakumiPay.sol";

/// @notice Rehearses the 2.1.0 -> 2.2.0 upgrade against the live Arc mainnet proxy on a
///         local fork. Nothing is broadcast. Skipped unless RUN_FORK_TESTS=true:
///           RUN_FORK_TESTS=true forge test --match-contract ArcUpgradeFork
///
///         Set NEW_IMPLEMENTATION to rehearse against an implementation already
///         deployed on Arc — the exact bytecode the owner will switch to — instead
///         of one compiled from this checkout.
contract TakumiPayArcUpgradeForkTest is Test {
    TakumiPay constant PROXY = TakumiPay(payable(0xF44Af1f2b422D66D60aAE5ceFCcbCBF299D01aBF));
    address constant ARC_USDC = 0x3600000000000000000000000000000000000000;

    function setUp() public {
        if (!vm.envOr("RUN_FORK_TESTS", false)) vm.skip(true);
        vm.createSelectFork("arc");
    }

    function test_upgradeFrom210_preservesStateAndArmsTimelock() public {
        assertEq(PROXY.version(), "2.1.0");

        address owner = PROXY.owner();
        address signer = PROXY.backendSigner();
        uint256 delay = PROXY.withdrawalDelay();
        uint256 cap = PROXY.sweepCap(ARC_USDC);
        uint256 txs = PROXY.txCounter();
        uint256 deposits = PROXY.pointDepositCounter();
        bytes32 domain = PROXY.DOMAIN_SEPARATOR();

        // 2.1.0's _authorizeUpgrade is owner-only with no queue, so this lands at once.
        address impl = vm.envOr("NEW_IMPLEMENTATION", address(0));
        if (impl == address(0)) impl = address(new TakumiPay());
        assertLe(impl.code.length, 24_576, "over the EIP-170 limit Arc enforces");
        vm.prank(owner);
        PROXY.upgradeToAndCall(impl, "");

        assertEq(PROXY.version(), "2.2.0");
        assertEq(PROXY.owner(), owner);
        assertEq(PROXY.backendSigner(), signer);
        assertEq(PROXY.withdrawalDelay(), delay);
        assertEq(PROXY.sweepCap(ARC_USDC), cap);
        assertEq(PROXY.nativeAliasToken(), ARC_USDC);
        assertTrue(PROXY.isAllowedPaymentToken(ARC_USDC));
        assertEq(PROXY.txCounter(), txs);
        assertEq(PROXY.pointDepositCounter(), deposits);
        assertEq(PROXY.DOMAIN_SEPARATOR(), domain, "quotes signed by the API must stay valid");

        // From here on the next upgrade waits out the live withdrawalDelay.
        address next = address(new TakumiPay());
        vm.startPrank(owner);
        vm.expectRevert(TakumiPay.UpgradeNotQueued.selector);
        PROXY.upgradeToAndCall(next, "");

        PROXY.queueUpgrade(next);
        vm.expectRevert(TakumiPay.TimelockNotExpired.selector);
        PROXY.upgradeToAndCall(next, "");

        vm.warp(block.timestamp + delay);
        PROXY.upgradeToAndCall(next, "");
        vm.stopPrank();
    }
}
