// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TakumiPay.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract AliasMockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Stands in for a stablecoin-native chain's token, where an ERC-20 transfer also
///      moves the recipient's native balance because they are one asset. Used to prove
///      that native landing on the contract mid-call no longer bricks the transaction.
contract NativePushingERC20 is ERC20 {
    constructor() ERC20("Native Alias USDC", "USDC") {}

    receive() external payable {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool ok = super.transferFrom(from, to, amount);
        (bool sent,) = payable(to).call{value: 1 wei}("");
        require(sent, "native push failed");
        return ok;
    }
}

/// @dev Mimics Arc's USDC: ONE balance held at 18-decimal native precision, exposed
///      through a 6-decimal ERC-20 interface. `balanceOf` therefore truncates — dust
///      below 1e12 native (a millionth of a dollar) is invisible through this view.
///      Used to prove `_pullToken`'s fee-on-transfer guard survives that truncation.
contract ArcUsdcMock {
    uint256 public constant SCALE = 1e12; // 1e18 native == 1e6 ERC-20

    mapping(address => uint256) public nativeBalance; // 18 decimals
    mapping(address => mapping(address => uint256)) public allowance; // 6 decimals

    function decimals() external pure returns (uint8) {
        return 6;
    }

    /// The 6-decimal view of an 18-decimal balance. Rounds down.
    function balanceOf(address account) public view returns (uint256) {
        return nativeBalance[account] / SCALE;
    }

    function mintNative(address to, uint256 amount18) external {
        nativeBalance[to] += amount18;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "insufficient allowance");
        allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    /// An ERC-20 transfer of `amount6` moves exactly `amount6 * SCALE` of the one
    /// underlying balance — never a fraction of a unit.
    function _move(address from, address to, uint256 amount6) internal {
        uint256 amount18 = amount6 * SCALE;
        require(nativeBalance[from] >= amount18, "insufficient balance");
        nativeBalance[from] -= amount18;
        nativeBalance[to] += amount18;
    }
}

