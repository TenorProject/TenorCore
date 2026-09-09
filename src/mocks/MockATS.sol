// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IHoldByPartition} from "../interfaces/IHoldByPartition.sol";

/// @notice Minimal stand-in for the ATS diamond's hold surface.
/// @dev Models the part that matters: total = available + held, holds are created against a
///      holder's available balance, and only the escrow can execute one. Enough to test that
///      collateral actually moves and that closeRepo's branches behave.
contract MockATS is IHoldByPartition {
    mapping(address => uint256) public available;
    mapping(address => uint256) public held;

    struct StoredHold { address holder; address escrow; uint256 amount; uint256 expiry; bool live; }
    mapping(uint256 => StoredHold) public holds;
    uint256 public nextHoldId = 1;

    /// @dev Set true to make execute revert, so we can exercise closeRepo's catch branch.
    bool public failExecute;

    function mint(address to, uint256 amount) external { available[to] += amount; }
    function setFailExecute(bool v) external { failExecute = v; }

    function createHoldByPartition(bytes32, Hold calldata h)
        external returns (bool, uint256)
    { return _create(msg.sender, h); }

    function createHoldFromByPartition(bytes32, address from, Hold calldata h, bytes calldata)
        external returns (bool, uint256)
    { return _create(from, h); }

    function _create(address from, Hold calldata h) internal returns (bool, uint256) {
        require(available[from] >= h.amount, "insufficient available");
        available[from] -= h.amount;
        held[from] += h.amount;
        uint256 id = nextHoldId++;
        holds[id] = StoredHold(from, h.escrow, h.amount, h.expirationTimestamp, true);
        return (true, id);
    }

    function executeHoldByPartition(HoldIdentifier calldata id, address to, uint256 amount)
        external returns (bool, bytes32)
    {
        require(!failExecute, "execute disabled");
        StoredHold storage s = holds[id.holdId];
        require(s.live, "no such hold");
        require(s.escrow == msg.sender, "not escrow");
        require(s.holder == id.tokenHolder, "holder mismatch");
        require(s.amount >= amount, "amount");
        s.amount -= amount;
        if (s.amount == 0) s.live = false;
        held[id.tokenHolder] -= amount;
        available[to] += amount;
        return (true, id.partition);
    }

    function releaseHoldByPartition(HoldIdentifier calldata id, uint256 amount)
        external returns (bool)
    {
        StoredHold storage s = holds[id.holdId];
        require(s.live && s.escrow == msg.sender, "release");
        s.amount -= amount;
        held[s.holder] -= amount;
        available[s.holder] += amount;
        if (s.amount == 0) s.live = false;
        return true;
    }

    function getHeldAmountForByPartition(bytes32, address holder) external view returns (uint256) {
        return held[holder];
    }
}
