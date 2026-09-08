// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TenorSettlement} from "../src/TenorSettlement.sol";

/// NOTE: forge's local EVM has no Hedera system contracts. `0x16b` (schedule service) and
/// `0x167` (HTS) do not exist here, so anything touching them must be mocked and passing
/// these tests proves very little. The real mechanism only runs via:
///   forge script ... --rpc-url hedera_testnet --broadcast
///
/// What IS worth unit testing locally, with mocks:
///   - closeRepo never reverts on any branch
///   - closeRepo is idempotent (second call after Closed/Defaulted is a no-op)
///   - the default branch fires when the borrower has no allowance or no balance
///   - openRepo rejects a maturity in the past
///   - openRepo rejects when the contract holds too little HBAR for the unwind
contract TenorSettlementTest is Test {
    TenorSettlement settlement;

    function setUp() public {
        settlement = new TenorSettlement();
    }

    function test_deploys() public view {
        assertEq(settlement.owner(), address(this));
        assertEq(settlement.SCHEDULE_GAS(), 200_000);
    }

    // TODO(day 1): MockScheduleService + MockHold + MockERC20, then the five cases above.
}