/// @notice Covers the native-alias configuration (Arc-style chains, where the native
///         coin and a USDC ERC-20 are two views of one balance) and the sweep-cap
///         coverage of every exit path.
contract TakumiPayNativeAliasTest is Test {
    TakumiPay public wallet;
    AliasMockERC20 public usdc;
    AliasMockERC20 public usdt;

    address public owner;
    address public user1;
    address public recipient;

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        recipient = makeAddr("recipient");

        TakumiPay implementation = new TakumiPay();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(TakumiPay.initialize, (owner, makeAddr("backendSigner"), address(0)))
        );
        wallet = TakumiPay(payable(address(proxy)));

        usdc = new AliasMockERC20("USD Coin", "USDC");
        usdt = new AliasMockERC20("Tether USD", "USDT");

        wallet.addAllowedPaymentToken(address(usdc));

        usdc.mint(user1, 10_000e6);
        vm.deal(user1, 100 ether);

        _setSweepCap(address(usdc), type(uint256).max);
        _setSweepCap(address(usdt), type(uint256).max);
    }

    function _setSweepCap(address token, uint256 cap) internal {
        if (cap > wallet.sweepCap(token)) {
            wallet.queueSweepCap(token, cap);
            wallet.applySweepCap(token);
        } else {
            wallet.setSweepCap(token, cap);
        }
    }

    function _payUsdc(string memory refId, uint256 amount) internal {
        vm.startPrank(user1);
        usdc.approve(address(wallet), amount);
        wallet.createTransaction("b1", 1, "v1", address(usdc), refId, amount);
        vm.stopPrank();
    }

    // ====== setNativeAliasToken ======

    function test_setNativeAliasToken_success() public {
        assertFalse(wallet.isNativeAliased());
        assertEq(wallet.nativeAliasToken(), address(0));

        vm.expectEmit(true, false, false, false);
        emit TakumiPay.NativeAliasTokenSet(address(usdc));
        wallet.setNativeAliasToken(address(usdc));

        assertTrue(wallet.isNativeAliased());
        assertEq(wallet.nativeAliasToken(), address(usdc));
    }

    function test_revert_setNativeAliasToken_zeroAddress() public {
        vm.expectRevert(TakumiPay.ZeroAddress.selector);
        wallet.setNativeAliasToken(address(0));
    }

    function test_revert_setNativeAliasToken_isSetOnce() public {
        wallet.setNativeAliasToken(address(usdc));

        vm.expectRevert(TakumiPay.NativeAliasAlreadySet.selector);
        wallet.setNativeAliasToken(address(usdt));
    }

    function test_revert_setNativeAliasToken_notOwner() public {
        vm.prank(user1);
        vm.expectRevert(TakumiPay.NotOwner.selector);
        wallet.setNativeAliasToken(address(usdc));
    }

    /// Refuses to create a config where one asset is already allowlisted twice.
    function test_revert_setNativeAliasToken_whenNativeAlreadyAllowlisted() public {
        wallet.addAllowedPaymentToken(address(0));

        vm.expectRevert(TakumiPay.NativeAliasNotAllowlistable.selector);
        wallet.setNativeAliasToken(address(usdc));
    }

    // ====== Allowlist on an alias chain ======

    function test_revert_addAllowedPaymentToken_nativeOnAliasChain() public {
        wallet.setNativeAliasToken(address(usdc));

        vm.expectRevert(TakumiPay.NativeDisabledOnAliasChain.selector);
        wallet.addAllowedPaymentToken(address(0));
    }

    function test_addAllowedPaymentToken_otherErc20StillWorks_onAliasChain() public {
        wallet.setNativeAliasToken(address(usdc));

        wallet.addAllowedPaymentToken(address(usdt));
        assertTrue(wallet.isAllowedPaymentToken(address(usdt)));
    }

    // ====== Payments on an alias chain ======

    function test_erc20PaymentStillWorks_onAliasChain() public {
        wallet.setNativeAliasToken(address(usdc));

        _payUsdc("ref1", 100e6);

        assertEq(wallet.txCounter(), 1);
        assertEq(usdc.balanceOf(address(wallet)), 100e6);
    }

    function test_revert_nativePayment_onAliasChain() public {
        wallet.setNativeAliasToken(address(usdc));

        // Native can never have been allowlisted, so the payment is rejected by the
        // existing allowlist gate.
        vm.prank(user1);
        vm.expectRevert(TakumiPay.TokenNotAllowed.selector);
        wallet.createTransaction{value: 1 ether}("b1", 1, "v1", address(0), "ref1", 1 ether);
    }

    // ====== Exits on an alias chain ======

    function test_revert_withdraw_nativeOnAliasChain() public {
        wallet.setNativeAliasToken(address(usdc));
        vm.deal(address(wallet), 5 ether);

        vm.expectRevert(TakumiPay.NativeDisabledOnAliasChain.selector);
        wallet.withdraw(address(0), recipient, 1 ether);
    }

    function test_revert_withdrawAll_nativeOnAliasChain() public {
        wallet.setNativeAliasToken(address(usdc));
        vm.deal(address(wallet), 5 ether);

        vm.expectRevert(TakumiPay.NativeDisabledOnAliasChain.selector);
        wallet.withdrawAll(address(0), recipient);
    }

    function test_revert_recoverToken_nativeOnAliasChain() public {
        wallet.setNativeAliasToken(address(usdc));
        vm.deal(address(wallet), 5 ether);

        vm.expectRevert(TakumiPay.NativeDisabledOnAliasChain.selector);
        wallet.recoverToken(address(0), recipient, 1 ether);
    }

    function test_revert_queueWithdrawal_nativeOnAliasChain() public {
        wallet.setNativeAliasToken(address(usdc));
        wallet.setWithdrawalDelay(1 days);

        vm.expectRevert(TakumiPay.NativeDisabledOnAliasChain.selector);
        wallet.queueWithdrawal(address(0), recipient, 1 ether);
    }

    function test_revert_sweepMerchantBacking_nativeOnAliasChain() public {
        wallet.setNativeAliasToken(address(usdc));
        vm.deal(address(wallet), 5 ether);

        vm.expectRevert(TakumiPay.NativeDisabledOnAliasChain.selector);
        wallet.sweepMerchantBacking(address(0), recipient, 1 ether);
    }

    /// The whole point of closing the native path: the same money is still reachable,
    /// through the ERC-20 view, in the units the caps and ledgers speak.
    function test_erc20SweepStillWorks_onAliasChain() public {
        wallet.setNativeAliasToken(address(usdc));
        _payUsdc("ref1", 100e6);

        wallet.sweepMerchantBacking(address(usdc), recipient, 100e6);

        assertEq(usdc.balanceOf(recipient), 100e6);
        assertEq(usdc.balanceOf(address(wallet)), 0);
    }

    // ====== Regression: chains with no alias are untouched ======

    function test_nativePayment_stillWorks_whenNoAlias() public {
        wallet.addAllowedPaymentToken(address(0));

        vm.prank(user1);
        wallet.createTransaction{value: 1 ether}("b1", 1, "v1", address(0), "ref1", 1 ether);

        assertEq(wallet.txCounter(), 1);
        assertEq(address(wallet).balance, 1 ether);
    }

    function test_nativeWithdraw_stillWorks_whenNoAlias() public {
        _setSweepCap(address(0), type(uint256).max);
        vm.deal(address(wallet), 5 ether);

        uint256 before = recipient.balance;
        wallet.withdraw(address(0), recipient, 2 ether);

        assertEq(recipient.balance - before, 2 ether);
    }

    function test_nativeSweep_stillWorks_whenNoAlias() public {
        _setSweepCap(address(0), type(uint256).max);
        vm.deal(address(wallet), 5 ether);

        uint256 before = recipient.balance;
        wallet.sweepMerchantBacking(address(0), recipient, 2 ether);

        assertEq(recipient.balance - before, 2 ether);
    }

    // ====== Sweep cap now bounds every exit ======

    function test_withdraw_boundedBySweepCap() public {
        _payUsdc("ref1", 100e6);
        _setSweepCap(address(usdc), 40e6);

        wallet.withdraw(address(usdc), recipient, 40e6);

        vm.expectRevert(TakumiPay.SweepCapExceeded.selector);
        wallet.withdraw(address(usdc), recipient, 1e6);
    }

    function test_revert_withdraw_whenSweepCapUnset() public {
        _payUsdc("ref1", 100e6);
        wallet.setSweepCap(address(usdc), 0);

        vm.expectRevert(TakumiPay.SweepCapNotSet.selector);
        wallet.withdraw(address(usdc), recipient, 1e6);
    }

    function test_recoverToken_boundedBySweepCap() public {
        usdt.mint(address(wallet), 100e6);
        _setSweepCap(address(usdt), 40e6);

        wallet.recoverToken(address(usdt), recipient, 40e6);

        vm.expectRevert(TakumiPay.SweepCapExceeded.selector);
        wallet.recoverToken(address(usdt), recipient, 1e6);
    }

    /// The timelocked path is capped too — otherwise a compromised owner just queues a
    /// full-treasury withdrawal and waits out the delay, and the cap means nothing.
    function test_executeWithdrawal_boundedBySweepCap() public {
        _payUsdc("ref1", 100e6);
        _setSweepCap(address(usdc), 40e6);
        wallet.setWithdrawalDelay(1 days);

        bytes32 wId = wallet.queueWithdrawal(address(usdc), recipient, 100e6);
        vm.warp(block.timestamp + 1 days);

        vm.expectRevert(TakumiPay.SweepCapExceeded.selector);
        wallet.executeWithdrawal(wId);
    }

    function test_withdrawAll_boundedBySweepCap() public {
        _payUsdc("ref1", 100e6);
        _setSweepCap(address(usdc), 40e6);

        vm.expectRevert(TakumiPay.SweepCapExceeded.selector);
        wallet.withdrawAll(address(usdc), recipient);
    }

    function test_sweepWindow_sharedAcrossWithdrawAndSweep() public {
        _payUsdc("ref1", 100e6);
        _setSweepCap(address(usdc), 40e6);

        wallet.sweepMerchantBacking(address(usdc), recipient, 30e6);

        // withdraw draws from the same window, not a fresh one.
        vm.expectRevert(TakumiPay.SweepCapExceeded.selector);
        wallet.withdraw(address(usdc), recipient, 20e6);

        wallet.withdraw(address(usdc), recipient, 10e6);
        assertEq(usdc.balanceOf(recipient), 40e6);
    }

    // ====== _pullToken under Arc's truncating balanceOf ======

    /// `_pullToken` brackets the transfer with balanceOf reads and demands the delta
    /// equal `amount` exactly. On Arc that view truncates an 18-decimal balance to 6,
    /// which looks like it should break the check — it does not. The dust is carried
    /// unchanged through both reads and cancels out, because an ERC-20 transfer always
    /// moves a whole multiple of 1e12 native units.
    function test_pullToken_exactDespiteArcTruncation() public {
        ArcUsdcMock arcUsdc = new ArcUsdcMock();
        wallet.addAllowedPaymentToken(address(arcUsdc));
        wallet.setNativeAliasToken(address(arcUsdc));

        // The contract already holds dust invisible through the 6-decimal view.
        uint256 dust = 999_999_999_999; // 1 wei short of a millionth of a dollar
        arcUsdc.mintNative(address(wallet), dust);
        assertEq(arcUsdc.balanceOf(address(wallet)), 0, "dust must be invisible");

        arcUsdc.mintNative(user1, 1_000e18);
        vm.startPrank(user1);
        arcUsdc.approve(address(wallet), 100e6);
        wallet.createTransaction("b1", 1, "v1", address(arcUsdc), "ref1", 100e6);
        vm.stopPrank();

        assertEq(wallet.txCounter(), 1);
        assertEq(arcUsdc.balanceOf(address(wallet)), 100e6);
        // The dust survived untouched — it was never part of the delta.
        assertEq(arcUsdc.nativeBalance(address(wallet)), uint256(100e6) * 1e12 + dust);
    }

    function testFuzz_pullToken_exactDespiteArcTruncation(uint256 dust, uint256 amount) public {
        dust = bound(dust, 0, 1e12 - 1);
        amount = bound(amount, 1, 1_000_000e6);

        ArcUsdcMock arcUsdc = new ArcUsdcMock();
        wallet.addAllowedPaymentToken(address(arcUsdc));

        arcUsdc.mintNative(address(wallet), dust);
        arcUsdc.mintNative(user1, amount * 1e12);

        vm.startPrank(user1);
        arcUsdc.approve(address(wallet), amount);
        wallet.createTransaction("b1", 1, "v1", address(arcUsdc), "ref1", amount);
        vm.stopPrank();

        assertEq(arcUsdc.balanceOf(address(wallet)), amount);
        assertEq(arcUsdc.nativeBalance(address(wallet)), amount * 1e12 + dust);
    }

    /// Same truncating view on the way out.
    function test_sweep_exactDespiteArcTruncation() public {
        ArcUsdcMock arcUsdc = new ArcUsdcMock();
        wallet.addAllowedPaymentToken(address(arcUsdc));
        wallet.setNativeAliasToken(address(arcUsdc));
        _setSweepCap(address(arcUsdc), type(uint256).max);

        arcUsdc.mintNative(address(wallet), 999_999_999_999);
        arcUsdc.mintNative(user1, 1_000e18);
        vm.startPrank(user1);
        arcUsdc.approve(address(wallet), 100e6);
        wallet.createTransaction("b1", 1, "v1", address(arcUsdc), "ref1", 100e6);
        vm.stopPrank();

        wallet.sweepMerchantBacking(address(arcUsdc), recipient, 100e6);

        assertEq(arcUsdc.balanceOf(recipient), 100e6);
        // Only the untouchable sub-unit dust is left behind.
        assertEq(arcUsdc.balanceOf(address(wallet)), 0);
        assertEq(arcUsdc.nativeBalance(address(wallet)), 999_999_999_999);
    }

    // ====== receive() no longer reverts under the reentrancy guard ======

    /// A counterparty can deliver native value to the contract in the middle of a
    /// nonReentrant call — a refund inside a token transfer, say. With `receive()`
    /// guarded, that reverted the whole payment even though receive() only emits.
    ///
    /// This is not an Arc-specific fix: Arc's ERC-20 USDC transfer moves the balance at
    /// state level and never invokes the recipient's receive(). Verified by eth_call
    /// against the live node — a USDC transfer to an address whose code unconditionally
    /// reverts still succeeds, while a plain native send to it reverts.
    function test_payment_succeeds_whenNativeArrivesMidCall() public {
        NativePushingERC20 token = new NativePushingERC20();
        vm.deal(address(token), 1 ether);
        token.mint(user1, 1_000e6);
        wallet.addAllowedPaymentToken(address(token));

        vm.startPrank(user1);
        token.approve(address(wallet), 100e6);
        wallet.createTransaction("b1", 1, "v1", address(token), "ref1", 100e6);
        vm.stopPrank();

        assertEq(wallet.txCounter(), 1);
        assertEq(token.balanceOf(address(wallet)), 100e6);
        assertEq(address(wallet).balance, 1 wei);
    }
}
