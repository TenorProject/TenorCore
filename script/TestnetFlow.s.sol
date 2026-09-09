// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {TenorSettlement} from "../src/TenorSettlement.sol";
import {MockATS} from "../src/mocks/MockATS.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/**
 * Testnet walkthrough. Each step is a separate entrypoint so you can run them one at a time and
 * inspect the chain between them:
 *
 *   forge script script/TestnetFlow.s.sol --sig "deployAll()"  --rpc-url hedera_testnet --broadcast
 *   forge script script/TestnetFlow.s.sol --sig "openRepo()"   --rpc-url hedera_testnet --broadcast --gas-limit 4000000
 *   forge script script/TestnetFlow.s.sol --sig "status()"     --rpc-url hedera_testnet
 *   forge script script/TestnetFlow.s.sol --sig "closeRepo()"  --rpc-url hedera_testnet --broadcast
 *   forge script script/TestnetFlow.s.sol --sig "repayEarly()" --rpc-url hedera_testnet --broadcast
 *
 * STAGE 1 (this script) uses MockATS and MockERC20 so the ONLY unknown is HIP-1215 scheduling,
 * which is the thing forge test cannot prove. Do not skip to the real bond: if you swap both the
 * securities layer and the scheduling layer at once and it fails, you will not know which broke.
 *
 * STAGE 2 replaces SECURITY with the real ATS bond and CASH with a real HTS token. See TESTNET.md.
 */
