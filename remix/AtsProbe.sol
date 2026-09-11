// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * AtsProbe: a Remix handle on a deployed ATS security.
 *
 * DO NOT DEPLOY THIS. Compile it, pick `IAtsProbe` in the Deploy panel, paste the bond
 * address into "At Address", and Remix gives you a button for every function below
 * against the already-deployed diamond.
 *
 * Bond (Hedera testnet):     0xc2dadb01462b766bb2f58c9638b32e97200ca07d
 * TenorSettlement:           0x8f9EE0a9Aae23fDe01e12cF6A6c9F024C59D4DB9
 * Default partition:         0x0000000000000000000000000000000000000000000000000000000000000001
 *
 * THE CLAIM UNDER TEST
 * --------------------
 * createHoldFromByPartition consumes an ERC-20 ALLOWANCE, not an ERC-1400 operator
 * authorization. Evidence so far: ATS ERC20StorageWrapper.sol reads
 * erc20Stor.allowed[from][spender] and reverts InsufficientAllowance(spender, from),
 * and on-chain our authorizeOperator succeeded while the hold still failed.
 * The procedure at the bottom of this file falsifies it if it is wrong.
 */
interface IAtsProbe {
    // ---- ERC-20 surface (what the claim says actually governs) ----
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);

    // ---- ERC-1400 partition surface ----
    function balanceOfByPartition(bytes32 partition, address account) external view returns (uint256);
    function partitionsOf(address account) external view returns (bytes32[] memory);

    // ---- ERC-1400 operator surface (what the claim says does NOT govern holds) ----
    function authorizeOperator(address operator) external;
    function revokeOperator(address operator) external;
    function isOperator(address operator, address tokenHolder) external view returns (bool);
    function authorizeOperatorByPartition(bytes32 partition, address operator) external;
    function isOperatorForPartition(bytes32 partition, address operator, address tokenHolder)
        external view returns (bool);

    // ---- Hold surface. Struct layout verified against ATS v8.0.0 (commit be4f860e). ----
    struct Hold {
        uint256 amount;
        uint256 expirationTimestamp;
        address escrow;
        address to;                 // address(0) = open destination, named at execution
        bytes data;
    }

    struct HoldIdentifier {
        bytes32 partition;
        address tokenHolder;
        uint256 holdId;
    }

    function createHoldByPartition(bytes32 partition, Hold calldata hold)
        external returns (bool success_, uint256 holdId_);

    function createHoldFromByPartition(
        bytes32 partition, address from, Hold calldata hold, bytes calldata operatorData
    ) external returns (bool success_, uint256 holdId_);

    function executeHoldByPartition(HoldIdentifier calldata id, address to, uint256 amount)
        external returns (bool success_, bytes32 partition_);

    function releaseHoldByPartition(HoldIdentifier calldata id, uint256 amount)
        external returns (bool success_);

    function getHeldAmountForByPartition(bytes32 partition, address tokenHolder)
        external view returns (uint256 amount_);

    /**
     * Read-only eligibility check ATS ships. `reason` is the SELECTOR of the blocking
     * error, so this names the failing gate without spending a transaction.
     * InsufficientAllowance(address,address) is 0xf180d8f9.
     * Signature taken from our earlier reading of the ATS source and NOT yet exercised
     * against the live diamond: if this one reverts, the signature is wrong, not the bond.
     */
    function canTransferByPartition(
        address from, address to, bytes32 partition, uint256 value, bytes calldata data
    ) external view returns (bool status_, bytes1 code_, bytes32 reason_);
}

/*
 * ============================================================================
 * PROCEDURE
 * ============================================================================
 *
 * Setup. Two accounts. A = the holder (must actually own tokens in the partition).
 * B = any second account, which stands in for TenorSettlement.
 *
 * STEP 0. Sanity, as A.
 *     decimals()
 *     balanceOfByPartition(0x..01, A)     <- if this is 0, stop. Nothing else can work.
 *     partitionsOf(A)                     <- confirms 0x..01 is really the partition in use
 *
 * STEP 1. Operator only, no allowance.
 *     as A:  authorizeOperator(B)
 *     as A:  isOperator(B, A)             -> expect true
 *     as A:  allowance(A, B)              -> expect 0
 *     as B:  createHoldFromByPartition(
 *                0x0000000000000000000000000000000000000000000000000000000000000001,
 *                A,
 *                [100, <unix now + 86400>, B, 0x0000000000000000000000000000000000000000, 0x],
 *                0x
 *            )
 *
 *   REVERTS with InsufficientAllowance  -> the claim holds. Operator is not enough.
 *   SUCCEEDS                            -> the claim is WRONG and the real problem is
 *                                          elsewhere. Tell me, do not paper over it.
 *
 * STEP 2. Add the allowance.
 *     as A:  approve(B, 1000000000000000000)
 *     as A:  allowance(A, B)              -> expect 1e18
 *     as B:  createHoldFromByPartition(... same args ...)
 *
 *   SUCCEEDS -> confirmed. Do the same approve from both the real borrower and the
 *               real lender, naming TenorSettlement as spender, and rerun openRepo.
 *
 * STEP 3. Cheaper substitute for the whole thing, if it works:
 *     canTransferByPartition(A, B, 0x..01, 100, 0x)
 *   reason_ == 0xf180d8f9...  means InsufficientAllowance, with no transaction spent.
 *
 * NOTE ON THE HOLD TUPLE. Remix wants it as one bracketed list in struct order:
 *     [amount, expirationTimestamp, escrow, to, data]
 * expirationTimestamp is MANDATORY and must be in the future. After expiry anyone can
 * reclaim the held tokens to the holder, which is why TenorSettlement sets it to
 * maturity + HOLD_BUFFER rather than trusting a caller-supplied value.
 */
