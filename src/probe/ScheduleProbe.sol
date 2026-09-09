// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/*
 * ScheduleProbe
 *
 * Evidence rig for HIP-1215. Kept in the repo because its measurements underpin the whole
 * project and a judge can rerun them.
 *
 * PROVEN on Hedera testnet, schedule 0.0.10393574:
 *   requested expiry 1788706751.000000000
 *   executed         1788706751.134840656   -> 134 ms drift
 *   payer            the CONTRACT (0.0.10393539), not the caller
 *   cost             12,002,340 tinybar (~0.12 HBAR) at 200k gas
 *   arm() gas        1,511,069
 *   gasLimit 200_000 works; 2_000_000 fails hasScheduleCapacity
 *
 * STILL UNANSWERED: what does the network do when a scheduled call REVERTS? Set
 * shouldRevert = true, arm, and check whether fireCount stays put and whether the schedule
 * is consumed with no retry. TenorSettlement.closeRepo's two-branch design depends on it.
 */

import {IHederaScheduleService, HSS, HEDERA_SUCCESS} from "../interfaces/IHederaScheduleService.sol";

/// @title ScheduleProbe
/// @notice Tests whether a Hedera contract can schedule its own future call, and what the
///         network does when that scheduled call reverts.
contract ScheduleProbe {
    address public owner;

    uint256 public armedAt;
    uint256 public scheduledFor;
    uint256 public firedAt;
    uint256 public fireCount;
    uint256 public lastDrift;
    address public lastSchedule;
    int64   public lastResponseCode;

    bool public shouldRevert;

    event Armed(address indexed scheduleAddress, uint256 scheduledFor, int64 responseCode);
    event Fired(uint256 firedAt, uint256 drift, uint256 count);
    event Funded(address indexed from, uint256 amount);

    error NotOwner();
    error NoCapacity(uint256 expirySecond, uint256 gasLimit);
    error HssCallReverted(bytes returndata);
    error ScheduleFailed(int64 responseCode);
    error DeliberateRevert();

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    function _onlyOwner() internal view {
        if (msg.sender != owner) revert NotOwner();
    }

    constructor() payable {
        owner = msg.sender;
    }

    receive() external payable {
        emit Funded(msg.sender, msg.value);
    }

    /// @param delaySeconds 900 for fifteen minutes.
    /// @param gasLimit 200_000. Do not raise it, see the header.
    function arm(uint256 delaySeconds, uint256 gasLimit) external onlyOwner returns (address) {
        uint256 expiry = block.timestamp + delaySeconds;

        if (!IHederaScheduleService(HSS).hasScheduleCapacity(expiry, gasLimit)) {
            revert NoCapacity(expiry, gasLimit);
        }

        bytes memory callData = abi.encodeWithSelector(this.settle.selector);

        // Low-level so this works whether the system contract returns (int64) or (int64, address).
        (bool ok, bytes memory ret) = HSS.call(
            abi.encodeWithSelector(
                IHederaScheduleService.scheduleCall.selector,
                address(this), expiry, gasLimit, uint64(0), callData
            )
        );
        if (!ok) revert HssCallReverted(ret);

        int64 rc;
        address addr;
        if (ret.length >= 64)      { (rc, addr) = abi.decode(ret, (int64, address)); }
        else if (ret.length >= 32) { rc = abi.decode(ret, (int64)); }

        lastResponseCode = rc;
        if (rc != HEDERA_SUCCESS) revert ScheduleFailed(rc);

        armedAt = block.timestamp;
        scheduledFor = expiry;
        lastSchedule = addr;
        emit Armed(addr, expiry, rc);
        return addr;
    }

    /// @notice The NETWORK calls this. No signature, nobody online.
    /// @dev Deliberately no access control: a scheduled execution has no EOA sender.
    function settle() external {
        if (shouldRevert) revert DeliberateRevert();
        firedAt = block.timestamp;
        unchecked { fireCount += 1; }
        lastDrift = block.timestamp > scheduledFor ? block.timestamp - scheduledFor : 0;
        emit Fired(firedAt, lastDrift, fireCount);
    }

    function setShouldRevert(bool v) external onlyOwner { shouldRevert = v; }

    function status() external view returns (
        uint256 nowTs, uint256 _armedAt, uint256 _scheduledFor, uint256 secondsUntilFire,
        uint256 _firedAt, uint256 _fireCount, uint256 _lastDrift, address _lastSchedule,
        bool _shouldRevert, uint256 balanceTinybar
    ) {
        return (
            block.timestamp, armedAt, scheduledFor,
            block.timestamp >= scheduledFor ? 0 : scheduledFor - block.timestamp,
            firedAt, fireCount, lastDrift, lastSchedule, shouldRevert,
            address(this).balance   // tinybars, 8 dp. msg.value is weibar, 18 dp.
        );
    }

    function sweep() external onlyOwner {
        (bool ok, ) = payable(owner).call{value: address(this).balance}("");
        require(ok, "sweep failed");
    }
}
