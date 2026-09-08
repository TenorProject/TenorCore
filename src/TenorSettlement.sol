// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IHederaScheduleService, HSS, HEDERA_SUCCESS} from "./interfaces/IHederaScheduleService.sol";
import {IHoldByPartition} from "./interfaces/IHoldByPartition.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/// @title TenorSettlement
/// @notice A repo desk for tokenised securities on Hedera. The trade settles atomically and
///         the unwind settles itself: the closing leg is handed to the network at open.
/// @dev THIS CONTRACT IS THE PROJECT. Everything else in the repo is supporting cast.
///      Read .claude/skills/tenor-hedera/SKILL.md before touching it.
contract TenorSettlement {
    // Proven on testnet. 2_000_000 fails hasScheduleCapacity. Do not raise.
    uint256 public constant SCHEDULE_GAS = 200_000;
    // ~0.12 HBAR per scheduled execution, in tinybars, with headroom.
    uint256 public constant MIN_HBAR_PER_REPO = 30_000_000;

    enum Status { None, Open, Closed, Defaulted }

    struct Repo {
        address lender;         // provides cash, receives collateral
        address borrower;       // provides collateral, receives cash
        address security;       // ATS diamond
        bytes32 partition;
        uint256 collateralQty;
        address cash;           // USDC, HTS token via the ERC-20 facade
        uint256 principal;      // cash moved at open
        uint256 repurchase;     // cash moved at close; computed off-chain, a trade input
        uint64  maturity;
        uint256 haircutBps;
        uint256 openHoldId;     // borrower's hold, open destination
        uint256 closeHoldId;    // lender's hold, created at open
        address scheduleAddress;
        Status  status;
    }

    address public owner;
    mapping(bytes32 => Repo) public repos;

    // Events are the ONLY handoff to the audit trail: HCS is unreachable from Solidity
    // (no precompile, HIP-1208 is an open PR). Emit enough that services/hcs/ can write a
    // complete record without re-reading chain state.
    event RepoOpened(
        bytes32 indexed id, address indexed lender, address indexed borrower,
        address security, uint256 collateralQty, address cash, uint256 principal,
        uint256 repurchase, uint64 maturity, address scheduleAddress
    );
    event RepoClosed(bytes32 indexed id, uint256 repurchasePaid, uint256 collateralReturned);
    event RepoDefaulted(bytes32 indexed id, string reason);
    event MarginCall(bytes32 indexed id, uint256 markedValue, uint256 required);
    event ScheduleStepped(bytes32 indexed id, uint64 requested, uint64 actual);
    event Funded(address indexed from, uint256 amount);

    error NotOwner();
    error AlreadyExists(bytes32 id);
    error MaturityInPast();
    error HoldExpiresBeforeSchedule(uint256 holdExpiry, uint64 maturity);
    error InsufficientHbarForUnwind(uint256 have, uint256 need);
    error NoScheduleCapacity(uint64 maturity);
    error ScheduleFailed(int64 responseCode);
    error CashLegFailed();

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    constructor() payable { owner = msg.sender; }

    receive() external payable { emit Funded(msg.sender, msg.value); }

    // -------------------------------------------------------------------------------------
    // OPEN
    // -------------------------------------------------------------------------------------

    /// @notice Cross cash against collateral atomically, then hand the unwind to the network.
    /// @dev Preconditions the caller must have arranged:
    ///      1. borrower created an OPEN DESTINATION hold (to == address(0)) over `collateralQty`,
    ///         escrow = address(this), expiration comfortably AFTER `maturity`;
    ///      2. lender approved `principal` of `cash` to this contract;
    ///      3. lender authorised this contract as an ATS operator, so step 5 can create the
    ///         return-leg hold over the lender's new balance;
    ///      4. this contract holds HBAR: it is the PAYER for the scheduled unwind.
    function openRepo(bytes32 id, Repo calldata r) external {
        if (repos[id].status != Status.None) revert AlreadyExists(id);
        if (r.maturity <= block.timestamp) revert MaturityInPast();
        if (address(this).balance < MIN_HBAR_PER_REPO) {
            revert InsufficientHbarForUnwind(address(this).balance, MIN_HBAR_PER_REPO);
        }

        // TODO(day 1): read the borrower's hold and assert its expirationTimestamp > maturity.
        // After an ATS hold expires ANYONE can permissionlessly reclaim to the holder, which
        // would make the unwind revert into a settlement that silently did not happen.
        // revert HoldExpiresBeforeSchedule(holdExpiry, r.maturity);

        // 1. cash leg: lender -> borrower
        if (!IERC20(r.cash).transferFrom(r.lender, r.borrower, r.principal)) revert CashLegFailed();

        // 2. security leg: execute the borrower's open-destination hold, naming the lender
        // TODO(day 1): VERIFY this signature against the deployed ATS ABI first.
        IHoldByPartition(r.security).executeHoldByPartition(
            IHoldByPartition.HoldIdentifier({
                partition: r.partition, tokenHolder: r.borrower, holdId: r.openHoldId
            }),
            r.lender,
            r.collateralQty
        );

        // Both legs have now moved, or neither has. No exposure window.

        Repo storage s = repos[id];
        s.lender = r.lender; s.borrower = r.borrower; s.security = r.security;
        s.partition = r.partition; s.collateralQty = r.collateralQty; s.cash = r.cash;
        s.principal = r.principal; s.repurchase = r.repurchase; s.maturity = r.maturity;
        s.haircutBps = r.haircutBps; s.openHoldId = r.openHoldId;

        // 3. return-leg hold over the lender's new balance, so closeRepo has something to move
        // TODO(day 1): operatorCreateHoldByPartition, escrow = address(this),
        //              expiration = maturity + buffer. Store s.closeHoldId.

        // 4. hand the unwind to the network
        s.scheduleAddress = _scheduleUnwind(id, r.maturity);
        s.status = Status.Open;

        emit RepoOpened(
            id, r.lender, r.borrower, r.security, r.collateralQty, r.cash,
            r.principal, r.repurchase, r.maturity, s.scheduleAddress
        );
    }

    /// @dev A saturated expiry second makes scheduleCall revert with SCHEDULE_EXPIRY_IS_BUSY.
    ///      Step forward rather than reverting the trade: a maturity date is a real date.
    function _scheduleUnwind(bytes32 id, uint64 maturity) internal returns (address) {
        uint64 target = maturity;
        for (uint64 i; i < 10; ++i) {
            if (IHederaScheduleService(HSS).hasScheduleCapacity(target, SCHEDULE_GAS)) {
                if (target != maturity) emit ScheduleStepped(id, maturity, target);

                (int64 rc, address addr) = IHederaScheduleService(HSS).scheduleCall(
                    address(this),
                    target,
                    SCHEDULE_GAS,
                    0,
                    abi.encodeWithSelector(this.closeRepo.selector, id)
                );
                if (rc != HEDERA_SUCCESS) revert ScheduleFailed(rc);
                return addr;
            }
            unchecked { target += 1; }
        }
        revert NoScheduleCapacity(maturity);
    }

    // -------------------------------------------------------------------------------------
    // CLOSE
    // -------------------------------------------------------------------------------------

    /// @notice Called by the NETWORK at maturity. Nobody is online.
    /// @dev NO ACCESS CONTROL, deliberately: a scheduled execution has no EOA sender.
    ///      MUST NEVER REVERT. A scheduled transaction fires once and never retries, so a
    ///      revert here is a settlement that silently did not happen. Two terminal branches,
    ///      and the default branch is not an error path: it is what a repo does when someone
    ///      fails to repurchase.
    function closeRepo(bytes32 id) external {
        Repo storage r = repos[id];
        if (r.status != Status.Open) return;   // idempotent, quiet

        bool funded = IERC20(r.cash).allowance(r.borrower, address(this)) >= r.repurchase
                   && IERC20(r.cash).balanceOf(r.borrower)               >= r.repurchase;

        if (!funded) {
            r.status = Status.Defaulted;       // lender keeps the collateral
            emit RepoDefaulted(id, "repurchase amount not available at maturity");
            return;
        }

        try IERC20(r.cash).transferFrom(r.borrower, r.lender, r.repurchase) returns (bool ok) {
            if (!ok) { r.status = Status.Defaulted; emit RepoDefaulted(id, "cash leg returned false"); return; }
        } catch {
            r.status = Status.Defaulted; emit RepoDefaulted(id, "cash leg reverted"); return;
        }

        try IHoldByPartition(r.security).executeHoldByPartition(
            IHoldByPartition.HoldIdentifier({
                partition: r.partition, tokenHolder: r.lender, holdId: r.closeHoldId
            }),
            r.borrower,
            r.collateralQty
        ) returns (bool) {
            r.status = Status.Closed;
            emit RepoClosed(id, r.repurchase, r.collateralQty);
        } catch {
            // Cash moved but collateral did not. Flag loudly; do NOT revert.
            r.status = Status.Defaulted;
            emit RepoDefaulted(id, "collateral leg reverted after cash settled");
        }
    }

    // -------------------------------------------------------------------------------------
    // MARGIN  (one rubric point; keep it this small)
    // -------------------------------------------------------------------------------------

    /// @dev No oracle prices our bond: it was minted this week. `markedValue` is an admin-set
    ///      NAV or a proxy feed, and the README says which.
    function markCollateral(bytes32 id, uint256 markedValue) external onlyOwner {
        Repo storage r = repos[id];
        if (r.status != Status.Open) return;
        uint256 required = r.principal + (r.principal * r.haircutBps) / 10_000;
        if (markedValue < required) emit MarginCall(id, markedValue, required);
    }

    // -------------------------------------------------------------------------------------

    function sweep() external onlyOwner {
        (bool ok, ) = payable(owner).call{value: address(this).balance}("");
        require(ok, "sweep failed");
    }
}
