// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Plain ERC-20 stand-in. Used for BOTH legs now: cash (USDC via the HTS ERC-20
///         facade on testnet) and the security (the ATS diamond, which exposes an ERC-20
///         facet). Locally there is no 0x167 and no diamond, so this substitutes for both.
contract MockERC20 {
    string public name = "Mock USDC";
    string public symbol = "mUSDC";
    uint8 public decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @dev Failure switches, so the escrow model's terminal paths can be tested. The real
    ///      security can refuse a transfer for compliance reasons at exactly the moment the
    ///      schedule fires, and closeRepo must survive that without reverting.
    bool public failTransfer;          // transfer() reverts
    bool public transferReturnsFalse;  // transfer() returns false without moving anything

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function setFailTransfer(bool v) external { failTransfer = v; }
    function setTransferReturnsFalse(bool v) external { transferReturnsFalse = v; }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (failTransfer) revert("transfer disabled");
        if (transferReturnsFalse) return false;
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        require(balanceOf[from] >= amount, "balance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
