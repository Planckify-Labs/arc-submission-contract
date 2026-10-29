// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TakumiPay.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Malicious ERC20 that attempts reentrancy on transferFrom
contract ReentrantERC20 is ERC20 {
    address public target;
    bool public attacking;

    constructor() ERC20("Reentrant", "REENT") {}

    function setTarget(address _target) external {
        target = _target;
    }

    function setAttacking(bool _attacking) external {
        attacking = _attacking;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (attacking && target != address(0)) {
            attacking = false;
            // Attempt reentrancy into createTransaction
            TakumiPay(payable(target)).createTransaction("b_reentry", 1, "v_reentry", address(this), "ref_reentry", amount);
        }
        return super.transferFrom(from, to, amount);
    }
}

contract TakumiPayProductionTest is Test {
    TakumiPay public wallet;
    MockERC20 public usdc;
    MockERC20 public usdt;

    address public owner;
    address public admin;
    address public user1;
    address public user2;

    function setUp() public {
        owner = address(this);
        admin = makeAddr("admin");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        TakumiPay implementation = new TakumiPay();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(TakumiPay.initialize, (owner, makeAddr("backendSigner"), address(0)))
        );
        wallet = TakumiPay(payable(address(proxy)));

        usdc = new MockERC20("USD Coin", "USDC");
        usdt = new MockERC20("Tether USD", "USDT");

        wallet.addAdmin(admin);
        // Every value-in entrypoint is allowlist-gated, native included.
        wallet.addAllowedPaymentToken(address(usdc));
        wallet.addAllowedPaymentToken(address(0));

        usdc.mint(user1, 10_000e6);
        usdc.mint(user2, 10_000e6);
        usdt.mint(user1, 10_000e6);

        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);

        // Every exit — sweeps, withdraw, executeWithdrawal, recoverToken — is bounded
        // by the per-token sweep cap, and an unset cap fails closed. Caps are set here,
        // before any withdrawalDelay is in force, because raising one is a loosening
        // and would otherwise be subject to that delay. This mirrors the deploy order.
        _setSweepCap(address(usdc), type(uint256).max);
        _setSweepCap(address(usdt), type(uint256).max);
        _setSweepCap(address(0), type(uint256).max);
    }

    /// Raising a sweep cap is a two-step queue/apply (both legs land in the same block
    /// while withdrawalDelay is 0); lowering is a single immediate call.
    function _setSweepCap(address token, uint256 cap) internal {
        if (cap > wallet.sweepCap(token)) {
            wallet.queueSweepCap(token, cap);
            wallet.applySweepCap(token);
        } else {
            wallet.setSweepCap(token, cap);
        }
    }

    // ====== Global Pause ======

    function test_SetPaused_Toggles() public {
        assertFalse(wallet.paused());
        wallet.setPaused(true);
        assertTrue(wallet.paused());
        wallet.setPaused(false);
        assertFalse(wallet.paused());
    }

    function test_SetPaused_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit TakumiPay.ContractPausedToggled(true);
        wallet.setPaused(true);
    }

    function test_SetPaused_RevertIf_NotAdminOrOwner() public {
        vm.prank(user1);
        vm.expectRevert(TakumiPay.NotAdminOrOwner.selector);
        wallet.setPaused(true);
    }

    function test_Paused_BlocksCreateTransaction() public {
        wallet.setPaused(true);
        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        vm.expectRevert(TakumiPay.ContractPaused.selector);
        wallet.createTransaction("b1", 1, "v1", address(usdc), "ref1", 100e6);
        vm.stopPrank();
    }

    function test_Paused_BlocksDepositPoints() public {
        wallet.setPaused(true);
        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        vm.expectRevert(TakumiPay.ContractPaused.selector);
        wallet.depositPoints(address(usdc), "pt1", 100e6);
        vm.stopPrank();
    }

    function test_Paused_BlocksBatchTransaction() public {
        wallet.setPaused(true);
        TakumiPay.TransactionParams[] memory params = new TakumiPay.TransactionParams[](1);
        params[0] = TakumiPay.TransactionParams("b1", 1, "v1", address(usdc), "ref1", 100e6);
        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        vm.expectRevert(TakumiPay.ContractPaused.selector);
        wallet.createTransactionBatch(params);
        vm.stopPrank();
    }

    // ====== Spending Limits ======

    function test_SetMaxTransactionAmount_Success() public {
        wallet.setMaxTransactionAmount(address(usdc), 500e6);
        assertEq(wallet.maxTransactionAmount(address(usdc)), 500e6);
    }

    function test_SetMaxTransactionAmount_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit TakumiPay.MaxTransactionAmountUpdated(address(usdc), 500e6);
        wallet.setMaxTransactionAmount(address(usdc), 500e6);
    }

    function test_SetMaxTransactionAmount_RevertIf_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert(TakumiPay.NotOwner.selector);
        wallet.setMaxTransactionAmount(address(usdc), 500e6);
    }

    function test_SpendingLimit_BlocksExcessiveAmount() public {
        wallet.setMaxTransactionAmount(address(usdc), 500e6);

        vm.startPrank(user1);
        usdc.approve(address(wallet), 1000e6);
        vm.expectRevert(TakumiPay.ExceedsSpendingLimit.selector);
        wallet.createTransaction("b1", 1, "v1", address(usdc), "ref1", 600e6);
        vm.stopPrank();
    }

    function test_SpendingLimit_AllowsExactMax() public {
        wallet.setMaxTransactionAmount(address(usdc), 500e6);

        vm.startPrank(user1);
        usdc.approve(address(wallet), 500e6);
        wallet.createTransaction("b1", 1, "v1", address(usdc), "ref1", 500e6);
        vm.stopPrank();

        assertEq(wallet.txCounter(), 1);
    }

    function test_SpendingLimit_ZeroMeansNoLimit() public {
        wallet.setMaxTransactionAmount(address(usdc), 0);

        vm.startPrank(user1);
        usdc.approve(address(wallet), 5000e6);
        wallet.createTransaction("b1", 1, "v1", address(usdc), "ref1", 5000e6);
        vm.stopPrank();

        assertEq(wallet.txCounter(), 1);
    }

    // ====== Batch Transactions ======

    function test_BatchTransaction_ERC20_Success() public {
        TakumiPay.TransactionParams[] memory params = new TakumiPay.TransactionParams[](3);
        params[0] = TakumiPay.TransactionParams("b1", 1, "v1", address(usdc), "ref1", 100e6);
        params[1] = TakumiPay.TransactionParams("b2", 2, "v2", address(usdc), "ref2", 200e6);
        params[2] = TakumiPay.TransactionParams("b3", 3, "v3", address(usdc), "ref3", 150e6);

        vm.startPrank(user1);
        usdc.approve(address(wallet), 450e6);
        wallet.createTransactionBatch(params);
        vm.stopPrank();

        assertEq(wallet.txCounter(), 3);
        assertEq(usdc.balanceOf(address(wallet)), 450e6);
    }

    function test_BatchTransaction_Native_Success() public {
        TakumiPay.TransactionParams[] memory params = new TakumiPay.TransactionParams[](2);
        params[0] = TakumiPay.TransactionParams("b1", 1, "v1", address(0), "ref1", 1 ether);
        params[1] = TakumiPay.TransactionParams("b2", 2, "v2", address(0), "ref2", 2 ether);

        vm.prank(user1);
        wallet.createTransactionBatch{value: 3 ether}(params);

        assertEq(wallet.txCounter(), 2);
        assertEq(address(wallet).balance, 3 ether);
    }

    function test_BatchTransaction_Mixed_Success() public {
        TakumiPay.TransactionParams[] memory params = new TakumiPay.TransactionParams[](2);
        params[0] = TakumiPay.TransactionParams("b1", 1, "v1", address(usdc), "ref1", 100e6);
        params[1] = TakumiPay.TransactionParams("b2", 2, "v2", address(0), "ref2", 1 ether);

        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        wallet.createTransactionBatch{value: 1 ether}(params);
        vm.stopPrank();

        assertEq(wallet.txCounter(), 2);
    }

    function test_BatchTransaction_RevertIf_Empty() public {
        TakumiPay.TransactionParams[] memory params = new TakumiPay.TransactionParams[](0);
        vm.prank(user1);
        vm.expectRevert(TakumiPay.EmptyBatch.selector);
        wallet.createTransactionBatch(params);
    }

    function test_BatchTransaction_RevertIf_TooLarge() public {
        TakumiPay.TransactionParams[] memory params = new TakumiPay.TransactionParams[](21);
        for (uint256 i = 0; i < 21; i++) {
            params[i] = TakumiPay.TransactionParams("b", i, "v", address(usdc), string(abi.encodePacked("ref", i)), 1e6);
        }
        vm.prank(user1);
        vm.expectRevert(TakumiPay.BatchTooLarge.selector);
        wallet.createTransactionBatch(params);
    }

    function test_BatchTransaction_RevertIf_DuplicateRefInBatch() public {
        TakumiPay.TransactionParams[] memory params = new TakumiPay.TransactionParams[](2);
        params[0] = TakumiPay.TransactionParams("b1", 1, "v1", address(usdc), "same_ref", 100e6);
        params[1] = TakumiPay.TransactionParams("b2", 2, "v2", address(usdc), "same_ref", 100e6);

        vm.startPrank(user1);
        usdc.approve(address(wallet), 200e6);
        vm.expectRevert(TakumiPay.DuplicateRefInBatch.selector);
        wallet.createTransactionBatch(params);
        vm.stopPrank();
    }

    function test_BatchTransaction_RevertIf_ExistingRefId() public {
        vm.startPrank(user1);
        usdc.approve(address(wallet), 200e6);
        wallet.createTransaction("b1", 1, "v1", address(usdc), "existing_ref", 100e6);

        TakumiPay.TransactionParams[] memory params = new TakumiPay.TransactionParams[](1);
        params[0] = TakumiPay.TransactionParams("b2", 2, "v2", address(usdc), "existing_ref", 100e6);

        vm.expectRevert(TakumiPay.RefConsumed.selector);
        wallet.createTransactionBatch(params);
        vm.stopPrank();
    }

    function test_BatchTransaction_RevertIf_IncorrectETH() public {
        TakumiPay.TransactionParams[] memory params = new TakumiPay.TransactionParams[](1);
        params[0] = TakumiPay.TransactionParams("b1", 1, "v1", address(0), "ref1", 1 ether);

        vm.prank(user1);
        vm.expectRevert(TakumiPay.NativeAmountMismatch.selector);
        wallet.createTransactionBatch{value: 0.5 ether}(params);
    }

    // ====== Withdrawal Timelock ======

    function test_SetWithdrawalDelay_Success() public {
        wallet.setWithdrawalDelay(1 days);
        assertEq(wallet.withdrawalDelay(), 1 days);
    }

    function test_SetWithdrawalDelay_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit TakumiPay.WithdrawalDelayUpdated(1 days);
        wallet.setWithdrawalDelay(1 days);
    }

    function test_SetWithdrawalDelay_RevertIf_ExceedsMax() public {
        vm.expectRevert(TakumiPay.DelayTooLong.selector);
        wallet.setWithdrawalDelay(8 days);
    }

    function test_SetWithdrawalDelay_RevertIf_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert(TakumiPay.NotOwner.selector);
        wallet.setWithdrawalDelay(1 days);
    }

    function test_QueueWithdrawal_Success() public {
        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        wallet.createTransaction("b1", 1, "v1", address(usdc), "ref1", 100e6);
        vm.stopPrank();

        wallet.setWithdrawalDelay(1 days);
        bytes32 wId = wallet.queueWithdrawal(address(usdc), owner, 100e6);

        (address token, address to, uint256 amount, uint256 unlockTime, bool executed, bool cancelled) =
            wallet.withdrawalRequests(wId);
        assertEq(token, address(usdc));
        assertEq(to, owner);
        assertEq(amount, 100e6);
        assertEq(unlockTime, block.timestamp + 1 days);
        assertFalse(executed);
        assertFalse(cancelled);
    }

    function test_QueueWithdrawal_EmitsEvent() public {
        wallet.setWithdrawalDelay(1 days);

        vm.expectEmit(false, true, true, true);
        emit TakumiPay.WithdrawalQueued(bytes32(0), address(usdc), owner, 100e6, block.timestamp + 1 days);
        wallet.queueWithdrawal(address(usdc), owner, 100e6);
    }

    function test_ExecuteWithdrawal_AfterDelay() public {
        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        wallet.createTransaction("b1", 1, "v1", address(usdc), "ref1", 100e6);
        vm.stopPrank();

        wallet.setWithdrawalDelay(1 days);
        bytes32 wId = wallet.queueWithdrawal(address(usdc), owner, 100e6);

        vm.warp(block.timestamp + 1 days);
        wallet.executeWithdrawal(wId);

        assertEq(usdc.balanceOf(owner), 100e6);
        (,,,, bool executed,) = wallet.withdrawalRequests(wId);
        assertTrue(executed);
    }

    function test_ExecuteWithdrawal_RevertIf_TooEarly() public {
        wallet.setWithdrawalDelay(1 days);
        bytes32 wId = wallet.queueWithdrawal(address(usdc), owner, 100e6);

        vm.expectRevert(TakumiPay.TimelockNotExpired.selector);
        wallet.executeWithdrawal(wId);
    }

    function test_ExecuteWithdrawal_RevertIf_AlreadyExecuted() public {
        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        wallet.createTransaction("b1", 1, "v1", address(usdc), "ref1", 100e6);
        vm.stopPrank();

        wallet.setWithdrawalDelay(1 days);
        bytes32 wId = wallet.queueWithdrawal(address(usdc), owner, 100e6);
        vm.warp(block.timestamp + 1 days);
        wallet.executeWithdrawal(wId);

        vm.expectRevert(TakumiPay.WithdrawalAlreadyExecuted.selector);
        wallet.executeWithdrawal(wId);
    }

    function test_CancelWithdrawal_Success() public {
        wallet.setWithdrawalDelay(1 days);
        bytes32 wId = wallet.queueWithdrawal(address(usdc), owner, 100e6);

        wallet.cancelWithdrawal(wId);

        (,,,,, bool cancelled) = wallet.withdrawalRequests(wId);
        assertTrue(cancelled);
    }

    function test_CancelWithdrawal_EmitsEvent() public {
        wallet.setWithdrawalDelay(1 days);
        bytes32 wId = wallet.queueWithdrawal(address(usdc), owner, 100e6);

        vm.expectEmit(true, false, false, false);
        emit TakumiPay.WithdrawalCancelled(wId);
        wallet.cancelWithdrawal(wId);
    }

    function test_CancelWithdrawal_BlocksExecution() public {
        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        wallet.createTransaction("b1", 1, "v1", address(usdc), "ref1", 100e6);
        vm.stopPrank();

        wallet.setWithdrawalDelay(1 days);
        bytes32 wId = wallet.queueWithdrawal(address(usdc), owner, 100e6);
        wallet.cancelWithdrawal(wId);

        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(TakumiPay.WithdrawalAlreadyCancelled.selector);
        wallet.executeWithdrawal(wId);
    }

    function test_ExecuteWithdrawal_RevertIf_NotFound() public {
        vm.expectRevert(TakumiPay.WithdrawalNotFound.selector);
        wallet.executeWithdrawal(bytes32(uint256(999)));
    }

    // ====== Token Recovery ======

    function test_RecoverToken_ERC20_Success() public {
        usdt.mint(address(wallet), 500e6);

        wallet.recoverToken(address(usdt), owner, 500e6);

        assertEq(usdt.balanceOf(owner), 500e6);
        assertEq(usdt.balanceOf(address(wallet)), 0);
    }

    function test_RecoverToken_Native_Success() public {
        vm.deal(address(wallet), 1 ether);

        uint256 before = user2.balance;
        wallet.recoverToken(address(0), user2, 1 ether);

        assertEq(user2.balance - before, 1 ether);
        assertEq(address(wallet).balance, 0);
    }

    function test_RecoverToken_EmitsEvent() public {
        usdt.mint(address(wallet), 100e6);

        vm.expectEmit(true, true, false, true);
        emit TakumiPay.TokenRecovered(address(usdt), owner, 100e6);
        wallet.recoverToken(address(usdt), owner, 100e6);
    }

    function test_RecoverToken_RevertIf_NotOwner() public {
        usdt.mint(address(wallet), 100e6);

        vm.prank(user1);
        vm.expectRevert(TakumiPay.NotOwner.selector);
        wallet.recoverToken(address(usdt), user1, 100e6);
    }

    function test_RecoverToken_RevertIf_ZeroAddress() public {
        vm.expectRevert(TakumiPay.ZeroAddress.selector);
        wallet.recoverToken(address(usdt), address(0), 100e6);
    }

    // ====== Interaction: Global Pause vs Point Deposits Pause ======

    function test_BothPauses_Independent() public {
        wallet.setPaused(true);

        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        vm.expectRevert(TakumiPay.ContractPaused.selector);
        wallet.depositPoints(address(usdc), "pt1", 100e6);
        vm.stopPrank();

        wallet.setPaused(false);
        wallet.setPointDepositsPaused(true);

        vm.startPrank(user1);
        vm.expectRevert(TakumiPay.PointDepositsPaused.selector);
        wallet.depositPoints(address(usdc), "pt1", 100e6);
        vm.stopPrank();

        vm.startPrank(user1);
        wallet.createTransaction("b1", 1, "v1", address(usdc), "tx_ref1", 100e6);
        vm.stopPrank();

        assertEq(wallet.txCounter(), 1);
    }

    // ====== Security: Two-Step Ownership Transfer ======

    function test_TransferOwnership_TwoStep() public {
        address newOwner = makeAddr("newOwner");

        wallet.transferOwnership(newOwner);
        assertEq(wallet.pendingOwner(), newOwner);
        assertEq(wallet.owner(), owner); // owner unchanged until accepted

        vm.prank(newOwner);
        wallet.acceptOwnership();

        assertEq(wallet.owner(), newOwner);
        assertEq(wallet.pendingOwner(), address(0));
    }

    function test_TransferOwnership_EmitsEvents() public {
        address newOwner = makeAddr("newOwner");

        vm.expectEmit(true, true, false, false);
        emit TakumiPay.OwnershipTransferInitiated(owner, newOwner);
        wallet.transferOwnership(newOwner);

        vm.expectEmit(true, true, false, false);
        emit TakumiPay.OwnershipTransferred(owner, newOwner);
        vm.prank(newOwner);
        wallet.acceptOwnership();
    }

    function test_TransferOwnership_RevertIf_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert(TakumiPay.NotOwner.selector);
        wallet.transferOwnership(user1);
    }

    function test_TransferOwnership_RevertIf_ZeroAddress() public {
        vm.expectRevert(TakumiPay.ZeroAddress.selector);
        wallet.transferOwnership(address(0));
    }

    function test_AcceptOwnership_RevertIf_NotPending() public {
        wallet.transferOwnership(user2);

        vm.prank(user1);
        vm.expectRevert(TakumiPay.NotPendingOwner.selector);
        wallet.acceptOwnership();
    }

    function test_CancelOwnershipTransfer() public {
        wallet.transferOwnership(user1);
        assertEq(wallet.pendingOwner(), user1);

        wallet.cancelOwnershipTransfer();
        assertEq(wallet.pendingOwner(), address(0));

        vm.prank(user1);
        vm.expectRevert(TakumiPay.NotPendingOwner.selector);
        wallet.acceptOwnership();
    }

    // ====== Security: Admin List Integrity After Removal ======

    function test_RemoveAdmin_PrunesArray() public {
        address admin2 = makeAddr("admin2");
        address admin3 = makeAddr("admin3");

        wallet.addAdmin(admin2);
        wallet.addAdmin(admin3);

        // Remove middle admin (admin)
        wallet.removeAdmin(admin);

        address[] memory activeAdmins = wallet.getAllAdmins();
        assertEq(activeAdmins.length, 2);

        // Verify removed admin is not in the list
        for (uint256 i = 0; i < activeAdmins.length; i++) {
            assertTrue(activeAdmins[i] != admin);
        }

        // Verify isAdmin returns false
        assertFalse(wallet.isAdmin(admin));
    }

    function test_RemoveAdmin_LastElement() public {
        // Remove the only admin
        wallet.removeAdmin(admin);

        address[] memory activeAdmins = wallet.getAllAdmins();
        assertEq(activeAdmins.length, 0);
    }

    function test_AddAdmin_AfterRemove_ReuseSlot() public {
        wallet.removeAdmin(admin);
        // Re-adding same admin should work
        wallet.addAdmin(admin);
        assertTrue(wallet.isAdmin(admin));
        assertEq(wallet.getAllAdmins().length, 1);
    }

    // ====== Security: Point Token List Integrity After Removal ======

    // ====== Payment token allowlist gates value-in entrypoints ======
    // Parity with Stellar's AllowedPaymentToken (see stellar/.../transaction.rs).
    // usdt is deliberately never allowlisted in setUp.

    function test_revert_createTransaction_tokenNotAllowed() public {
        vm.startPrank(user1);
        usdt.approve(address(wallet), 100e6);
        vm.expectRevert(TakumiPay.TokenNotAllowed.selector);
        wallet.createTransaction("b1", 1, "v1", address(usdt), "ref_notallowed", 100e6);
        vm.stopPrank();

        // No funds moved and no record written
        assertEq(usdt.balanceOf(address(wallet)), 0);
        assertEq(wallet.txCounter(), 0);
    }

    function test_revert_createTransactionBatch_tokenNotAllowed() public {
        TakumiPay.TransactionParams[] memory params = new TakumiPay.TransactionParams[](2);
        params[0] = TakumiPay.TransactionParams("b1", 1, "v1", address(usdc), "ref_ok", 100e6);
        params[1] = TakumiPay.TransactionParams("b2", 2, "v2", address(usdt), "ref_bad", 100e6);

        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        usdt.approve(address(wallet), 100e6);
        // Rejected in phase 1, so the allowlisted leg never transfers either.
        vm.expectRevert(TakumiPay.TokenNotAllowed.selector);
        wallet.createTransactionBatch(params);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(wallet)), 0);
        assertEq(wallet.txCounter(), 0);
    }

    function test_revert_createTransaction_nativeNotAllowed() public {
        wallet.removeAllowedPaymentToken(address(0));

        vm.prank(user1);
        vm.expectRevert(TakumiPay.TokenNotAllowed.selector);
        wallet.createTransaction{value: 1 ether}("b1", 1, "v1", address(0), "ref_native", 1 ether);
    }

    /// setUp allowlists [usdc, native]. Adding usdt then removing usdc must
    /// swap-and-pop cleanly, leaving the other two intact.
    function test_RemovePaymentToken_PrunesArray() public {
        wallet.addAllowedPaymentToken(address(usdt));
        assertEq(wallet.getAllowedPaymentTokens().length, 3);

        wallet.removeAllowedPaymentToken(address(usdc));

        address[] memory tokens = wallet.getAllowedPaymentTokens();
        assertEq(tokens.length, 2);
        assertFalse(wallet.isAllowedPaymentToken(address(usdc)));
        assertTrue(wallet.isAllowedPaymentToken(address(usdt)));
        assertTrue(wallet.isAllowedPaymentToken(address(0)));
    }

    function test_RemovePaymentToken_DrainsToEmpty() public {
        wallet.removeAllowedPaymentToken(address(usdc));
        wallet.removeAllowedPaymentToken(address(0));

        address[] memory tokens = wallet.getAllowedPaymentTokens();
        assertEq(tokens.length, 0);
        assertFalse(wallet.isAllowedPaymentToken(address(usdc)));
        assertFalse(wallet.isAllowedPaymentToken(address(0)));
    }

    // ====== Security: Reentrancy Guard ======

    function test_Reentrancy_BlockedOnCreateTransaction() public {
        ReentrantERC20 reentrantToken = new ReentrantERC20();
        reentrantToken.mint(user1, 1000e18);
        reentrantToken.setTarget(address(wallet));
        reentrantToken.setAttacking(true);

        vm.startPrank(user1);
        reentrantToken.approve(address(wallet), type(uint256).max);

        // Attempt reentrancy — should revert due to ReentrancyGuard
        vm.expectRevert();
        wallet.createTransaction("b_attack", 1, "v_attack", address(reentrantToken), "ref_attack", 100e18);
        vm.stopPrank();
    }

    // ====== Security: Fallback Revert ======

    function test_Fallback_RevertsOnUnknownSelector() public {
        // Calling with unknown selector should revert
        (bool success,) = address(wallet).call(abi.encodeWithSignature("nonExistentFunction()"));
        assertFalse(success);
    }

    function test_Receive_AcceptsNativeETH() public {
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        (bool success,) = address(wallet).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(wallet).balance, 1 ether);
    }

    // ====== Security: String Length Validation ======

    function test_CreateTransaction_RevertIf_EmptyRefId() public {
        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        vm.expectRevert(TakumiPay.InvalidStringLength.selector);
        wallet.createTransaction("b1", 1, "v1", address(usdc), "", 100e6);
        vm.stopPrank();
    }

    function test_CreateTransaction_RevertIf_RefIdTooLong() public {
        string memory longRefId = new string(257);
        // Fill with 'a' characters
        bytes memory longRefIdBytes = bytes(longRefId);
        for (uint256 i = 0; i < 257; i++) {
            longRefIdBytes[i] = "a";
        }

        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        vm.expectRevert(TakumiPay.InvalidStringLength.selector);
        wallet.createTransaction("b1", 1, "v1", address(usdc), string(longRefIdBytes), 100e6);
        vm.stopPrank();
    }

    function test_CreateTransaction_RevertIf_EmptyBookingId() public {
        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        vm.expectRevert(TakumiPay.InvalidStringLength.selector);
        wallet.createTransaction("", 1, "v1", address(usdc), "ref1", 100e6);
        vm.stopPrank();
    }

    // ====== Security: Pagination Limit Cap ======

    function test_GetUserTransactions_RevertIf_LimitTooLarge() public {
        vm.prank(user1);
        vm.expectRevert(TakumiPay.LimitTooLarge.selector);
        wallet.getUserTransactions(0, 501);
    }

    function test_GetUserPointDeposits_RevertIf_LimitTooLarge() public {
        vm.prank(user1);
        vm.expectRevert(TakumiPay.LimitTooLarge.selector);
        wallet.getUserPointDeposits(0, 501);
    }

    function test_GetTransactionsInRange_RevertIf_LimitTooLarge() public {
        vm.expectRevert(TakumiPay.LimitTooLarge.selector);
        wallet.getTransactionsInRange(0, block.timestamp, 0, 501);
    }

    function test_GetTransactionsInRange_RevertIf_InvalidRange() public {
        vm.expectRevert(TakumiPay.InvalidRange.selector);
        wallet.getTransactionsInRange(block.timestamp + 1, block.timestamp, 0, 10);
    }

    // ====== Security: addAdmin zero address ======

    function test_AddAdmin_RevertIf_ZeroAddress() public {
        vm.expectRevert(TakumiPay.ZeroAddress.selector);
        wallet.addAdmin(address(0));
    }

    // ====== Upgradeability ======

    function test_Version_Returns_Current() public view {
        assertEq(wallet.version(), "2.3.0");
    }

    function test_UpgradeToAndCall_RevertIf_NotOwner() public {
        TakumiPay newImpl = new TakumiPay();
        vm.prank(user1);
        vm.expectRevert(TakumiPay.NotOwner.selector);
        wallet.upgradeToAndCall(address(newImpl), "");
    }

    function test_UpgradeToAndCall_Owner_Succeeds() public {
        TakumiPay newImpl = new TakumiPay();
        wallet.queueUpgrade(address(newImpl));
        wallet.upgradeToAndCall(address(newImpl), "");
        // State is preserved after upgrade
        assertEq(wallet.owner(), owner);
    }
}
