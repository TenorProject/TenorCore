# Mocks

`forge test` cannot reach Hedera system contracts. These stand in for them locally.

- `MockScheduleService.sol` — answers `hasScheduleCapacity` and records `scheduleCall`, so
  `openRepo` can be tested without `0x16b`. Add a helper that fires the scheduled callback on
  demand, to exercise both `closeRepo` branches.
- `MockHold.sol` — minimal ATS hold surface: create, operator-create, execute.
- `MockERC20.sol` — stands in for USDC.

Passing tests against these proves the branch logic, not the integration. The integration only
runs on testnet.
