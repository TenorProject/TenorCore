// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TenorSettlement} from "../src/TenorSettlement.sol";
import {MockATS} from "../src/mocks/MockATS.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {IHederaScheduleService, HSS} from "../src/interfaces/IHederaScheduleService.sol";

/// @dev forge's local EVM has no Hedera system contracts, so `0x16b` is mocked with vm.mockCall.
///      These tests prove branch logic only. The mechanism itself is proven on testnet
///      (schedule 0.0.10393574, 134ms drift) and re-run via script/, never here.
contract TenorSettlementTest is Test {
    TenorSettlement settlement;
    MockATS ats;
    MockERC20 usdc;

    uint256 lenderPk = 0xA11CE;
    address lender;
    address borrower = address(0xB0B);

    bytes32 constant PARTITION = bytes32(uint256(1));
    uint256 constant QTY = 100e18;
    uint256 constant PRINCIPAL = 100_000e6;
    uint256 constant REPURCHASE = 100_096e6; // 5% annualised over 7 days
    bytes32 constant REQ = keccak256("request-1");

    function setUp() public {
        lender = vm.addr(lenderPk);
        settlement = new TenorSettlement{value: 1 ether}();
        ats = new MockATS();
        usdc = new MockERC20();

        ats.mint(borrower, QTY);
        usdc.mint(lender, PRINCIPAL);
        usdc.mint(borrower, REPURCHASE);

        vm.prank(lender);
        usdc.approve(address(settlement), type(uint256).max);

        _mockScheduleService(true);
    }

    function _mockScheduleService(bool hasCapacity) internal {
        vm.mockCall(
            HSS,
            abi.encodeWithSelector(IHederaScheduleService.hasScheduleCapacity.selector),
            abi.encode(hasCapacity)
        );
        vm.mockCall(
            HSS,
            abi.encodeWithSelector(IHederaScheduleService.scheduleCall.selector),
            abi.encode(int64(22), address(0x5CADD1E))
        );
    }

    function _quote() internal view returns (TenorSettlement.Quote memory q) {
        q = TenorSettlement.Quote({
            requestId: REQ,
            lender: lender,
            borrower: borrower,
            security: address(ats),
            partition: PARTITION,
            collateralQty: QTY,
            cash: address(usdc),
            principal: PRINCIPAL,
            repurchase: REPURCHASE,
            maturity: uint64(block.timestamp + 7 days),
            quoteExpiry: uint64(block.timestamp + 10 minutes),
            haircutBps: 200
        });
    }

    function _sign(TenorSettlement.Quote memory q, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, settlement.hashQuote(q));
        return abi.encodePacked(r, s, v);
    }

    function _open() internal returns (TenorSettlement.Quote memory q) {
        q = _quote();
        bytes memory sig = _sign(q, lenderPk);
        vm.prank(borrower);
        settlement.openRepo(q, sig);
    }

    // ---- open ---------------------------------------------------------------------------

    function test_open_crossesBothLegs() public {
        _open();
        assertEq(usdc.balanceOf(borrower), REPURCHASE + PRINCIPAL, "borrower got cash");
        assertEq(usdc.balanceOf(lender), 0, "lender paid cash");
        assertEq(ats.available(lender), 0, "lender collateral is held, not free");
        assertEq(ats.held(lender), QTY, "return-leg hold created over lender balance");
        assertEq(ats.available(borrower), 0, "borrower gave up collateral");
    }

    function test_open_rejectsBadSignature() public {
        TenorSettlement.Quote memory q = _quote();
        bytes memory sig = _sign(q, 0xBADBAD); // someone else signed
        vm.prank(borrower);
        vm.expectRevert();
        settlement.openRepo(q, sig);
    }

    function test_open_rejectsNonBorrowerCaller() public {
        TenorSettlement.Quote memory q = _quote();
        bytes memory sig = _sign(q, lenderPk);
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        settlement.openRepo(q, sig);
    }

    function test_open_rejectsExpiredQuote() public {
        TenorSettlement.Quote memory q = _quote();
        bytes memory sig = _sign(q, lenderPk);
        vm.warp(block.timestamp + 11 minutes);
        vm.prank(borrower);
        vm.expectRevert();
        settlement.openRepo(q, sig);
    }

    function test_open_rejectsCancelledQuote() public {
        TenorSettlement.Quote memory q = _quote();
        bytes memory sig = _sign(q, lenderPk);
        vm.prank(lender);
        settlement.cancelQuote(REQ);
        vm.prank(borrower);
        vm.expectRevert();
        settlement.openRepo(q, sig);
    }

    function test_open_rejectsReplay() public {
        TenorSettlement.Quote memory q = _open();
        bytes memory sig = _sign(q, lenderPk);
        vm.prank(borrower);
        vm.expectRevert();
        settlement.openRepo(q, sig);
    }

    // ---- close --------------------------------------------------------------------------

    function test_close_repurchase() public {
        _open();
        vm.prank(borrower);
        usdc.approve(address(settlement), REPURCHASE);
        vm.warp(block.timestamp + 7 days);

        settlement.closeRepo(REQ); // anyone can call: the network has no EOA sender

        assertEq(ats.available(borrower), QTY, "collateral returned");
        assertEq(usdc.balanceOf(lender), REPURCHASE, "lender repaid");
    }

    function test_close_defaultsWhenBorrowerHasNoAllowance() public {
        _open();
        vm.warp(block.timestamp + 7 days);

        settlement.closeRepo(REQ); // never reverts

        assertEq(ats.held(lender), QTY, "lender keeps the collateral");
        assertEq(ats.available(borrower), 0, "borrower gets nothing back");
    }

    function test_close_neverRevertsWhenCollateralLegFails() public {
        _open();
        vm.prank(borrower);
        usdc.approve(address(settlement), REPURCHASE);
        ats.setFailExecute(true);
        vm.warp(block.timestamp + 7 days);

        settlement.closeRepo(REQ); // must not revert even though the security leg fails
    }

    // ---- early repayment ----------------------------------------------------------------

    function test_repayEarly_returnsCollateralBeforeMaturity() public {
        _open();
        vm.startPrank(borrower);
        usdc.approve(address(settlement), REPURCHASE);
        settlement.repayEarly(REQ);
        vm.stopPrank();

        assertEq(ats.available(borrower), QTY, "collateral back before maturity");
        assertEq(usdc.balanceOf(lender), REPURCHASE, "lender paid in full, no rebate");
    }

    function test_repayEarly_onlyBorrower() public {
        _open();
        vm.prank(lender);
        vm.expectRevert();
        settlement.repayEarly(REQ);
    }

    function test_repayEarly_revertsWhenUnfunded() public {
        _open();
        vm.prank(borrower);
        vm.expectRevert(); // no allowance: caller-initiated, so it must revert, not default
        settlement.repayEarly(REQ);
    }

    function test_scheduledCloseIsNoOpAfterEarlyRepayment() public {
        _open();
        vm.startPrank(borrower);
        usdc.approve(address(settlement), REPURCHASE);
        settlement.repayEarly(REQ);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days);
        settlement.closeRepo(REQ); // the schedule still fires; must be a quiet no-op

        assertEq(ats.available(borrower), QTY, "nothing moved twice");
        assertEq(usdc.balanceOf(lender), REPURCHASE, "lender not paid twice");
    }

    function test_close_isIdempotent() public {
        _open();
        vm.prank(borrower);
        usdc.approve(address(settlement), REPURCHASE);
        vm.warp(block.timestamp + 7 days);

        settlement.closeRepo(REQ);
        settlement.closeRepo(REQ); // second call is a quiet no-op, not a revert
    }
}
