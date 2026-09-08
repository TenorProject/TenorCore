// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice ATS hold API. Holds are the settlement primitive: tokens stay in the holder's
///         account, moving from available to held balance, and only `escrow` can execute.
///
/// !! VERIFY EVERY SIGNATURE HERE AGAINST THE DEPLOYED ATS ABI BEFORE BUILDING ON IT. !!
/// Struct shapes are read from v8.0.0 source, but parameter and return types have not been
/// confirmed against the live diamond. Too much ATS documentation has already been wrong.
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

    /// @dev Requires the caller to have been authorised as an ATS operator by the holder.
    function operatorCreateHoldByPartition(bytes32 _partition, address _from, Hold calldata _hold)
        external returns (bool success_, uint256 holdId_);

    /// @dev Only the escrow may call. Partial execution supported.
    function executeHoldByPartition(HoldIdentifier calldata _id, address _to, uint256 _amount)
        external returns (bool success_);

    function releaseHoldByPartition(HoldIdentifier calldata _id, uint256 _amount)
        external returns (bool success_);

    function getHeldAmountForByPartition(bytes32 _partition, address _tokenHolder)
        external view returns (uint256 amount_);
}
