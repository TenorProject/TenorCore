// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {TenorSettlement} from "../src/TenorSettlement.sol";
import {MockATS} from "../src/mocks/MockATS.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {IHederaScheduleService, HSS} from "../src/interfaces/IHederaScheduleService.sol";

/*
 * TenorSettlement test suite
 *
 * This file is written to double as the TESTNET RUNBOOK. Every test says what it proves and what
 * the equivalent step is against the real deployment, so the same sequence can be walked by hand
 * on Hedera testnet.
 *
 * WHAT IS MOCKED HERE, AND WHAT REPLACES IT ON TESTNET
 *
 *   MockERC20   -> USDC. On Hedera, USDC is an HTS token reached through the ERC-20 facade.
 *                  Same interface, so the contract code is identical; only the address changes.
 *                  Remember: accounts must be ASSOCIATED with an HTS token before they can
 *                  receive it. There is no association step locally.
 *
 *   MockATS     -> the Asset Tokenization Studio diamond. Models the part that matters:
 *                  total = available + held, holds are created out of available balance, and
 *                  only the escrow can execute one.
 *
 *   vm.mockCall -> the HIP-1215 schedule service at 0x16b. It does not exist in forge's local
 *                  EVM, so scheduling is faked here and is the ONE THING these tests cannot
 *                  prove. It is proven separately on testnet by ScheduleProbe
 *                  (schedule 0.0.10393574, 134 ms drift).
 *
 *   `scheduler` -> stands in for the network invoking closeRepo. On testnet you can call
 *                  closeRepo manually from any account to exercise the logic without waiting for
 *                  maturity, then do the real scheduled run once as the final proof.
 *
 * WHAT THESE TESTS PROVE: branch logic and access control.
 * WHAT THEY DO NOT PROVE: that ATS accepts our hold calls, that HTS transfers behave, or that
 * the network fires the schedule. All three are testnet-only.
 */
