// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice The ATS setters we need to point a bond at our own registry and compliance module.
/// @dev BOTH require ROLE_TREX_OWNER (0xd9e1264632ee9a37e8673a0c55a0a1d8b38c758e843084168ee08cd2d1f7e6f0),
///      NOT DEFAULT_ADMIN_ROLE. initializeIdentity is one-shot and already spent on our bond.
interface ITenorWiring {
    function setIdentityRegistry(address _identityRegistry) external;
    function identityRegistry() external view returns (address);
    function setCompliance(address _compliance) external;
    function compliance() external view returns (address);
}
