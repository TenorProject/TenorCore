// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ITenorWiring} from "../src/interfaces/ITenorWiring.sol";

/// Points the ATS bond at our own registry and compliance module.
/// REQUIRES ROLE_TREX_OWNER (0xd9e126...f7e6f0) on the caller, NOT DEFAULT_ADMIN_ROLE.
/// forge script script/02_WireBond.s.sol --rpc-url hedera_testnet --broadcast
contract WireBond is Script {
    function run() external {
        ITenorWiring bond = ITenorWiring(vm.envAddress("ATS_BOND"));

        console.log("before: identityRegistry =", bond.identityRegistry());
        console.log("before: compliance       =", bond.compliance());

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        bond.setIdentityRegistry(vm.envAddress("TENOR_IDENTITY_REGISTRY"));
        bond.setCompliance(vm.envAddress("TENOR_COMPLIANCE"));
        vm.stopBroadcast();

        console.log("after:  identityRegistry =", bond.identityRegistry());
        console.log("after:  compliance       =", bond.compliance());
    }
}
