// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title TenorIdentityRegistry
/// @notice Minimal ERC-3643 identity registry for Hedera Asset Tokenization Studio.
/// @dev ATS REQUIRES a registry to be wired: without one, every mint and transfer of the security
///      reverts with IdentityRegistryCallFailed(). ATS does not ship an implementation, and its
///      production credential path needs issuer infrastructure unavailable on testnet. This is the
///      minimum that satisfies the interface for a testnet bond we issued ourselves.
/// @dev ATS calls exactly one function on a registry: isVerified(address). Deploy with
///      permitAllForTestnet = true to unblock development, then flip it off and whitelist the two
///      demo counterparties so the rejection beat comes from the registry itself.
///      Whitelist the LONG-ZERO address form the wallet presents, not an ECDSA alias.
contract TenorIdentityRegistry {
    address public owner;
    bool public permitAllForTestnet;
    mapping(address => bool) public verified;

    event VerifiedSet(address indexed account, bool status);
    event PermitAllForTestnetSet(bool status);
    event OwnerChanged(address indexed newOwner);

    error NotOwner();

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    function _onlyOwner() internal view {
        if (msg.sender != owner) revert NotOwner();
    }

    constructor(bool _permitAllForTestnet) {
        owner = msg.sender;
        permitAllForTestnet = _permitAllForTestnet;
        emit OwnerChanged(msg.sender);
        emit PermitAllForTestnetSet(_permitAllForTestnet);
    }

    /// @notice The only function ATS calls.
    function isVerified(address _userAddress) external view returns (bool) {
        return permitAllForTestnet || verified[_userAddress];
    }

    function setVerified(address account, bool status) external onlyOwner {
        verified[account] = status;
        emit VerifiedSet(account, status);
    }

    function setVerifiedBatch(address[] calldata accounts, bool status) external onlyOwner {
        for (uint256 i; i < accounts.length; ++i) {
            verified[accounts[i]] = status;
            emit VerifiedSet(accounts[i], status);
        }
    }

    function setPermitAllForTestnet(bool status) external onlyOwner {
        permitAllForTestnet = status;
        emit PermitAllForTestnetSet(status);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
        emit OwnerChanged(newOwner);
    }
}
