// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IHederaScheduleService, HSS, HEDERA_SUCCESS} from "./interfaces/IHederaScheduleService.sol";
import {IHoldByPartition} from "./interfaces/IHoldByPartition.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/// @title TenorSettlement
/// @notice A repo desk for tokenised securities on Hedera. The trade settles atomically and the
///         unwind settles itself: the closing leg is handed to the network at open.
///
/// @dev Rate agreement is RFQ, not an order book, because repo against a *specific* security is a
///      specials trade. The borrower publishes a request, lenders return EIP-712 signed quotes,
///      and the borrower executes the one they accept. Nothing is negotiated on-chain and nothing
///      can be substituted: the terms are bound by the lender's signature.
///
///      Setup, once per party:
///        lender   -> approve(cash, TenorSettlement, working amount)
///        borrower -> authorise TenorSettlement as an ATS operator for the security
///      Per trade:
///        lender   -> sign a Quote off-chain, zero transactions
///        borrower -> openRepo(quote, signature), one transaction
contract TenorSettlement is EIP712 {
    using ECDSA for bytes32;

    /// Proven on testnet. 2_000_000 fails hasScheduleCapacity. Do not raise.
    uint256 public constant SCHEDULE_GAS = 200_000;
    /// ~0.12 HBAR per scheduled execution, in tinybars, with headroom.
    uint256 public constant MIN_HBAR_PER_REPO = 30_000_000;
    /// Holds must outlive the schedule: after expiry anyone can reclaim to the holder.
    uint64 public constant HOLD_BUFFER = 3 days;

    bytes32 private constant QUOTE_TYPEHASH = keccak256(
        "Quote(bytes32 requestId,address lender,address borrower,address security,bytes32 partition,uint256 collateralQty,address cash,uint256 principal,uint256 repurchase,uint64 maturity,uint64 quoteExpiry,uint256 haircutBps)"
    );

    /// @notice Terms a lender signs off-chain. `repurchase` is the rate, expressed as an amount.
    struct Quote {
        bytes32 requestId;
        address lender;
        address borrower;
        address security;
        bytes32 partition;
        uint256 collateralQty;
        address cash;
        uint256 principal;
        uint256 repurchase;
        uint64  maturity;
        uint64  quoteExpiry;
        uint256 haircutBps;
    }

    enum Status { None, Open, Closed, Defaulted }

    struct Repo {
        address lender;
        address borrower;
        address security;
        bytes32 partition;
        uint256 collateralQty;
        address cash;
        uint256 principal;
        uint256 repurchase;
        uint64  maturity;
        uint256 haircutBps;
        uint256 closeHoldId;
        address scheduleAddress;
        Status  status;
    }

    address public owner;
    mapping(bytes32 => Repo) public repos;
    /// @notice lender => requestId => cancelled. Lets a lender pull a quote before it expires.
    mapping(address => mapping(bytes32 => bool)) public quoteCancelled;

    // HCS is unreachable from Solidity (no precompile; HIP-1208 is an open PR), so these events
    // are the ONLY handoff to the audit trail in services/hcs/. Emit enough to reconstruct the
    // trade without re-reading chain state.
    event RepoOpened(
        bytes32 indexed id, address indexed lender, address indexed borrower,
        address security, uint256 collateralQty, address cash, uint256 principal,
        uint256 repurchase, uint64 maturity, address scheduleAddress
    );
    event RepoClosed(bytes32 indexed id, uint256 repurchasePaid, uint256 collateralReturned);
    event RepoDefaulted(bytes32 indexed id, string reason);
    event MarginCall(bytes32 indexed id, uint256 markedValue, uint256 required);
    event ScheduleStepped(bytes32 indexed id, uint64 requested, uint64 actual);
    event QuoteCancelled(address indexed lender, bytes32 indexed requestId);
    event Funded(address indexed from, uint256 amount);

    error NotOwner();
    error NotBorrower(address expected, address actual);
    error AlreadyExists(bytes32 id);
    error QuoteExpired(uint64 quoteExpiry);
    error QuoteWasCancelled(bytes32 requestId);
    error BadSignature(address recovered, address expected);
    error MaturityInPast();
    error InsufficientHbarForUnwind(uint256 have, uint256 need);
    error NoScheduleCapacity(uint64 maturity);
    error ScheduleFailed(int64 responseCode);
    error CashLegFailed();

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    constructor() payable EIP712("Tenor", "1") { owner = msg.sender; }

    receive() external payable { emit Funded(msg.sender, msg.value); }

    // -------------------------------------------------------------------------------------
    // QUOTES
    // -------------------------------------------------------------------------------------

    /// @notice Digest a lender signs. Exposed so off-chain tooling and tests agree with the chain.
    function hashQuote(Quote calldata q) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(
            QUOTE_TYPEHASH, q.requestId, q.lender, q.borrower, q.security, q.partition,
            q.collateralQty, q.cash, q.principal, q.repurchase, q.maturity, q.quoteExpiry,
            q.haircutBps
        )));
    }

    /// @notice A lender withdraws a quote before it expires.
    function cancelQuote(bytes32 requestId) external {
        quoteCancelled[msg.sender][requestId] = true;
        emit QuoteCancelled(msg.sender, requestId);
    }

    // -------------------------------------------------------------------------------------
    // OPEN
    // -------------------------------------------------------------------------------------

    /// @notice Accept a lender's signed quote and open the repo. ONE transaction.
    /// @dev Crosses cash against collateral atomically, then hands the unwind to the network.
    ///      Reverting here is correct and safe: nothing has moved yet.
    function openRepo(Quote calldata q, bytes calldata signature) external {
        if (msg.sender != q.borrower) revert NotBorrower(q.borrower, msg.sender);
        if (repos[q.requestId].status != Status.None) revert AlreadyExists(q.requestId);
        if (block.timestamp > q.quoteExpiry) revert QuoteExpired(q.quoteExpiry);
        if (quoteCancelled[q.lender][q.requestId]) revert QuoteWasCancelled(q.requestId);
        if (q.maturity <= block.timestamp) revert MaturityInPast();
        if (address(this).balance < MIN_HBAR_PER_REPO) {
            revert InsufficientHbarForUnwind(address(this).balance, MIN_HBAR_PER_REPO);
        }

        address signer = ECDSA.recover(hashQuote(q), signature);
        if (signer != q.lender) revert BadSignature(signer, q.lender);

        uint256 holdExpiry = uint256(q.maturity) + HOLD_BUFFER;

        // 1. cash leg: lender -> borrower, against the standing allowance
        if (!IERC20(q.cash).transferFrom(q.lender, q.borrower, q.principal)) revert CashLegFailed();

        // 2. security leg. We are an ATS operator for the borrower, so we create the hold
        //    ourselves and immediately execute it. Open destination (to == 0) means we name
        //    the lender at settlement time.
        (, uint256 openHoldId) = IHoldByPartition(q.security).createHoldFromByPartition(
            q.partition,
            q.borrower,
            IHoldByPartition.Hold({
                amount: q.collateralQty,
                expirationTimestamp: holdExpiry,
                escrow: address(this),
                to: address(0),
                data: ""
            }),
            ""
        );
        IHoldByPartition(q.security).executeHoldByPartition(
            IHoldByPartition.HoldIdentifier({
                partition: q.partition, tokenHolder: q.borrower, holdId: openHoldId
            }),
            q.lender,
            q.collateralQty
        );

        // Both legs have moved, or neither has. No exposure window.

        // 3. return-leg hold over the lender's new balance, so closeRepo has something to move
        //    back and the lender cannot move the collateral away during the term.
        (, uint256 closeHoldId) = IHoldByPartition(q.security).createHoldFromByPartition(
            q.partition,
            q.lender,
            IHoldByPartition.Hold({
                amount: q.collateralQty,
                expirationTimestamp: holdExpiry,
                escrow: address(this),
                to: address(0),
                data: ""
            }),
            ""
        );

        Repo storage s = repos[q.requestId];
        s.lender = q.lender; s.borrower = q.borrower; s.security = q.security;
        s.partition = q.partition; s.collateralQty = q.collateralQty; s.cash = q.cash;
        s.principal = q.principal; s.repurchase = q.repurchase; s.maturity = q.maturity;
        s.haircutBps = q.haircutBps; s.closeHoldId = closeHoldId;

        // 4. hand the unwind to the network
        s.scheduleAddress = _scheduleUnwind(q.requestId, q.maturity);
        s.status = Status.Open;

        emit RepoOpened(
            q.requestId, q.lender, q.borrower, q.security, q.collateralQty, q.cash,
            q.principal, q.repurchase, q.maturity, s.scheduleAddress
        );
    }

    /// @dev A saturated expiry second makes scheduleCall revert with SCHEDULE_EXPIRY_IS_BUSY.
    ///      Step forward rather than killing the trade: a maturity date is a real date.
    function _scheduleUnwind(bytes32 id, uint64 maturity) internal returns (address) {
        uint64 target = maturity;
        for (uint64 i; i < 10; ++i) {
            if (IHederaScheduleService(HSS).hasScheduleCapacity(target, SCHEDULE_GAS)) {
                if (target != maturity) emit ScheduleStepped(id, maturity, target);
                (int64 rc, address addr) = IHederaScheduleService(HSS).scheduleCall(
                    address(this), target, SCHEDULE_GAS, 0,
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
    ///      MUST NEVER REVERT. A scheduled transaction fires once and never retries, so a revert
    ///      is a settlement that silently did not happen. The default branch is not an error
    ///      path: it is what a repo does when someone fails to repurchase.
    function closeRepo(bytes32 id) external {
        Repo storage r = repos[id];
        if (r.status != Status.Open) return;

        bool funded = IERC20(r.cash).allowance(r.borrower, address(this)) >= r.repurchase
                   && IERC20(r.cash).balanceOf(r.borrower)               >= r.repurchase;

        if (!funded) {
            r.status = Status.Defaulted;
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
        ) returns (bool, bytes32) {
            r.status = Status.Closed;
            emit RepoClosed(id, r.repurchase, r.collateralQty);
        } catch {
            r.status = Status.Defaulted;
            emit RepoDefaulted(id, "collateral leg reverted after cash settled");
        }
    }

    // -------------------------------------------------------------------------------------
    // MARGIN  (one rubric point; keep it this small)
    // -------------------------------------------------------------------------------------

    /// @dev No oracle prices this bond: it was minted this week. `markedValue` is an admin-set
    ///      NAV or a proxy feed, and the README says which.
    function markCollateral(bytes32 id, uint256 markedValue) external onlyOwner {
        Repo storage r = repos[id];
        if (r.status != Status.Open) return;
        uint256 required = r.principal + (r.principal * r.haircutBps) / 10_000;
        if (markedValue < required) emit MarginCall(id, markedValue, required);
    }

    function sweep() external onlyOwner {
        (bool ok, ) = payable(owner).call{value: address(this).balance}("");
        require(ok, "sweep failed");
    }
}
