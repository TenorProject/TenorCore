// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice The ONLY function ATS ever calls on an identity registry, in exactly one place
///         (ERC1594StorageWrapper._validateIdentifiedAccount). Verified against v8.0.0 source.
/// @dev An EMPTY return passes the check. Only a failed staticcall reverts, with
///      IdentityRegistryCallFailed() = 0xad87849e.
interface IIdentityRegistry {
    function isVerified(address _userAddress) external view returns (bool);
}
