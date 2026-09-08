// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title TenorCompliance
/// @notice Minimal ERC-3643 compliance module for Hedera Asset Tokenization Studio.
/// @dev ATS calls transferred/created/destroyed on state changes and canTransfer on validation.
///      The hooks go through functionCall, so THEY MUST NEVER REVERT: they only emit.
///      The events are useful in their own right, `created` firing on mint gives a clean
///      on-chain trace for the demo.
contract TenorCompliance {
    address public owner;
    bool public allowAll = true;

    event TransferRecorded(address indexed from, address indexed to, uint256 amount);
    event CreatedRecorded(address indexed to, uint256 amount);
    event DestroyedRecorded(address indexed from, uint256 amount);
    event AllowAllSet(bool status);

    error NotOwner();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function canTransfer(address, address, uint256) external view returns (bool) {
        return allowAll;
    }

    function transferred(address _from, address _to, uint256 _amount) external {
        emit TransferRecorded(_from, _to, _amount);
    }

    function created(address _to, uint256 _amount) external {
        emit CreatedRecorded(_to, _amount);
    }

    function destroyed(address _from, uint256 _amount) external {
        emit DestroyedRecorded(_from, _amount);
    }

    function setAllowAll(bool status) external onlyOwner {
        allowAll = status;
        emit AllowAllSet(status);
    }
}
