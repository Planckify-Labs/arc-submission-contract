// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TakumiPay.sol";

/// @notice Rehearses the 2.1.0 -> 2.3.0 upgrade against the live mainnet proxies on
///         local forks. Nothing is broadcast. Skipped unless RUN_FORK_TESTS=true:
///           RUN_FORK_TESTS=true forge test --match-contract UpgradeFork -vv
///
///         RPCs default to public endpoints; override with ARC_RPC_URL,
///         ARBITRUM_RPC_URL or MONAD_RPC_URL. To rehearse against an implementation
///         already deployed on a chain (the exact bytecode the owner will switch to)
///         rather than one compiled from this checkout, set
///         NEW_IMPLEMENTATION_<chainId>, e.g. NEW_IMPLEMENTATION_5042.
contract TakumiPayUpgradeForkTest is Test {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 internal constant LAST_SLOT = 74; // owner through the end of __gap

    function setUp() public {
        if (!vm.envOr("RUN_FORK_TESTS", false)) vm.skip(true);
    }

    function test_arcMainnet() public {
        vm.createSelectFork(vm.envOr("ARC_RPC_URL", string("https://rpc.mainnet.arc.io")));
        _rehearse(TakumiPay(payable(0xF44Af1f2b422D66D60aAE5ceFCcbCBF299D01aBF)));
    }

    function test_arbitrumOne() public {
        vm.createSelectFork(vm.envOr("ARBITRUM_RPC_URL", string("https://arb1.arbitrum.io/rpc")));
        _rehearse(TakumiPay(payable(0xdE981573883294dfD35A7F0F399DB7e439E1f56B)));
    }

    function test_monadMainnet() public {
        vm.createSelectFork(vm.envOr("MONAD_RPC_URL", string("https://rpc.monad.xyz")));
        _rehearse(TakumiPay(payable(0x479B0843C3e0627f36551660506dEd5b349Fa968)));
    }

    /// Everything the owner and clients can read, through getters 2.1.0 and 2.3.0
    /// share, for every allowlisted token plus native.
    function _state(TakumiPay proxy) internal view returns (bytes memory state) {
        state = abi.encode(
            proxy.owner(),
            proxy.pendingOwner(),
            proxy.backendSigner(),
            proxy.paused(),
            proxy.pointDepositsPaused(),
            proxy.withdrawalDelay(),
            proxy.nativeAliasToken(),
            proxy.DOMAIN_SEPARATOR(),
            proxy.txCounter(),
            proxy.pointDepositCounter(),
            proxy.getAllAdmins(),
            proxy.getAllowedPaymentTokens()
        );
        address[] memory tokens = _tokensAndNative(proxy);
        for (uint256 i = 0; i < tokens.length; i++) {
            address t = tokens[i];
            state = bytes.concat(
                state,
                abi.encode(
                    proxy.sweepCap(t),
                    proxy.sweptInWindow(t),
                    proxy.sweepWindowStart(t),
                    proxy.platformFeeAccrued(t),
                    proxy.maxTransactionAmount(t),
                    proxy.getPendingChange(keccak256(abi.encode("sweepCap", t)))
                )
            );
        }
        state = bytes.concat(
            state,
            abi.encode(
                proxy.getPendingChange(keccak256("withdrawalDelay")), proxy.getPendingChange(keccak256("upgrade"))
            )
        );
    }

    function _tokensAndNative(TakumiPay proxy) internal view returns (address[] memory all) {
        address[] memory allowed = proxy.getAllowedPaymentTokens();
        all = new address[](allowed.length + 1);
        for (uint256 i = 0; i < allowed.length; i++) {
            all[i] = allowed[i];
        }
        // address(0) last; if native is allowlisted it simply appears twice.
    }

    function _slots(TakumiPay proxy) internal view returns (bytes32[] memory slots) {
        slots = new bytes32[](LAST_SLOT + 1);
        for (uint256 i = 0; i <= LAST_SLOT; i++) {
            slots[i] = vm.load(address(proxy), bytes32(i));
        }
    }

    function _rehearse(TakumiPay proxy) internal {
        assertEq(proxy.version(), "2.1.0", "expected the live proxy to run 2.1.0");
        address owner = proxy.owner();
        uint256 delay = proxy.withdrawalDelay();
        bytes memory before = _state(proxy);
        bytes32[] memory slotsBefore = _slots(proxy);

        address impl = vm.envOr(string.concat("NEW_IMPLEMENTATION_", vm.toString(block.chainid)), address(0));
        if (impl == address(0)) impl = address(new TakumiPay());
        assertGt(impl.code.length, 0, "NEW_IMPLEMENTATION has no code on this chain");
        assertLe(impl.code.length, 24_576, "over the EIP-170 limit");

        // 2.1.0's _authorizeUpgrade is owner-only with no queue, so this lands at once.
        vm.prank(owner);
        proxy.upgradeToAndCall(impl, "");

        assertEq(proxy.version(), "2.3.0");
        assertEq(address(uint160(uint256(vm.load(address(proxy), IMPLEMENTATION_SLOT)))), impl);
        assertEq(_state(proxy), before, "a readable value changed");
        bytes32[] memory slotsAfter = _slots(proxy);
        for (uint256 i = 0; i <= LAST_SLOT; i++) {
            assertEq(slotsAfter[i], slotsBefore[i], "a contract slot changed");
        }
        assertEq(proxy.withdrawalDelayRaisedAt(), 0);

        // Report what the new rules make of the live state.
        console.log("proxy", address(proxy), "withdrawalDelay", delay);
        address[] memory tokens = _tokensAndNative(proxy);
        for (uint256 i = 0; i < tokens.length; i++) {
            address t = tokens[i];
            uint256 cap = proxy.sweepCap(t);
            uint256 allowance = proxy.sweepAllowance(t);
            assertTrue(cap == type(uint256).max ? allowance == cap : allowance <= cap, "allowance above cap");
            uint256 balance = t == address(0) ? address(proxy).balance : IERC20(t).balanceOf(address(proxy));
            uint256 fees = proxy.platformFeeAccrued(t);
            console.log("  token", t);
            console.log("    cap / allowance now", cap, allowance);
            console.log("    balance / accrued fees", balance, fees);
            if (fees > balance) console.log("    WARNING: fees exceed balance; sweepMerchantBacking reverts until fees are swept");
        }

        // From here on the next upgrade is queued, code-bound and waits the live delay.
        address next = address(new TakumiPay());
        vm.startPrank(owner);
        vm.expectRevert(TakumiPay.UpgradeNotQueued.selector);
        proxy.upgradeToAndCall(next, "");

        proxy.queueUpgrade(next);
        if (delay > 0) {
            vm.expectRevert(TakumiPay.TimelockNotExpired.selector);
            proxy.upgradeToAndCall(next, "");
            vm.warp(vm.getBlockTimestamp() + delay);
        }
        proxy.upgradeToAndCall(next, "");
        vm.stopPrank();
        assertEq(address(uint160(uint256(vm.load(address(proxy), IMPLEMENTATION_SLOT)))), next);
    }
}
