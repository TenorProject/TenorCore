// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title TenorCompliance
/// @notice Minimal ERC-3643 compliance module for Hedera Asset Tokenization Studio.
/// @dev ATS REQUIRES a compliance module to be wired: without one, every mint and transfer reverts
///      with ComplianceCallFailed(). ATS does not ship an implementation. Testnet only.
/// @dev ATS calls transferred/created/destroyed on state changes and canTransfer on validation.
///      The hooks go through functionCall, so THEY MUST NEVER REVERT: they only emit.
///      The events are useful in their own right, `created` firing on mint gives a clean
///      on-chain trace for the demo.
contract TenorCompliance {
    address public owner;
    bool public permitAllForTestnet = true;

    event TransferRecorded(address indexed from, address indexed to, uint256 amount);
    event CreatedRecorded(address indexed to, uint256 amount);
    event DestroyedRecorded(address indexed from, uint256 amount);
    event PermitAllForTestnetSet(bool status);

    error NotOwner();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function canTransfer(address, address, uint256) external view returns (bool) {
        return permitAllForTestnet;
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

    function setPermitAllForTestnet(bool status) external onlyOwner {
        permitAllForTestnet = status;
        emit PermitAllForTestnetSet(status);
    }
}
