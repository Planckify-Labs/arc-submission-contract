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

contract TakumiPayPointDepositTest is Test {
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
        wallet.addAllowedPaymentToken(address(usdc));

        usdc.mint(user1, 1000e6);
        usdc.mint(user2, 1000e6);
        usdt.mint(user1, 1000e6);
    }

    // ====== depositPoints ======

    function test_DepositPoints_Success() public {
        uint256 amount = 100e6;
        string memory refId = "pt_abc123";

        vm.startPrank(user1);
        usdc.approve(address(wallet), amount);
        wallet.depositPoints(address(usdc), refId, amount);
        vm.stopPrank();

        assertEq(wallet.pointDepositCounter(), 1);
        assertEq(usdc.balanceOf(address(wallet)), amount);
        assertEq(usdc.balanceOf(user1), 900e6);
    }

    function test_DepositPoints_CreatesCorrectRecord() public {
        uint256 amount = 50e6;
        string memory refId = "pt_record1";
        uint256 ts = block.timestamp;

        vm.startPrank(user1);
        usdc.approve(address(wallet), amount);
        wallet.depositPoints(address(usdc), refId, amount);
        vm.stopPrank();

        vm.prank(admin);
        TakumiPay.PointDeposit memory dep = wallet.getPointDepositByRef(refId);

        assertEq(dep.walletAddress, user1);
        assertEq(dep.tokenAddress, address(usdc));
        assertEq(dep.amount, amount);
        assertEq(dep.refId, refId);
        assertEq(dep.timestamp, ts);
    }

    function test_DepositPoints_IncrementsCounter() public {
        vm.startPrank(user1);
        usdc.approve(address(wallet), 200e6);
        wallet.depositPoints(address(usdc), "pt_1", 100e6);
        wallet.depositPoints(address(usdc), "pt_2", 100e6);
        vm.stopPrank();

        assertEq(wallet.pointDepositCounter(), 2);
    }

    function test_DepositPoints_AddsToUserMapping() public {
        uint256 amount = 100e6;

        vm.startPrank(user1);
        usdc.approve(address(wallet), amount);
        wallet.depositPoints(address(usdc), "pt_user1", amount);
        vm.stopPrank();

        vm.prank(admin);
        assertEq(wallet.getUserPointDepositCount(user1), 1);
    }

    function test_DepositPoints_EmitsEvent() public {
        uint256 amount = 100e6;
        string memory refId = "pt_event1";

        vm.startPrank(user1);
        usdc.approve(address(wallet), amount);

        vm.expectEmit(true, true, true, true);
        emit TakumiPay.PointDepositCreated(
            1,
            user1,
            address(usdc),
            refId,
            amount,
            block.timestamp
        );
        wallet.depositPoints(address(usdc), refId, amount);
        vm.stopPrank();
    }

    function test_DepositPoints_RevertIf_TokenNotAllowed() public {
        vm.startPrank(user1);
        usdt.approve(address(wallet), 100e6);
        vm.expectRevert(TakumiPay.TokenNotAllowed.selector);
        wallet.depositPoints(address(usdt), "pt_usdt1", 100e6);
        vm.stopPrank();
    }

    function test_DepositPoints_RevertIf_DuplicateRefId() public {
        string memory refId = "pt_dup1";

        vm.startPrank(user1);
        usdc.approve(address(wallet), 200e6);
        wallet.depositPoints(address(usdc), refId, 100e6);

        vm.expectRevert(TakumiPay.RefConsumed.selector);
        wallet.depositPoints(address(usdc), refId, 100e6);
        vm.stopPrank();
    }

    function test_DepositPoints_RevertIf_ZeroAmount() public {
        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        vm.expectRevert(TakumiPay.ZeroAmount.selector);
        wallet.depositPoints(address(usdc), "pt_zero", 0);
        vm.stopPrank();
    }

    function test_DepositPoints_RevertIf_Paused() public {
        wallet.setPointDepositsPaused(true);

        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        vm.expectRevert(TakumiPay.PointDepositsPaused.selector);
        wallet.depositPoints(address(usdc), "pt_paused", 100e6);
        vm.stopPrank();
    }

    function test_DepositPoints_RevertIf_InsufficientAllowance() public {
        vm.prank(user1);
        vm.expectRevert();
        wallet.depositPoints(address(usdc), "pt_noallowance", 100e6);
    }

    // ====== getPointDepositByRef ======

    function test_GetPointDepositByRef_Success() public {
        uint256 amount = 75e6;
        string memory refId = "pt_byref1";

        vm.startPrank(user1);
        usdc.approve(address(wallet), amount);
        wallet.depositPoints(address(usdc), refId, amount);
        vm.stopPrank();

        vm.prank(admin);
        TakumiPay.PointDeposit memory dep = wallet.getPointDepositByRef(refId);
        assertEq(dep.amount, amount);
        assertEq(dep.walletAddress, user1);
    }

    function test_GetPointDepositByRef_RevertIf_NotFound() public {
        vm.expectRevert(TakumiPay.PointDepositNotFound.selector);
        wallet.getPointDepositByRef("pt_nonexistent");
    }

    // ====== getPointDepositsByAddress pagination ======

    function test_GetPointDepositsByAddress_Pagination() public {
        vm.startPrank(user1);
        usdc.approve(address(wallet), 300e6);
        wallet.depositPoints(address(usdc), "pt_p1", 100e6);
        wallet.depositPoints(address(usdc), "pt_p2", 100e6);
        wallet.depositPoints(address(usdc), "pt_p3", 100e6);
        vm.stopPrank();

        vm.startPrank(admin);

        TakumiPay.PointDeposit[] memory page1 = wallet.getPointDepositsByAddress(user1, 0, 2);
        assertEq(page1.length, 2);
        assertEq(page1[0].refId, "pt_p1");
        assertEq(page1[1].refId, "pt_p2");

        TakumiPay.PointDeposit[] memory page2 = wallet.getPointDepositsByAddress(user1, 2, 2);
        assertEq(page2.length, 1);
        assertEq(page2[0].refId, "pt_p3");

        TakumiPay.PointDeposit[] memory empty = wallet.getPointDepositsByAddress(user1, 10, 2);
        assertEq(empty.length, 0);

        vm.stopPrank();
    }

    // ====== getUserPointDeposits ======

    function test_GetUserPointDeposits_OnlyOwnDeposits() public {
        vm.startPrank(user1);
        usdc.approve(address(wallet), 200e6);
        wallet.depositPoints(address(usdc), "pt_own1", 100e6);
        wallet.depositPoints(address(usdc), "pt_own2", 100e6);
        vm.stopPrank();

        vm.startPrank(user2);
        usdc.approve(address(wallet), 100e6);
        wallet.depositPoints(address(usdc), "pt_other1", 100e6);
        vm.stopPrank();

        vm.prank(user1);
        TakumiPay.PointDeposit[] memory result = wallet.getUserPointDeposits(0, 10);
        assertEq(result.length, 2);
        assertEq(result[0].walletAddress, user1);
        assertEq(result[1].walletAddress, user1);
    }

    // ====== getUserPointDepositCount ======

    function test_GetUserPointDepositCount() public {
        vm.startPrank(user1);
        usdc.approve(address(wallet), 300e6);
        wallet.depositPoints(address(usdc), "pt_cnt1", 100e6);
        wallet.depositPoints(address(usdc), "pt_cnt2", 100e6);
        wallet.depositPoints(address(usdc), "pt_cnt3", 100e6);
        vm.stopPrank();

        vm.prank(admin);
        assertEq(wallet.getUserPointDepositCount(user1), 3);
    }

    // ====== Token Whitelist Management ======

    function test_AddAllowedPaymentToken_Success() public {
        wallet.addAllowedPaymentToken(address(usdt));
        assertTrue(wallet.allowedPaymentTokens(address(usdt)));
    }

    function test_AddAllowedPaymentToken_EmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit TakumiPay.AllowedPaymentTokenAdded(address(usdt));
        wallet.addAllowedPaymentToken(address(usdt));
    }

    function test_AddAllowedPaymentToken_RevertIf_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert(TakumiPay.NotOwner.selector);
        wallet.addAllowedPaymentToken(address(usdt));
    }

    function test_AddAllowedPaymentToken_RevertIf_AlreadyAllowed() public {
        vm.expectRevert(TakumiPay.TokenAlreadyAllowed.selector);
        wallet.addAllowedPaymentToken(address(usdc));
    }

    /// address(0) is native, and native is gated by the same allowlist as any
    /// ERC-20 — so allowlisting it is valid, not an error.
    function test_AddAllowedPaymentToken_AcceptsNative() public {
        wallet.addAllowedPaymentToken(address(0));
        assertTrue(wallet.isAllowedPaymentToken(address(0)));
    }

    function test_RemoveAllowedPaymentToken_Success() public {
        wallet.removeAllowedPaymentToken(address(usdc));
        assertFalse(wallet.allowedPaymentTokens(address(usdc)));
    }

    function test_RemoveAllowedPaymentToken_EmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit TakumiPay.AllowedPaymentTokenRemoved(address(usdc));
        wallet.removeAllowedPaymentToken(address(usdc));
    }

    function test_RemoveAllowedPaymentToken_RevertIf_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert(TakumiPay.NotOwner.selector);
        wallet.removeAllowedPaymentToken(address(usdc));
    }

    function test_GetAllowedPaymentTokens() public {
        wallet.addAllowedPaymentToken(address(usdt));
        address[] memory tokens = wallet.getAllowedPaymentTokens();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(usdc));
        assertEq(tokens[1], address(usdt));
    }

    function test_IsAllowedPaymentToken() public {
        assertTrue(wallet.isAllowedPaymentToken(address(usdc)));
        assertFalse(wallet.isAllowedPaymentToken(address(usdt)));
    }

    // ====== Pause Control ======

    function test_SetPointDepositsPaused_Success() public {
        wallet.setPointDepositsPaused(true);
        assertTrue(wallet.pointDepositsPaused());

        wallet.setPointDepositsPaused(false);
        assertFalse(wallet.pointDepositsPaused());
    }

    function test_SetPointDepositsPaused_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit TakumiPay.PointDepositsPausedToggled(true);
        wallet.setPointDepositsPaused(true);
    }

    function test_SetPointDepositsPaused_RevertIf_NotAdminOrOwner() public {
        vm.prank(user1);
        vm.expectRevert(TakumiPay.NotAdminOrOwner.selector);
        wallet.setPointDepositsPaused(true);
    }

    // ====== Existing Functions Unaffected ======

    function test_ExistingFunctions_Unaffected_CreateTransaction() public {
        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        wallet.createTransaction("booking1", 1, "variant1", address(usdc), "tx_ref1", 100e6);
        vm.stopPrank();

        assertEq(wallet.txCounter(), 1);
    }

    function test_ExistingFunctions_Unaffected_GetTransactionByRef() public {
        vm.startPrank(user1);
        usdc.approve(address(wallet), 100e6);
        wallet.createTransaction("booking2", 2, "variant2", address(usdc), "tx_ref2", 100e6);
        vm.stopPrank();

        vm.prank(admin);
        TakumiPay.Transaction memory txData = wallet.getTransactionByRef("tx_ref2");
        assertEq(txData.bookingId, "booking2");
    }

    /// A refId is one idempotency key across flows — the API claims it in a single
    /// ReferenceId table and credits only the first use, so the contract must refuse a
    /// second on-chain payment under the same key rather than take money twice.
    function test_RevertIf_PointDepositReusesBookingRefId() public {
        string memory sharedRef = "shared_ref_1";

        vm.startPrank(user1);
        usdc.approve(address(wallet), 200e6);
        wallet.createTransaction("booking3", 3, "variant3", address(usdc), sharedRef, 100e6);

        vm.expectRevert(TakumiPay.RefConsumed.selector);
        wallet.depositPoints(address(usdc), sharedRef, 100e6);
        vm.stopPrank();

        assertEq(wallet.pointDepositCounter(), 0);
    }

    function test_RevertIf_BookingReusesPointDepositRefId() public {
        string memory sharedRef = "pt_shared";

        vm.startPrank(user1);
        usdc.approve(address(wallet), 200e6);
        wallet.depositPoints(address(usdc), sharedRef, 100e6);

        vm.expectRevert(TakumiPay.RefConsumed.selector);
        wallet.createTransaction("booking3", 3, "variant3", address(usdc), sharedRef, 100e6);

        TakumiPay.TransactionParams[] memory params = new TakumiPay.TransactionParams[](1);
        params[0] = TakumiPay.TransactionParams("booking3", 3, "variant3", address(usdc), sharedRef, 100e6);
        vm.expectRevert(TakumiPay.RefConsumed.selector);
        wallet.createTransactionBatch(params);
        vm.stopPrank();

        assertEq(wallet.txCounter(), 0);
    }
}
