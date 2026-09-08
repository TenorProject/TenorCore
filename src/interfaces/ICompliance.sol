// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice ERC-3643 compliance module as ATS calls it. Verified against v8.0.0 source.
/// @dev Called from EIGHT places. transferred/created/destroyed go through functionCall
///      (state-changing), so THEY MUST NEVER REVERT. A failure surfaces as
///      ComplianceCallFailed() = 0x67fba102.
interface ICompliance {
    function transferred(address _from, address _to, uint256 _amount) external;
    function created(address _to, uint256 _amount) external;
    function destroyed(address _from, uint256 _amount) external;
    function canTransfer(address _from, address _to, uint256 _amount) external view returns (bool);
}
