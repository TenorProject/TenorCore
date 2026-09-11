// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TenorSettlement} from "../src/TenorSettlement.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {IHederaScheduleService, HSS} from "../src/interfaces/IHederaScheduleService.sol";

/*
 * TenorSettlement test suite - ESCROW MODEL
 *
 * Written to double as the TESTNET RUNBOOK. Every test says what it proves and what the
 * equivalent step is against the real deployment.
 *
 * CUSTODY MODEL UNDER TEST
 *   open      cash     lender   -> borrower
 *             security borrower -> THIS CONTRACT (escrow)
 *   repayEarly / closeRepo funded
 *             cash     borrower -> lender
 *             security escrow   -> borrower
 *   closeRepo unfunded
 *             security escrow   -> lender      <-- default now MOVES tokens
 *
 * WHAT IS MOCKED, AND WHAT REPLACES IT ON TESTNET
 *   MockERC20 (cash)     -> USDC, an HTS token through the ERC-20 facade at 0x167. Accounts
 *                           must be ASSOCIATED with an HTS token before receiving it. No local
 *                           equivalent, so stage 2 hides nothing here but association.
 *   MockERC20 (security) -> the ATS diamond's ERC-20 facet. VERIFIED on testnet: approve and
 *                           allowance behave exactly as ERC-20. The diamond also enforces
 *                           compliance on transfer, which the mock does not: THIS CONTRACT must
 *                           itself pass isVerified to receive collateral into escrow.
 *   vm.mockCall          -> HIP-1215 at 0x16b, which does not exist in forge's EVM. Scheduling
 *                           is the ONE THING these tests cannot prove. Proven on testnet:
 *                           schedule 0.0.10474468 executed 25.8 ms after its target second.
 *   `scheduler`          -> the network invoking closeRepo. closeRepo has no access control
 *                           because a scheduled execution has no EOA sender.
 *
 * WHAT THESE PROVE: branch logic, access control, and that no path can strand value silently.
 * WHAT THEY DO NOT PROVE: ATS compliance behaviour, HTS association, schedule firing.
 */
