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
///      There is deliberately NO price oracle and NO margin call. A repo is over-collateralised
///      at open by the haircut and short-dated, and the lender's remedy on default is keeping
///      collateral they already hold. That is how bilateral term repo actually works, and it
///      means there is no feed to manipulate.
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

    /// @notice Terms a lender signs off-chain and the borrower executes on-chain.
    /// @dev Field names and ORDER are load-bearing: QUOTE_TYPEHASH is the literal EIP-712 type
    ///      string for this struct. Changing either without updating the typehash silently
    ///      invalidates every signature.
    struct Quote {
        /// @dev Unique id for this RFQ. Doubles as the repo id and as the replay guard: a given
        ///      requestId can open exactly once, because openRepo requires Status.None.
        bytes32 requestId;
        /// @dev Signs this quote, pays `principal`, holds the collateral for the term.
        ///      Must have approved `cash` to this contract (standing approval, set up once).
        address lender;
        /// @dev Must be msg.sender on openRepo. Pledges the collateral, receives `principal`.
        ///      Must have authorised this contract as an ATS operator, so we can create their hold.
        address borrower;
        /// @dev The ATS diamond. An ERC-3643 / ERC-1400 security, not an ERC-20.
        address security;
        /// @dev ERC-1410 partition the collateral sits in. ATS balances are partitioned, so a
        ///      hold is always scoped to one.
        bytes32 partition;
        /// @dev Units of `security`, in that token's own decimals.
        uint256 collateralQty;
        /// @dev Settlement currency. On Hedera this is USDC, an HTS token reached through the
        ///      ERC-20 facade. Not HBAR: closeRepo is invoked by the network with no value
        ///      attached, so the repurchase cash cannot arrive as msg.value.
        address cash;
        /// @dev Cash paid lender -> borrower at open.
        uint256 principal;
        /// @dev Cash paid borrower -> lender at maturity. THIS IS THE RATE, expressed as an
        ///      amount rather than a percentage: no interest arithmetic on chain, no day-count
        ///      convention to argue about, no rounding disputes. The repo interest is
        ///      `repurchase - principal`.
        uint256 repurchase;
        /// @dev Unix seconds. The scheduled unwind targets this exact second. uint64 because
        ///      HIP-1215 takes a second-precision expiry, and it must be within 62 days.
        uint64  maturity;
        /// @dev Unix seconds after which this signature is dead. Keep it short, minutes not days:
        ///      the lender's allowance is standing, so a stale quote is a free option held by the
        ///      borrower against a price the lender may no longer want.
        uint64  quoteExpiry;
        /// @dev Over-collateralisation in basis points, agreed at open. THIS IS THE RISK
        ///      CONTROL. There is no mark-to-market and no margin call: the trade is
        ///      over-collateralised from the start, short-dated, and the lender's remedy on
        ///      default is keeping collateral they already hold. Recorded in the signed quote so
        ///      the agreed cushion is part of the audit trail.
        uint256 haircutBps;
    }

    /// @notice Repo lifecycle. Both end states are terminal.
    enum Status {
        /// @dev Never opened. Also the replay guard: openRepo requires this.
        None,
        /// @dev Cash and collateral have crossed. The unwind is scheduled and pending.
        Open,
        /// @dev Borrower repurchased at maturity; collateral went back to them.
        Closed,
        /// @dev Borrower did not repurchase; the lender keeps the collateral. This is NOT an
        ///      error path. It is what a repo does when someone fails to repurchase, and
        ///      closeRepo reaching it is a correct settlement, not a failed one.
        Defaulted
    }

    /// @notice On-chain state for an open repo. Mostly the accepted quote, plus what the
    ///         network-invoked closeRepo needs to finish without any off-chain input.
    /// @dev Deliberately absent: `requestId` (it is the mapping key) and `quoteExpiry` (spent at
    ///      open and meaningless afterwards).
    struct Repo {
        /// @dev As accepted from the quote. Receives `repurchase` at maturity.
        address lender;
        /// @dev As accepted from the quote. Owes `repurchase` at maturity.
        address borrower;
        /// @dev The ATS diamond holding the collateral.
        address security;
        /// @dev Partition the collateral and both holds live in.
        bytes32 partition;
        /// @dev Units of `security` pledged.
        uint256 collateralQty;
        /// @dev Settlement currency, re-read at close so the close leg cannot be redirected.
        address cash;
        /// @dev Cash that moved at open. Kept for the margin calculation and the audit trail.
        uint256 principal;
        /// @dev Cash owed at maturity. closeRepo checks the borrower's allowance AND balance
        ///      against this before moving anything.
        uint256 repurchase;
        /// @dev Unix seconds the unwind was scheduled for. Informational after open; the network
        ///      owns the timing from that point.
        uint64  maturity;
        /// @dev Over-collateralisation in basis points as agreed at open. Recorded, not
        ///      enforced intraday: see the Quote field for why there is no margin call.
        uint256 haircutBps;
        /// @dev The ATS hold created over the LENDER's balance at open, with this contract as
        ///      escrow. Two jobs: it locks the collateral for the term so the lender cannot move
        ///      it away and leave nothing to give back, and it is what closeRepo executes back to
        ///      the borrower on repurchase. Its expiry is maturity + HOLD_BUFFER, because after a
        ///      hold expires anyone may reclaim it to the holder.
        uint256 closeHoldId;
        /// @dev Address of the HIP-1215 schedule that will call closeRepo. Kept so the pending
        ///      settlement is inspectable on HashScan and reconstructable in the HCS trail.
        address scheduleAddress;
        /// @dev Lifecycle. closeRepo returns silently unless this is Open, which is what makes it
        ///      idempotent and safe to invoke more than once.
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
    event RepoRepaidEarly(bytes32 indexed id, uint64 repaidAt, uint64 scheduledMaturity);
    event RepoDefaulted(bytes32 indexed id, string reason);
    event ScheduleStepped(bytes32 indexed id, uint64 requested, uint64 actual);
    event QuoteCancelled(address indexed lender, bytes32 indexed requestId);
    event Funded(address indexed from, uint256 amount);

    error NotOwner();
    error InternalOnly();
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
    error NotOpen(bytes32 id);

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    function _onlyOwner() internal view {
        if (msg.sender != owner) revert NotOwner();
    }

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

    /// @notice Settle the repo at maturity. Called by the NETWORK, not by a person.
    ///
    /// @dev HOW THIS RUNS. At open, `openRepo` handed HIP-1215 a scheduled call to this function
    ///      with this `id` baked into the calldata. At the maturity second the network executes
    ///      it, paid for by this contract, with nobody online and no transaction of ours pending.
    ///      That is the whole point of the project.
    ///
    ///      NO ACCESS CONTROL, deliberately. A scheduled execution has no EOA sender, so there is
    ///      no `msg.sender` to gate on. Anyone may also call it manually; that is harmless,
    ///      because the outcome depends only on stored state and the borrower's allowance.
    ///
    ///      MUST NEVER REVERT. A scheduled transaction fires exactly once and is never retried,
    ///      so a revert here is not an error the network reports back to anyone, it is a
    ///      settlement that silently did not happen and can never happen. Every failure path
    ///      therefore records a terminal state and returns, rather than throwing.
    ///
    ///      Defaulting is NOT an error. It is what a repo does when the borrower fails to
    ///      repurchase: the lender simply keeps the collateral they already hold. That is the
    ///      economic remedy, and it requires us to move nothing at all.
    function closeRepo(bytes32 id) external {
        Repo storage r = repos[id];

        // Idempotency guard, and the reason early repayment is safe. If `repayEarly` already
        // settled this repo, the pending schedule still fires at maturity, lands here, finds a
        // terminal status and returns quietly. Also covers a manual double-call.
        if (r.status != Status.Open) return;

        // Check BEFORE moving anything. The borrower owes `repurchase`; they must both have the
        // balance and still have the allowance standing. Either being short means default, and
        // we take that decision without having touched a single token.
        bool funded = IERC20(r.cash).allowance(r.borrower, address(this)) >= r.repurchase
                   && IERC20(r.cash).balanceOf(r.borrower)               >= r.repurchase;

        if (!funded) {
            // The lender already holds the collateral from open, so there is nothing to move:
            // we only have to stop the return leg from happening. Terminal.
            r.status = Status.Defaulted;
            emit RepoDefaulted(id, "repurchase amount not available at maturity");
            return;
        }

        // Both legs in a single self-call so the EVM rolls back both if either fails.
        // No partial settlement: cash cannot move without collateral following.
        try this._executeSettlement(id) {
            r.status = Status.Closed;
            emit RepoClosed(id, r.repurchase, r.collateralQty);
        } catch Error(string memory reason) {
            r.status = Status.Defaulted;
            emit RepoDefaulted(id, reason);
        } catch {
            r.status = Status.Defaulted;
            emit RepoDefaulted(id, "settlement reverted");
        }
    }

    /// @dev Internal sub-call from closeRepo; atomic leg settlement, preserves closeRepo state.
    function _executeSettlement(bytes32 id) external {
        if (msg.sender != address(this)) revert InternalOnly();
        Repo storage r = repos[id];

        bool ok = IERC20(r.cash).transferFrom(r.borrower, r.lender, r.repurchase);
        if (!ok) revert CashLegFailed();

        IHoldByPartition(r.security).executeHoldByPartition(
            IHoldByPartition.HoldIdentifier({
                partition: r.partition, tokenHolder: r.lender, holdId: r.closeHoldId
            }),
            r.borrower,
            r.collateralQty
        );
    }

    /// @notice Repurchase before maturity and take the collateral back early.
    /// @dev The borrower pays the FULL `repurchase` amount, with no rebate for the unused term.
    ///      That is why this needs no consent from the lender: they receive exactly the return
    ///      they signed for, sooner, so they are strictly better off and cannot be harmed by it.
    ///
    ///      Unlike `closeRepo`, this one SHOULD revert on failure. It is caller-initiated and
    ///      atomic: if a leg fails, nothing has moved, and the borrower needs to be told rather
    ///      than silently marked in default on a repo they were trying to settle.
    ///
    ///      The pending schedule is deliberately left alone. It fires at maturity, sees a
    ///      terminal status, and returns. It costs this contract one scheduled execution fee
    ///      (~0.12 HBAR) to do nothing. If `deleteSchedule` is available on the schedule service
    ///      system contract, calling it here would reclaim that; verify the signature first.
    function repayEarly(bytes32 id) external {
        Repo storage r = repos[id];
        if (msg.sender != r.borrower) revert NotBorrower(r.borrower, msg.sender);
        if (r.status != Status.Open) revert NotOpen(id);

        if (!IERC20(r.cash).transferFrom(r.borrower, r.lender, r.repurchase)) revert CashLegFailed();

        IHoldByPartition(r.security).executeHoldByPartition(
            IHoldByPartition.HoldIdentifier({
                partition: r.partition, tokenHolder: r.lender, holdId: r.closeHoldId
            }),
            r.borrower,
            r.collateralQty
        );

        r.status = Status.Closed;
        emit RepoRepaidEarly(id, uint64(block.timestamp), r.maturity);
        emit RepoClosed(id, r.repurchase, r.collateralQty);
    }

    function sweep() external onlyOwner {
        (bool ok, ) = payable(owner).call{value: address(this).balance}("");
        require(ok, "sweep failed");
    }
}
