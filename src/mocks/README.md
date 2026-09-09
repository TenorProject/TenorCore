# Mocks

`forge test` cannot reach Hedera system contracts, so these stand in for them locally. **Passing
tests against these proves branch logic, not integration.** The integration only runs on testnet,
through `script/TestnetFlow.s.sol`. See `TESTNET.md`.

## What is here

- **`MockATS.sol`** — the ATS hold surface, and only the parts `TenorSettlement` calls:
  `createHoldFromByPartition` and `executeHoldByPartition`. It models the accounting that matters,
  `total = available + held`, and executes a hold as an escrow transfer. `setFailExecute(true)`
  forces the execute leg to fail, which is how the `try/catch` fallbacks in `closeRepo` are tested.
  It does **not** enforce operator authorisation. The real diamond does, which is the single most
  likely stage 2 failure.
- **`MockERC20.sol`** — stands in for the cash leg. Plain ERC-20. It does not model HTS token
  association, so stage 1 hides that step entirely.

## What is NOT here, and why

There is no mock schedule service contract. `0x16b` is handled with `vm.mockCall` in
`test/TenorSettlement.t.sol`, because the address is fixed and only two functions are called. Do
not add a `MockScheduleService.sol`; it would have to be `vm.etch`ed to `0x16b` anyway, and the
mock calls are already easier to read at the point of use.

`closeRepo` has no access control, so a test drives it directly from an arbitrary account
(`makeAddr("scheduler")`) to stand in for the network. No mock is needed to fire it.