contract TestnetFlow is Script {
    bytes32 constant PARTITION = bytes32(uint256(1));
    uint256 constant QTY        = 100e18;
    uint256 constant PRINCIPAL  = 100_000e6;
    uint256 constant REPURCHASE = 100_096e6;

    // Short on purpose so you can watch a real schedule fire without waiting a week.
    uint64  constant TERM       = 15 minutes;
    uint64  constant QUOTE_TTL  = 10 minutes;

    function _lenderPk()   internal view returns (uint256) { return vm.envUint("LENDER_PRIVATE_KEY"); }
    function _borrowerPk() internal view returns (uint256) { return vm.envUint("BORROWER_PRIVATE_KEY"); }
    function _reqId()      internal view returns (bytes32) { return keccak256(bytes(vm.envString("REQUEST_ID"))); }

    /// Step 1. Deploy everything and put both parties in position.
    function deployAll() external {
        address lender   = vm.addr(_lenderPk());
        address borrower = vm.addr(_borrowerPk());

        // The settlement contract PAYS for every scheduled unwind (~0.12 HBAR each), so it must
        // be funded. NOTE THE UNITS: msg.value is weibar (18 dp), so 5e18 == 5 HBAR. But
        // address(this).balance reads back in TINYBARS (8 dp), which is what
        // MIN_HBAR_PER_REPO (30_000_000 == 0.3 HBAR) is denominated in.
        vm.startBroadcast(_lenderPk());
        TenorSettlement settlement = new TenorSettlement{value: 5e18}();
        MockATS ats   = new MockATS();
        MockERC20 cash = new MockERC20();

        cash.mint(lender, PRINCIPAL);
        cash.mint(borrower, REPURCHASE);   // so the borrower can settle later
        ats.mint(borrower, QTY);

        // The lender's ONE on-chain setup transaction. After this they only ever sign.
        cash.approve(address(settlement), type(uint256).max);
        vm.stopBroadcast();

        console.log("TENOR_SETTLEMENT=", address(settlement));
        console.log("SECURITY=", address(ats));
        console.log("CASH=", address(cash));
        console.log("LENDER=", lender);
        console.log("BORROWER=", borrower);
        console.log("");
        console.log("Put TENOR_SETTLEMENT, SECURITY and CASH in .env, then run openRepo().");
        console.log("NOTE: MockATS does not enforce operator authorisation. The real ATS bond");
        console.log("does, so stage 2 needs the borrower to authorise the settlement contract.");
    }

    function _quote() internal view returns (TenorSettlement.Quote memory q) {
        q = TenorSettlement.Quote({
            requestId:     _reqId(),
            lender:        vm.addr(_lenderPk()),
            borrower:      vm.addr(_borrowerPk()),
            security:      vm.envAddress("SECURITY"),
            partition:     PARTITION,
            collateralQty: QTY,
            cash:          vm.envAddress("CASH"),
            principal:     PRINCIPAL,
            repurchase:    REPURCHASE,
            maturity:      uint64(block.timestamp) + TERM,
            quoteExpiry:   uint64(block.timestamp) + QUOTE_TTL,
            haircutBps:    200
        });
    }

    /// Step 2. Lender signs off-chain, borrower executes. ONE transaction on chain.
    ///
    /// RUN THIS WITH --gas-limit 4000000. scheduleCall on 0x16b reverts with EMPTY returndata when
    /// starved of gas; the floor for the precompile alone is around 1.45M. openRepo does a cash
    /// transfer, two hold creations and a hold execution before it reaches scheduleCall, and
    /// EIP-150 forwards only 63/64 of what is left, so a limit that looks generous can still land
    /// under the floor. An empty revert here is gas, not logic. If --gas-limit is ignored, use
    /// --gas-estimate-multiplier 300 instead; hashio's eth_estimateGas does not model system
    /// contract calls well.
    function openRepo() external {
        TenorSettlement settlement = TenorSettlement(payable(vm.envAddress("TENOR_SETTLEMENT")));
        TenorSettlement.Quote memory q = _quote();

        // hashQuote is a view call, so this costs nothing and guarantees the digest matches the
        // chain's own encoding. Do this in your off-chain tooling too; never reimplement EIP-712.
        bytes32 digest = settlement.hashQuote(q);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_lenderPk(), digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        console.log("quote digest:");
        console.logBytes32(digest);

        // Only the borrower broadcasts. The lender never sends a transaction here.
        vm.broadcast(_borrowerPk());
        settlement.openRepo(q, sig);

        console.log("opened. maturity in", TERM, "seconds");
        console.log("Look up the scheduleAddress from status() on HashScan: that pending");
        console.log("schedule is the settlement the network now owns.");
    }

    /// Read-only. Run this between every step.
    function status() external view {
        TenorSettlement settlement = TenorSettlement(payable(vm.envAddress("TENOR_SETTLEMENT")));
        ( , , , , , , , uint256 repurchase, uint64 maturity, , ,
          address scheduleAddress, TenorSettlement.Status st) = settlement.repos(_reqId());

        console.log("status (0 None, 1 Open, 2 Closed, 3 Defaulted):", uint8(st));
        console.log("repurchase owed:", repurchase);
        console.log("maturity:", maturity);
        console.log("now     :", block.timestamp);
        console.log("schedule:", scheduleAddress);
        console.log("contract HBAR balance (tinybars):", address(settlement).balance);
    }

    /// Step 3a. Borrower buys the collateral back before maturity, at the full amount.
    function repayEarly() external {
        TenorSettlement settlement = TenorSettlement(payable(vm.envAddress("TENOR_SETTLEMENT")));
        MockERC20 cash = MockERC20(vm.envAddress("CASH"));

        vm.startBroadcast(_borrowerPk());
        cash.approve(address(settlement), REPURCHASE);
        settlement.repayEarly(_reqId());
        vm.stopBroadcast();

        console.log("repaid early. The scheduled call will still fire at maturity and do nothing.");
    }

    /// Step 3b. Fund the repurchase, then let the NETWORK settle at maturity.
    /// Run this, then wait. Do not call closeRepo yourself: that is the point.
    function fundRepurchase() external {
        TenorSettlement settlement = TenorSettlement(payable(vm.envAddress("TENOR_SETTLEMENT")));
        MockERC20 cash = MockERC20(vm.envAddress("CASH"));
        vm.broadcast(_borrowerPk());
        cash.approve(address(settlement), REPURCHASE);
        console.log("funded. Now wait for maturity and re-run status().");
        console.log("If you skip this step the repo will DEFAULT, which is also worth filming.");
    }

    /// Manual close, for debugging the logic without waiting. NOT the demo path.
    function closeRepo() external {
        TenorSettlement settlement = TenorSettlement(payable(vm.envAddress("TENOR_SETTLEMENT")));
        vm.broadcast(_borrowerPk());   // anyone may call it; there is no access control
        settlement.closeRepo(_reqId());
    }
}
