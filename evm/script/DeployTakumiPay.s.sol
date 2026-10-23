// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TakumiPay} from "../src/TakumiPay.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Deploys TakumiPay behind a UUPS ERC-1967 proxy.
///
/// Usage:
///   BACKEND_SIGNER=0x... forge script script/DeployTakumiPay.s.sol \
///     --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast \
///     --verify
///
/// The deployer address becomes the initial owner.
/// Set INITIAL_OWNER env var to override (useful for multisig deployments).
///
/// Post-deploy runbook — ORDER MATTERS. Raising a sweep cap and lowering the withdrawal
/// delay are both "loosenings", so they become subject to whatever delay is already in
/// force. Do them first, while withdrawalDelay is still 0:
///
///   1. On a stablecoin-native chain the native alias is set by `initialize` itself, so
///      there is no window where native and the ERC-20 are both live. On Arc (5042,
///      5042002) this script passes the USDC ERC-20 at 0x3600…0000 automatically and
///      the contract refuses to initialize there without one. Set NATIVE_ALIAS_TOKEN
///      to override, e.g. for another stablecoin-native chain.
///
///   2. Allowlist every payment token. On a normal chain that may include native
///      (address(0)); on an alias chain step 1 makes native un-allowlistable:
///        cast send $PROXY "addAllowedPaymentToken(address)" <token>
///
///   3. Set sweep caps. Every exit — sweepPlatformFees, sweepMerchantBacking, withdraw,
///      withdrawAll, recoverToken and executeWithdrawal — is bounded by these, and an
///      unset cap fails closed, so the contract cannot pay anything out until this is
///      done. Raising from 0 is a queue/apply pair that lands in a single block only
///      while withdrawalDelay is 0:
///        cast send $PROXY "queueSweepCap(address,uint256)" <token> <cap>
///        cast send $PROXY "applySweepCap(address)" <token>
///
///   4. Only now raise the withdrawal delay. This also permanently disables the instant
///      withdraw/withdrawAll/recoverToken paths, and becomes the upgrade timelock:
///        cast send $PROXY "setWithdrawalDelay(uint256)" 86400
///
/// Amounts follow the token's own decimals: 6 for USDC-style ERC-20s, 18 for native.
contract DeployTakumiPay is Script {
    address internal constant ARC_USDC = 0x3600000000000000000000000000000000000000;

    function run() external returns (address proxy) {
        address initialOwner = vm.envOr("INITIAL_OWNER", msg.sender);
        address backendSigner = vm.envAddress("BACKEND_SIGNER");
        bool isArc = block.chainid == 5042 || block.chainid == 5042002;
        address nativeAlias = vm.envOr("NATIVE_ALIAS_TOKEN", isArc ? ARC_USDC : address(0));

        vm.startBroadcast();

        // 1. Deploy the implementation (no initializer — _disableInitializers blocks it)
        TakumiPay implementation = new TakumiPay();

        // 2. Deploy the proxy, calling initialize atomically
        bytes memory initData = abi.encodeCall(TakumiPay.initialize, (initialOwner, backendSigner, nativeAlias));
        ERC1967Proxy proxyContract = new ERC1967Proxy(address(implementation), initData);
        proxy = address(proxyContract);

        vm.stopBroadcast();

        console.log("Implementation:", address(implementation));
        console.log("Proxy (use this address):", proxy);
        console.log("Owner:", initialOwner);
        console.log("Backend signer:", backendSigner);
        console.log("Native alias token:", nativeAlias);

        // Persist a clean deployment record to deployments/<chainId>.json
        string memory obj = "deployment";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "proxy", proxy);
        vm.serializeAddress(obj, "implementation", address(implementation));
        vm.serializeAddress(obj, "owner", initialOwner);
        vm.serializeAddress(obj, "backendSigner", backendSigner);
        string memory json = vm.serializeUint(obj, "deployedAt", block.timestamp);

        // writeFile rather than writeJson — writeJson requires the target to already
        // exist, which it never does the first time we deploy to a new chain.
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeFile(path, json);
        console.log("Deployment record written to:", path);
    }
}

/// @notice Deploys a new TakumiPay implementation and starts upgrading a proxy to it.
///
/// From 2.2.0 an upgrade is a queued change: queueUpgrade, wait out the proxy's
/// withdrawalDelay, then upgradeToAndCall. This script deploys the implementation and
/// queues it, and finishes the upgrade in the same run only when nothing has to wait:
///   - the proxy runs 2.1.0, whose _authorizeUpgrade predates the timelock, or
///   - the proxy's withdrawalDelay is 0.
/// Otherwise it prints the unlock time; finish with ApplyUpgradeTakumiPay.
///
/// Usage:
///   PROXY_ADDRESS=0x... forge script script/DeployTakumiPay.s.sol:UpgradeTakumiPay \
///     --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast \
///     --verify
contract UpgradeTakumiPay is Script {
    function run() external {
        TakumiPay proxy = TakumiPay(payable(vm.envAddress("PROXY_ADDRESS")));
        bool legacy = keccak256(bytes(proxy.version())) == keccak256("2.1.0");

        vm.startBroadcast();

        TakumiPay newImplementation = new TakumiPay();

        bool applied;
        if (legacy) {
            proxy.upgradeToAndCall(address(newImplementation), "");
            applied = true;
        } else {
            proxy.queueUpgrade(address(newImplementation));
            if (proxy.withdrawalDelay() == 0) {
                proxy.upgradeToAndCall(address(newImplementation), "");
                applied = true;
            }
        }

        vm.stopBroadcast();

        console.log("New implementation:", address(newImplementation));
        if (applied) {
            console.log("Proxy upgraded:", address(proxy));
            console.log("New version:", proxy.version());
        } else {
            console.log("Upgrade queued; unlocks at:", block.timestamp + proxy.withdrawalDelay());
            console.log("Then run ApplyUpgradeTakumiPay with NEW_IMPLEMENTATION set to the address above.");
        }
    }
}

/// @notice Applies an upgrade queued by UpgradeTakumiPay once its delay has passed.
///
/// Usage:
///   PROXY_ADDRESS=0x... NEW_IMPLEMENTATION=0x... \
///     forge script script/DeployTakumiPay.s.sol:ApplyUpgradeTakumiPay \
///     --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
contract ApplyUpgradeTakumiPay is Script {
    function run() external {
        TakumiPay proxy = TakumiPay(payable(vm.envAddress("PROXY_ADDRESS")));
        address newImplementation = vm.envAddress("NEW_IMPLEMENTATION");

        vm.startBroadcast();
        proxy.upgradeToAndCall(newImplementation, "");
        vm.stopBroadcast();

        console.log("Proxy upgraded:", address(proxy));
        console.log("New version:", proxy.version());
    }
}
