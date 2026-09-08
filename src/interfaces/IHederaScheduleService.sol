// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// HIP-1215 Hedera Schedule Service system contract.
// VERIFIED on testnet: schedule 0.0.10393574 executed 134ms past its expiry second.
address constant HSS = address(0x16b);

// Hedera ResponseCode.SUCCESS
int64 constant HEDERA_SUCCESS = 22;

interface IHederaScheduleService {
    /// @notice Schedule a contract call for a future second. The CALLING CONTRACT is the payer
    ///         and must hold HBAR (~0.12 per execution at 200k gas).
    /// @dev gasLimit 200_000 works. 2_000_000 fails hasScheduleCapacity: there is a per-second
    ///      capacity ceiling. Hedera's own tutorial suggests 2_000_000; it is not safe.
    function scheduleCall(
        address to,
        uint256 expirySecond,
        uint256 gasLimit,
        uint64 value,
        bytes memory callData
    ) external returns (int64 responseCode, address scheduleAddress);

    /// @notice Never reverts. Check first and step the expiry forward on false, rather than
    ///         reverting the surrounding trade.
    function hasScheduleCapacity(uint256 expirySecond, uint256 gasLimit)
        external view returns (bool capacity);
}