contract TenorSettlementTest is Test {
    TenorSettlement settlement;
    MockATS ats;      // stands in for the ATS bond diamond
    MockERC20 usdc;   // stands in for USDC (HTS token on testnet)

    // The lender must be a key we control, because they SIGN quotes off-chain.
    // On testnet this is a real ECDSA account whose key you hold.
    uint256 lenderPk = 0xA11CE;
    address lender;

    // Borrower sends the transactions. No signing required from them.
    address borrower = address(0xB0B);

    // Stands in for the Hedera network invoking the scheduled call.
    address scheduler;

    // A third party with no role, used to prove access control.
    address stranger;

    bytes32 constant PARTITION = bytes32(uint256(1));
    uint256 constant QTY        = 100e18;    // 100 bond units
    uint256 constant PRINCIPAL  = 100_000e6; // 100,000 USDC (6 dp)
    uint256 constant REPURCHASE = 100_096e6; // ~5% annualised over 7 days
    bytes32 constant REQ        = keccak256("request-1");
    uint64  constant TERM       = 7 days;

    /*
     * SETUP == the one-time on-boarding both parties do on testnet.
     *
     *   1. deploy TenorSettlement WITH HBAR. It is the payer for every scheduled unwind
     *      (~0.12 HBAR each), and openRepo reverts if the balance is below MIN_HBAR_PER_REPO.
     *   2. borrower holds the bond; lender holds USDC.
     *   3. lender approves USDC to the settlement contract ONCE. This is the standing
     *      allowance that makes signature-only quoting possible. There is no EIP-2612 permit
     *      on HTS, so this transaction is unavoidable.
     *   4. borrower authorises the settlement contract as an ATS OPERATOR, so openRepo can
     *      create their hold for them. The mock does not enforce this; ATS does. Do not skip
     *      it on testnet or createHoldFromByPartition will revert.
     */
    function setUp() public {
        lender    = vm.addr(lenderPk);
        scheduler = makeAddr("scheduler"); // stands in for the network firing the schedule
        stranger  = makeAddr("stranger");  // no role in the trade, used for access-control tests

        settlement = new TenorSettlement{value: 1 ether}();
        ats  = new MockATS();
        usdc = new MockERC20();

        ats.mint(borrower, QTY);            // borrower owns the bond
        usdc.mint(lender, PRINCIPAL);       // lender has cash to lend
        usdc.mint(borrower, REPURCHASE);    // borrower can afford the repurchase later

        vm.prank(lender);
        usdc.approve(address(settlement), type(uint256).max);

        _mockScheduleService();
    }

    /// Fakes 0x16b: capacity always available, scheduleCall always returns SUCCESS (22).
    /// On testnet this is real and neither is guaranteed.
    function _mockScheduleService() internal {
        vm.mockCall(
            HSS,
            abi.encodeWithSelector(IHederaScheduleService.hasScheduleCapacity.selector),
            abi.encode(true)
        );
        vm.mockCall(
            HSS,
            abi.encodeWithSelector(IHederaScheduleService.scheduleCall.selector),
            abi.encode(int64(22), address(0x5CADD1E))
        );
    }

    // =====================================================================================
    // HELPERS
    // =====================================================================================

    /// The agreed terms. On testnet you build this JSON off-chain and the lender signs it.
    function _quote() internal view returns (TenorSettlement.Quote memory q) {
        q = TenorSettlement.Quote({
            requestId:     REQ,
            lender:        lender,
            borrower:      borrower,
            security:      address(ats),
            partition:     PARTITION,
            collateralQty: QTY,
            cash:          address(usdc),
            principal:     PRINCIPAL,
            repurchase:    REPURCHASE,
            maturity:      uint64(block.timestamp + TERM),
            quoteExpiry:   uint64(block.timestamp + 10 minutes),
            haircutBps:    200
        });
    }

    /// Signs the EIP-712 digest the contract itself computes, so the test and the chain can
    /// never disagree about encoding. Off-chain tooling should call hashQuote the same way.
    ///
    /// GOTCHA: this makes an EXTERNAL call to settlement.hashQuote(). vm.prank and
    /// vm.expectRevert apply to the NEXT external call, so calling _sign() after either of them
    /// consumes the cheat and the real call runs unpranked. Always hoist the signature into a
    /// local first. The same trap exists on testnet in reverse: hashQuote is a view call, so it
    /// costs nothing and can be read before you build the transaction.
    function _sign(TenorSettlement.Quote memory q, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, settlement.hashQuote(q));
        return abi.encodePacked(r, s, v);
    }

    function _openValid() internal returns (TenorSettlement.Quote memory q) {
        q = _quote();
        bytes memory sig = _sign(q, lenderPk); // hoisted: see the GOTCHA on _sign
        vm.prank(borrower);
        settlement.openRepo(q, sig);
    }

    /// Borrower approves the repurchase amount. On testnet this is a separate transaction the
    /// borrower must remember to send before maturity, or the repo defaults.
    function _borrowerFundsRepurchase() internal {
        vm.prank(borrower);
        usdc.approve(address(settlement), REPURCHASE);
    }

    // =====================================================================================
    // 1. openRepo — SUCCESS
    // =====================================================================================

    /*
     * Proves: a valid signed quote crosses BOTH legs in ONE transaction.
     *
     * Testnet: lender signs the quote off-chain and sends it to the borrower by any means.
     * Borrower sends one transaction. Afterwards check on HashScan that the USDC transfer and
     * the two hold operations all appear in the SAME transaction record.
     */
    function test_open_success_crossesBothLegsAtomically() public {
        _openValid();

        // cash moved lender -> borrower
        assertEq(usdc.balanceOf(lender), 0, "lender paid out the principal");
        assertEq(usdc.balanceOf(borrower), REPURCHASE + PRINCIPAL, "borrower received the principal");

        // collateral moved borrower -> lender, and is LOCKED in the return-leg hold
        assertEq(ats.available(borrower), 0, "borrower gave up the collateral");
        assertEq(ats.held(lender), QTY, "lender holds it, but cannot move it during the term");
        assertEq(ats.available(lender), 0, "collateral is held, not freely transferable");
    }

    /*
     * Proves: the repo is recorded as Open and the schedule address was captured, so the
     * pending settlement is inspectable.
     *
     * Testnet: read repos(REQ) and look the scheduleAddress up on HashScan. A pending schedule
     * with a future expiry IS the demo shot.
     */
    function test_open_success_recordsOpenRepoAndSchedule() public {
        _openValid();
        ( , , , , , , , , , , , address scheduleAddress, TenorSettlement.Status status) =
            settlement.repos(REQ);
        assertEq(uint8(status), uint8(TenorSettlement.Status.Open), "status is Open");
        assertTrue(scheduleAddress != address(0), "schedule address recorded");
    }

    // =====================================================================================
    // 2. openRepo — FAILURE
    // =====================================================================================

    /*
     * Proves: a quote signed by anyone other than q.lender is rejected.
     * This is the whole security of the RFQ design: terms cannot be forged.
     */
    function test_open_fail_signedByWrongKey() public {
        TenorSettlement.Quote memory q = _quote();
        bytes memory forged = _sign(q, 0xBADBAD); // not the lender
        vm.prank(borrower);
        vm.expectRevert();
        settlement.openRepo(q, forged);
        assertEq(usdc.balanceOf(lender), PRINCIPAL, "nothing moved");
    }

    /*
     * Proves: a borrower cannot take a legitimately signed quote and improve the terms.
     * The lender signed repurchase = REPURCHASE; lowering it invalidates the signature.
     * This is the attack the signature exists to stop.
     */
    function test_open_fail_tamperedTerms() public {
        TenorSettlement.Quote memory q = _quote();
        bytes memory sig = _sign(q, lenderPk);    // signature over the HONEST quote
        q.repurchase = PRINCIPAL;                 // borrower now tries to owe no interest
        vm.prank(borrower);
        vm.expectRevert();
        settlement.openRepo(q, sig);
    }

    /// Proves: only the borrower named in the quote can execute it.
    function test_open_fail_wrongCaller() public {
        TenorSettlement.Quote memory q = _quote();
        bytes memory sig = _sign(q, lenderPk); // hoisted: see the GOTCHA on _sign
        vm.prank(stranger);
        vm.expectRevert();
        settlement.openRepo(q, sig);
    }

    /*
     * Proves: a stale quote cannot be executed. Keep quoteExpiry short on testnet: the lender's
     * allowance is standing, so an old quote is a free option against a price they may no
     * longer want.
     */
    function test_open_fail_expiredQuote() public {
        TenorSettlement.Quote memory q = _quote();
        bytes memory sig = _sign(q, lenderPk);
        vm.warp(block.timestamp + 11 minutes);
        vm.prank(borrower);
        vm.expectRevert();
        settlement.openRepo(q, sig);
    }

    /// Proves: a lender can withdraw a quote before it expires, and it stops working immediately.
    function test_open_fail_cancelledQuote() public {
        TenorSettlement.Quote memory q = _quote();
        bytes memory sig = _sign(q, lenderPk);
        vm.prank(lender);
        settlement.cancelQuote(REQ);
        vm.prank(borrower);
        vm.expectRevert();
        settlement.openRepo(q, sig);
    }

    /// Proves: the same signed quote cannot be executed twice. requestId is the replay guard.
    function test_open_fail_replay() public {
        TenorSettlement.Quote memory q = _openValid();
        bytes memory sig = _sign(q, lenderPk); // hoisted: see the GOTCHA on _sign
        vm.prank(borrower);
        vm.expectRevert();
        settlement.openRepo(q, sig);
    }

    // =====================================================================================
    // 3. repayEarly
    // =====================================================================================

    /*
     * Proves: the borrower can buy the collateral back before maturity by paying the FULL
     * repurchase amount. No rebate, so the lender is strictly better off and their consent is
     * not required.
     *
     * Testnet: borrower approves REPURCHASE, then calls repayEarly. Collateral should return
     * immediately without waiting for the schedule.
     */
    function test_repayEarly_success() public {
        _openValid();
        _borrowerFundsRepurchase();

        vm.prank(borrower);
        settlement.repayEarly(REQ);

        assertEq(ats.available(borrower), QTY, "collateral returned early");
        assertEq(ats.held(lender), 0, "lender's hold released");
        assertEq(usdc.balanceOf(lender), REPURCHASE, "lender paid in full, no rebate");
    }

    /*
     * Proves: repayEarly REVERTS when the borrower has not funded it.
     *
     * This is deliberately the opposite of closeRepo. repayEarly is caller-initiated and atomic,
     * so a failure must be reported. Silently marking a borrower in default on a repo they were
     * actively trying to settle would be wrong.
     */
    function test_repayEarly_fail_notFunded() public {
        _openValid();                       // no approval given
        vm.prank(borrower);
        vm.expectRevert();
        settlement.repayEarly(REQ);

        assertEq(ats.held(lender), QTY, "collateral untouched");
    }

    /// Proves: only the borrower can repay. A lender cannot force an early unwind.
    function test_repayEarly_fail_wrongCaller() public {
        _openValid();
        _borrowerFundsRepurchase();
        vm.prank(lender);
        vm.expectRevert();
        settlement.repayEarly(REQ);
    }

    /// Proves: a settled repo cannot be repaid again.
    function test_repayEarly_fail_alreadyClosed() public {
        _openValid();
        _borrowerFundsRepurchase();
        vm.startPrank(borrower);
        settlement.repayEarly(REQ);
        vm.expectRevert();
        settlement.repayEarly(REQ);
        vm.stopPrank();
    }

    // =====================================================================================
    // 4. closeRepo — invoked by `scheduler`, standing in for the network
    // =====================================================================================

    /*
     * Proves: at maturity, a funded repo settles both legs back.
     *
     * `scheduler` is an ordinary account here on purpose: closeRepo has NO access control,
     * because a scheduled execution has no EOA sender. Anyone being able to call it is a
     * property of the design, not an oversight.
     *
     * Testnet: call closeRepo manually from any account first to prove the logic, THEN do one
     * real run where the network fires it at maturity with nobody online. The second one is the
     * demo.
     */
    function test_close_success_repurchaseAtMaturity() public {
        _openValid();
        _borrowerFundsRepurchase();
        vm.warp(block.timestamp + TERM);

        vm.prank(scheduler);
        settlement.closeRepo(REQ);

        assertEq(ats.available(borrower), QTY, "collateral returned to borrower");
        assertEq(usdc.balanceOf(lender), REPURCHASE, "lender received the repurchase amount");
    }

    /*
     * Proves: an unfunded repo DEFAULTS instead of reverting, and the lender keeps the
     * collateral they already hold.
     *
     * This is the branch that makes the settlement guarantee real. A scheduled call fires once
     * and is never retried, so a revert here would be a settlement that silently never happened.
     * Defaulting is a correct outcome, not a failure.
     */
    function test_close_default_borrowerNeverFunded() public {
        _openValid();                       // borrower never approves
        vm.warp(block.timestamp + TERM);

        vm.prank(scheduler);
        settlement.closeRepo(REQ);          // must NOT revert

        assertEq(ats.held(lender), QTY, "lender keeps the collateral");
        assertEq(ats.available(borrower), 0, "borrower gets nothing back");
        assertEq(usdc.balanceOf(lender), 0, "no cash moved");
    }

    /*
     * Proves: closeRepo does not revert even when the SECURITY leg fails after cash has moved.
     * Worst case in the whole contract: borrower has paid, lender still holds the bond. We
     * record it loudly rather than throwing away the settlement.
     */
    function test_close_neverReverts_whenSecurityLegFails() public {
        _openValid();
        _borrowerFundsRepurchase();
        ats.setFailExecute(true);
        vm.warp(block.timestamp + TERM);

        vm.prank(scheduler);
        settlement.closeRepo(REQ);          // must NOT revert
    }

    /// Proves: calling closeRepo twice is a quiet no-op, not a double settlement.
    function test_close_isIdempotent() public {
        _openValid();
        _borrowerFundsRepurchase();
        vm.warp(block.timestamp + TERM);

        vm.startPrank(scheduler);
        settlement.closeRepo(REQ);
        settlement.closeRepo(REQ);
        vm.stopPrank();

        assertEq(usdc.balanceOf(lender), REPURCHASE, "lender not paid twice");
        assertEq(ats.available(borrower), QTY, "collateral not returned twice");
    }

    /*
     * Proves: after early repayment the orphaned schedule is harmless.
     *
     * repayEarly leaves the scheduled call in place. At maturity the network fires it, it finds
     * a closed repo and returns. It costs the contract one execution fee (~0.12 HBAR) to do
     * nothing. This is why the status guard is the first line of closeRepo.
     */
    function test_close_isNoOpAfterEarlyRepayment() public {
        _openValid();
        _borrowerFundsRepurchase();
        vm.prank(borrower);
        settlement.repayEarly(REQ);

        vm.warp(block.timestamp + TERM);
        vm.prank(scheduler);
        settlement.closeRepo(REQ);

        assertEq(ats.available(borrower), QTY, "nothing moved twice");
        assertEq(usdc.balanceOf(lender), REPURCHASE, "lender not paid twice");
    }

    /// Proves: closeRepo on an id that was never opened is a no-op, not a revert.
    function test_close_unknownIdIsNoOp() public {
        vm.prank(scheduler);
        settlement.closeRepo(keccak256("never-existed"));
    }
}
