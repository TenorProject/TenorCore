// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {TenorIdentityRegistry} from "../src/periphery/TenorIdentityRegistry.sol";
import {TenorCompliance} from "../src/periphery/TenorCompliance.sol";

/// forge script script/01_DeployPeriphery.s.sol --rpc-url hedera_testnet --broadcast
contract DeployPeriphery is Script {
    function run() external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // verifyEveryone = true unblocks development. Flip to false and whitelist the two
        // demo counterparties before filming, so the rejection comes from the registry itself.
        TenorIdentityRegistry registry = new TenorIdentityRegistry(true);
        TenorCompliance compliance = new TenorCompliance();

        vm.stopBroadcast();

        console.log("TENOR_IDENTITY_REGISTRY=", address(registry));
        console.log("TENOR_COMPLIANCE=", address(compliance));
        console.log("Next: 02_WireBond, needs ROLE_TREX_OWNER on the bond.");
    }
}
