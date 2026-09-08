// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title TenorIdentityRegistry
/// @notice Minimal ERC-3643 identity registry for Hedera Asset Tokenization Studio.
/// @dev ATS calls exactly one function on a registry: isVerified(address). Deploy with
///      verifyEveryone = true to unblock development, then flip it off and whitelist the two
///      demo counterparties so the rejection beat comes from the registry itself.
///      Whitelist the LONG-ZERO address form the wallet presents, not an ECDSA alias.
contract TenorIdentityRegistry {
    address public owner;
    bool public verifyEveryone;
    mapping(address => bool) public verified;

    event VerifiedSet(address indexed account, bool status);
    event VerifyEveryoneSet(bool status);
    event OwnerChanged(address indexed newOwner);

    error NotOwner();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(bool _verifyEveryone) {
        owner = msg.sender;
        verifyEveryone = _verifyEveryone;
        emit OwnerChanged(msg.sender);
        emit VerifyEveryoneSet(_verifyEveryone);
    }

    /// @notice The only function ATS calls.
    function isVerified(address _userAddress) external view returns (bool) {
        return verifyEveryone || verified[_userAddress];
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

    function setVerifyEveryone(bool status) external onlyOwner {
        verifyEveryone = status;
        emit VerifyEveryoneSet(status);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
        emit OwnerChanged(newOwner);
    }
}