contract TenorSettlementTest is Test {
    TenorSettlement settlement;
    MockERC20 bond;   // the security, escrowed by the contract for the term
    MockERC20 usdc;   // the cash leg

    uint256 lenderPk = 0xA11CE;
    address lender;
    address borrower = address(0xB0B);
    address scheduler;
    address stranger;

    bytes32 constant PARTITION  = bytes32(uint256(1));
    uint256 constant QTY        = 100e18;
    uint256 constant PRINCIPAL  = 100_000e6;
    uint256 constant REPURCHASE = 100_096e6;
    bytes32 constant REQ        = keccak256("request-1");
    uint64  constant TERM       = 7 days;

    /*
     * SETUP == the one-time onboarding each party does on testnet. ONE approval each.
     *   1. deploy TenorSettlement WITH HBAR: it pays for every scheduled unwind, and openRepo
     *      reverts below MIN_HBAR_PER_REPO.
     *   2. borrower holds the bond and approves it to the settlement contract.
     *   3. lender holds USDC and approves it to the settlement contract.
     * The lender needs NO approval on the bond in this model. That is the whole point of it.
     */
    function setUp() public {
        lender    = vm.addr(lenderPk);
        scheduler = makeAddr("scheduler");
        stranger  = makeAddr("stranger");

        settlement = new TenorSettlement{value: 1 ether}();
        bond = new MockERC20();
        usdc = new MockERC20();

        bond.mint(borrower, QTY);
        usdc.mint(lender, PRINCIPAL);
        usdc.mint(borrower, REPURCHASE);

        vm.prank(lender);
        usdc.approve(address(settlement), type(uint256).max);

        vm.prank(borrower);
        bond.approve(address(settlement), type(uint256).max);

        _mockScheduleService();
    }

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

    function _quote() internal view returns (TenorSettlement.Quote memory q) {
        q = TenorSettlement.Quote({
            requestId:     REQ,
            lender:        lender,
            borrower:      borrower,
            security:      address(bond),
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

    /// GOTCHA: this makes an EXTERNAL call to settlement.hashQuote(). vm.prank and
    /// vm.expectRevert apply to the NEXT external call, so calling _sign() after either of them
    /// consumes the cheat and the real call runs unpranked. ALWAYS hoist the signature into a
    /// local first. This cost an hour once already.
    function _sign(TenorSettlement.Quote memory q, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, settlement.hashQuote(q));
        return abi.encodePacked(r, s, v);
    }

    function _openValid() internal returns (TenorSettlement.Quote memory q) {
        q = _quote();
        bytes memory sig = _sign(q, lenderPk); // hoisted: see GOTCHA on _sign
        vm.prank(borrower);
        settlement.openRepo(q, sig);
    }

    function _borrowerFundsRepurchase() internal {
        vm.prank(borrower);
        usdc.approve(address(settlement), REPURCHASE);
    }

    function _status(bytes32 id) internal view returns (TenorSettlement.Status st) {
        ( , , , , , , , , , , , , st) = settlement.repos(id);
    }

    function _escrowed(bytes32 id) internal view returns (uint256 q) {
        ( , , , , , , , , , , q, , ) = settlement.repos(id);
    }

    // =====================================================================================
    // 1. openRepo - SUCCESS
    // =====================================================================================

    /*
     * Proves: BOTH legs cross in ONE transaction, and the collateral lands in ESCROW rather
     * than with the lender.
     *
     * Testnet: check on HashScan that the USDC transfer and the bond transfer appear in the
     * SAME transaction record, and that the bond balance of TenorSettlement went up.
     */
    function test_open_success_crossesBothLegsAtomically() public {
        _openValid();

        assertEq(usdc.balanceOf(borrower), REPURCHASE + PRINCIPAL, "borrower did not receive cash");
        assertEq(usdc.balanceOf(lender), 0, "lender cash did not leave");

        assertEq(bond.balanceOf(borrower), 0, "collateral did not leave the borrower");
        assertEq(bond.balanceOf(address(settlement)), QTY, "collateral is not in escrow");
        assertEq(bond.balanceOf(lender), 0, "lender must NOT hold the security during the term");

        assertEq(uint8(_status(REQ)), uint8(TenorSettlement.Status.Open), "status");
        assertEq(_escrowed(REQ), QTY, "escrowedQty not recorded");
    }

    function test_open_success_recordsScheduleAddress() public {
        _openValid();
        ( , , , , , , , , , , , address sched, ) = settlement.repos(REQ);
        assertEq(sched, address(0x5CADD1E), "schedule address not recorded");
    }

    // =====================================================================================
    // 2. openRepo - FAILURES. Reverting here is safe: nothing has moved.
    // =====================================================================================

    function test_open_fail_wrongCaller() public {
        TenorSettlement.Quote memory q = _quote();
        bytes memory sig = _sign(q, lenderPk); // hoisted BEFORE the cheatcodes
        vm.expectRevert();
        vm.prank(stranger);
        settlement.openRepo(q, sig);
    }

    function test_open_fail_replaySameRequestId() public {
        TenorSettlement.Quote memory q = _openValid();
        bytes memory sig = _sign(q, lenderPk);
        vm.expectRevert();
        vm.prank(borrower);
        settlement.openRepo(q, sig);
    }

    function test_open_fail_quoteExpired() public {
        TenorSettlement.Quote memory q = _quote();
        bytes memory sig = _sign(q, lenderPk);
        vm.warp(block.timestamp + 11 minutes);
        vm.expectRevert();
        vm.prank(borrower);
        settlement.openRepo(q, sig);
    }

    function test_open_fail_quoteCancelledByLender() public {
        TenorSettlement.Quote memory q = _quote();
        bytes memory sig = _sign(q, lenderPk);
        vm.prank(lender);
        settlement.cancelQuote(REQ);
        vm.expectRevert();
        vm.prank(borrower);
        settlement.openRepo(q, sig);
    }

    /*
     * Proves the security beat: a borrower cannot improve the terms after the lender signed.
     * Testnet: edit the repurchase amount downward in your tooling and watch it revert.
     */
    function test_open_fail_tamperedQuote() public {
        TenorSettlement.Quote memory q = _quote();
        bytes memory sig = _sign(q, lenderPk);
        q.repurchase = PRINCIPAL; // borrower tries to pay back less
        vm.expectRevert();
        vm.prank(borrower);
        settlement.openRepo(q, sig);
    }

    function test_open_fail_signedByWrongKey() public {
        TenorSettlement.Quote memory q = _quote();
        bytes memory sig = _sign(q, 0xBADBAD);
        vm.expectRevert();
        vm.prank(borrower);
        settlement.openRepo(q, sig);
    }

    function test_open_fail_maturityInPast() public {
        TenorSettlement.Quote memory q = _quote();
        q.maturity = uint64(block.timestamp - 1);
        bytes memory sig = _sign(q, lenderPk);
        vm.expectRevert();
        vm.prank(borrower);
        settlement.openRepo(q, sig);
    }

    /// The contract pays for its own scheduled unwinds. Below the floor it must refuse to open
    /// a trade it cannot afford to settle. Testnet: drain with sweep() and retry.
    function test_open_fail_insufficientHbar() public {
        TenorSettlement poor = new TenorSettlement();
        TenorSettlement.Quote memory q = _quote();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(lenderPk, poor.hashQuote(q));
        bytes memory sig = abi.encodePacked(r, s, v);
        vm.expectRevert();
        vm.prank(borrower);
        poor.openRepo(q, sig);
    }

    /// The borrower's single approval is what makes the escrow pull work. Without it, nothing.
    function test_open_fail_borrowerHasNotApprovedSecurity() public {
        vm.prank(borrower);
        bond.approve(address(settlement), 0);

        TenorSettlement.Quote memory q = _quote();
        bytes memory sig = _sign(q, lenderPk);
        vm.expectRevert();
        vm.prank(borrower);
        settlement.openRepo(q, sig);
    }

    function test_open_fail_lenderHasNoCash() public {
        vm.prank(lender);
        usdc.approve(address(settlement), 0);

        TenorSettlement.Quote memory q = _quote();
        bytes memory sig = _sign(q, lenderPk);
        vm.expectRevert();
        vm.prank(borrower);
        settlement.openRepo(q, sig);
    }

    // =====================================================================================
    // 3. repayEarly - caller-initiated, SHOULD revert on failure
    // =====================================================================================

    function test_repayEarly_success_returnsCollateralAndPaysLender() public {
        _openValid();
        _borrowerFundsRepurchase();

        vm.prank(borrower);
        settlement.repayEarly(REQ);

        assertEq(bond.balanceOf(borrower), QTY, "collateral not returned");
        assertEq(bond.balanceOf(address(settlement)), 0, "escrow not emptied");
        assertEq(usdc.balanceOf(lender), REPURCHASE, "lender not paid in full");
        assertEq(uint8(_status(REQ)), uint8(TenorSettlement.Status.Closed), "status");
        assertEq(_escrowed(REQ), 0, "escrowedQty not cleared");
    }

    function test_repayEarly_fail_notBorrower() public {
        _openValid();
        _borrowerFundsRepurchase();
        vm.expectRevert();
        vm.prank(stranger);
        settlement.repayEarly(REQ);
    }

    function test_repayEarly_fail_repoNotOpen() public {
        vm.expectRevert();
        vm.prank(borrower);
        settlement.repayEarly(keccak256("never-opened"));
    }

    /// Opposite policy to closeRepo ON PURPOSE: a human is here to retry, so tell them.
    function test_repayEarly_fail_revertsWhenUnfunded() public {
        _openValid(); // no approval for the repurchase
        vm.expectRevert();
        vm.prank(borrower);
        settlement.repayEarly(REQ);
    }

    // =====================================================================================
    // 4. closeRepo - invoked by the NETWORK. Must never revert.
    // =====================================================================================

    function test_close_funded_returnsCollateralToBorrower() public {
        _openValid();
        _borrowerFundsRepurchase();
        vm.warp(block.timestamp + TERM);

        vm.prank(scheduler);
        settlement.closeRepo(REQ);

        assertEq(uint8(_status(REQ)), uint8(TenorSettlement.Status.Closed), "status");
        assertEq(bond.balanceOf(borrower), QTY, "collateral not returned to borrower");
        assertEq(bond.balanceOf(address(settlement)), 0, "escrow not emptied");
        assertEq(usdc.balanceOf(lender), REPURCHASE, "lender not paid");
        assertEq(_escrowed(REQ), 0, "escrowedQty not cleared");
    }

    /*
     * THE BRANCH THAT PROVES THE SETTLEMENT GUARANTEE.
     * Unfunded at maturity: the lender takes the collateral. Unlike the old hold-based design
     * this MOVES tokens, so the transfer has to work inside a function that must not revert.
     *
     * Testnet: skip the borrower's approval, wait for the schedule, expect status 3 and a
     * SUCCESS result on the scheduled transaction.
     */
    function test_close_unfunded_transfersCollateralToLender() public {
        _openValid();
        vm.warp(block.timestamp + TERM);

        vm.prank(scheduler);
        settlement.closeRepo(REQ); // must not revert

        assertEq(uint8(_status(REQ)), uint8(TenorSettlement.Status.Defaulted), "status");
        assertEq(bond.balanceOf(lender), QTY, "lender did not receive the collateral");
        assertEq(bond.balanceOf(address(settlement)), 0, "escrow not emptied");
        assertEq(usdc.balanceOf(lender), 0, "no cash should have moved");
        assertEq(_escrowed(REQ), 0, "escrowedQty not cleared");
    }

    /// Balance present but allowance pulled: still a default, still no revert.
    function test_close_allowanceRevokedBeforeMaturity_defaults() public {
        _openValid();
        _borrowerFundsRepurchase();
        vm.prank(borrower);
        usdc.approve(address(settlement), 0);
        vm.warp(block.timestamp + TERM);

        vm.prank(scheduler);
        settlement.closeRepo(REQ);

        assertEq(uint8(_status(REQ)), uint8(TenorSettlement.Status.Defaulted), "status");
        assertEq(bond.balanceOf(lender), QTY, "lender did not get collateral");
    }

    /// Looked funded, settlement still failed. Must fall through to default, not revert.
    function test_close_settlementLegFails_fallsThroughToDefault() public {
        _openValid();
        _borrowerFundsRepurchase();
        vm.warp(block.timestamp + TERM);

        bond.setFailTransfer(true);
        vm.prank(scheduler);
        settlement.closeRepo(REQ); // must not revert

        assertEq(uint8(_status(REQ)), uint8(TenorSettlement.Status.Defaulted), "status");
        // Collateral could not move either way, so it is stranded and flagged for recovery.
        assertEq(_escrowed(REQ), QTY, "escrowedQty should still flag stranded collateral");
        assertEq(bond.balanceOf(address(settlement)), QTY, "collateral should still be here");
    }

    /*
     * THE WORST CASE, AND IT MUST NOT REVERT.
     * The security refuses to move to the lender at the exact moment the schedule fires, e.g.
     * because the lender failed a compliance check. The repo still settles as Defaulted, and
     * the collateral is recoverable afterwards rather than stuck forever.
     */
    function test_close_collateralTransferReverts_stillDefaultsWithoutReverting() public {
        _openValid();
        vm.warp(block.timestamp + TERM);

        bond.setFailTransfer(true);
        vm.prank(scheduler);
        settlement.closeRepo(REQ); // must not revert

        assertEq(uint8(_status(REQ)), uint8(TenorSettlement.Status.Defaulted), "status");
        assertEq(_escrowed(REQ), QTY, "stranded collateral must stay flagged");
    }

    function test_close_collateralTransferReturnsFalse_stillDefaults() public {
        _openValid();
        vm.warp(block.timestamp + TERM);

        bond.setTransferReturnsFalse(true);
        vm.prank(scheduler);
        settlement.closeRepo(REQ);

        assertEq(uint8(_status(REQ)), uint8(TenorSettlement.Status.Defaulted), "status");
        assertEq(_escrowed(REQ), QTY, "a silent false must not clear the flag");
    }

    /// A scheduled transaction fires ONCE and never retries, but a manual double-call must be
    /// harmless. Also what makes repayEarly safe.
    function test_close_isIdempotent() public {
        _openValid();
        vm.warp(block.timestamp + TERM);

        vm.prank(scheduler);
        settlement.closeRepo(REQ);
        uint256 lenderBond = bond.balanceOf(lender);

        vm.prank(stranger);
        settlement.closeRepo(REQ); // no-op, no revert

        assertEq(bond.balanceOf(lender), lenderBond, "second call moved tokens");
        assertEq(uint8(_status(REQ)), uint8(TenorSettlement.Status.Defaulted), "status changed");
    }

    /// After repayEarly the orphaned schedule still fires. It must do nothing at all.
    function test_close_afterRepayEarly_isHarmlessNoOp() public {
        _openValid();
        _borrowerFundsRepurchase();
        vm.prank(borrower);
        settlement.repayEarly(REQ);

        uint256 borrowerBond = bond.balanceOf(borrower);
        vm.warp(block.timestamp + TERM);
        vm.prank(scheduler);
        settlement.closeRepo(REQ);

        assertEq(bond.balanceOf(borrower), borrowerBond, "orphaned schedule moved tokens");
        assertEq(uint8(_status(REQ)), uint8(TenorSettlement.Status.Closed), "status changed");
    }

    /// No access control, deliberately: a scheduled execution has no EOA sender. Safe because
    /// terms are fixed at open and every branch is terminal.
    function test_close_hasNoAccessControl() public {
        _openValid();
        _borrowerFundsRepurchase();
        vm.warp(block.timestamp + TERM);

        vm.prank(stranger);
        settlement.closeRepo(REQ);

        assertEq(uint8(_status(REQ)), uint8(TenorSettlement.Status.Closed), "stranger call failed");
    }

    function test_close_unknownRepo_isNoOp() public {
        vm.prank(scheduler);
        settlement.closeRepo(keccak256("never-opened")); // must not revert
    }

    // =====================================================================================
    // 5. claimCollateral - recovery for stranded escrow
    // =====================================================================================

    function test_claim_recoversStrandedCollateralToLender() public {
        _openValid();
        vm.warp(block.timestamp + TERM);

        bond.setFailTransfer(true);
        vm.prank(scheduler);
        settlement.closeRepo(REQ);
        assertEq(_escrowed(REQ), QTY, "precondition: collateral stranded");

        bond.setFailTransfer(false);   // whatever blocked it is resolved
        vm.prank(stranger);            // permissionless: destination is fixed by status
        settlement.claimCollateral(REQ);

        assertEq(bond.balanceOf(lender), QTY, "lender did not receive stranded collateral");
        assertEq(_escrowed(REQ), 0, "flag not cleared");
    }

    function test_claim_fail_whenRepoStillOpen() public {
        _openValid();
        vm.expectRevert();
        settlement.claimCollateral(REQ);
    }

    function test_claim_fail_whenNothingEscrowed() public {
        _openValid();
        vm.warp(block.timestamp + TERM);
        vm.prank(scheduler);
        settlement.closeRepo(REQ); // succeeds, escrow emptied

        vm.expectRevert();
        settlement.claimCollateral(REQ);
    }
}
