// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice ATS hold API. Holds are the settlement primitive: tokens stay in the holder's
///         account, moving from available to held balance, and only `escrow` can execute.
///
/// VERIFIED against ATS source at v8.0.0 (commit be4f860e), against
/// packages/ats/contracts/contracts/facets/holdByPartition/IHoldByPartition.sol and
/// facets/hold/IHoldTypes.sol. Not yet exercised against the live diamond call-by-call;
/// confirm on testnet before relying on it further.
interface IHoldByPartition {
    /// @dev `to == address(0)` gives an OPEN DESTINATION hold: the escrow names the recipient
    ///      at settlement time. This is what makes holds usable for DvP.
    ///      `expirationTimestamp` is mandatory, and AFTER EXPIRY ANYONE CAN RECLAIM to the
    ///      holder. Always assert hold expiry outlives any schedule that depends on it.
    struct Hold {
        uint256 amount;
        uint256 expirationTimestamp;
        address escrow;
        address to;
        bytes data;
    }

    struct HoldIdentifier {
        bytes32 partition;
        address tokenHolder;
        uint256 holdId;
    }

    function createHoldByPartition(bytes32 _partition, Hold calldata _hold)
        external returns (bool success_, uint256 holdId_);

    /// @dev Real ATS name is `createHoldFromByPartition`, not `operatorCreateHoldByPartition`
    ///      (that name does not exist on the diamond and would hit the fallback). Requires the
    ///      caller to have been authorised as an ATS operator by `_from`.
    function createHoldFromByPartition(
        bytes32 _partition, address _from, Hold calldata _hold, bytes calldata _operatorData
    ) external returns (bool success_, uint256 holdId_);

    /// @dev Only the escrow may call. Partial execution supported. Real ATS also returns the
    ///      partition the tokens moved from, alongside success.
    function executeHoldByPartition(HoldIdentifier calldata _id, address _to, uint256 _amount)
        external returns (bool success_, bytes32 partition_);

    function releaseHoldByPartition(HoldIdentifier calldata _id, uint256 _amount)
        external returns (bool success_);

    function getHeldAmountForByPartition(bytes32 _partition, address _tokenHolder)
        external view returns (uint256 amount_);
}
