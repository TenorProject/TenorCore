---
name: tenor-debug
description: Diagnose a failed forge build, forge test, forge script or Hedera testnet transaction in the Tenor repo. Load whenever something reverts, a test fails, a schedule does not fire, a balance reads wrong, or an ATS mint or transfer is rejected. Every entry here is a failure this team already hit and solved.
---

# Failure playbook

Work top down: **find the symptom, apply the fix, do not investigate from first principles.**
Every entry below cost this team real time. Rediscovering one is pure waste.

Two rules that override anything you conclude while debugging:

- **Never make `closeRepo` revert.** A scheduled transaction fires once and never retries, so a
  revert there is a settlement that silently did not happen. If a leg fails, catch it and take a
  terminal branch. `repayEarly` has the opposite policy and *should* revert; do not unify them.
- **Never change the field order or field names of the `Quote` struct** in `TenorSettlement.sol`.
  They are hashed into `QUOTE_TYPEHASH`. Any edit silently invalidates every signature, and the
  failure surfaces as `BadSignature`, which looks like a key problem and is not.

---

## Reverts with a 4-byte selector

Decode against the errors declared in `src/TenorSettlement.sol` first. Ones already met:

| Selector | Error | Cause and fix |
|---|---|---|
| `0xad87849e` | `IdentityRegistryCallFailed()` | The bond's identity registry slot holds something that is not an ERC-3643 identity registry. This happened by pasting an **external KYC list address into the identity registry field** at bond creation. Fix: deploy `TenorIdentityRegistry` and call `setIdentityRegistry`. That call needs **`ROLE_TREX_OWNER`**, not admin. |
| `0x67fba102` | `ComplianceCallFailed()` | Same mistake on the compliance slot. Fix: `TenorCompliance` plus `setCompliance`, again under `ROLE_TREX_OWNER`. |
| `BadSignature` | | Either the `Quote` struct changed (see the rule above), or the signature was recovered against a different digest. Never reimplement EIP-712 off-chain: call `settlement.hashQuote(q)` as a view and sign what it returns. |
| `RequestIdUsed` | | A `requestId` opens exactly once. Change `REQUEST_ID` in `.env` for every new trade. |
| `NotBorrower` | | `openRepo` must be sent by `q.borrower`. In `forge script`, check which key is in `vm.broadcast`. |
| `InsufficientHbar` | | The settlement contract pays for scheduled executions and is below `MIN_HBAR_PER_REPO` (30,000,000 tinybars = 0.3 HBAR). Send it more HBAR. |

Reading a selector off chain:

```
https://testnet.mirrornode.hedera.com/api/v1/contracts/results?timestamp=<consensus.timestamp>
```

`error_message` carries the 4 bytes.

---

## Reverts with NO selector and NO returndata

**This is gas, not logic. Stop decoding.**

`scheduleCall` on `0x16b` reverts with empty returndata when starved. The HIP's claim that it never
reverts covers business failures, not gas starvation. The floor for the precompile alone has been
reported at roughly 1,445,000 to 1,469,000 gas; our own `ScheduleProbe.arm()` burned 1,511,069 in
total, which is consistent with that floor plus overhead.

`openRepo` runs a cash transfer, two hold creations and a hold execution **before** reaching
`scheduleCall`, and EIP-150 forwards the precompile only 63/64 of the gas remaining at that point.
A 1.5M outer limit forwards about 1.457M, which is inside the failure band.

```bash
forge script script/TestnetFlow.s.sol --sig "openRepo()" \
  --rpc-url hedera_testnet --broadcast --gas-limit 4000000
```

If `--gas-limit` does not take, use `--gas-estimate-multiplier 300`. Hashio's `eth_estimateGas`
does not model system contract calls well, so forge's default 130% is applied to an estimate that
was already wrong.

---

## Scheduling

| Symptom | Cause and fix |
|---|---|
| `NoCapacity` / `hasScheduleCapacity` returns false | Usually the **inner** gas limit is too large. 200,000 works, 2,000,000 fails. Hedera's own tutorial uses 2,000,000; it is wrong for this. Do not raise `SCHEDULE_GAS`. It can also mean that second is saturated, which is why `_scheduleUnwind` steps the expiry forward instead of reverting the trade. |
| `hasScheduleCapacity(now+1, ...)` returns false | Reported by another team: the call conflates "saturated" with "invalid", so a near-future second reads as unavailable. Schedule further out. |
| The schedule fired but nothing changed | Read the schedule on HashScan, not the account balance. A `closeRepo` that took the no-op branch (status was not `Open`) is a successful execution that does nothing. This is correct behaviour after `repayEarly`. |
| The contract balance reads 0 in a script but the wallet shows HBAR | Units. `eth_getBalance` reports **weibar** (18 dp); `address(this).balance` inside the contract reads **tinybars** (8 dp). They differ by 1e10. `msg.value` is weibar, so `5e18` is 5 HBAR. |

---

## ATS mint and transfer rejections

| Symptom | Cause and fix |
|---|---|
| `Account 0.0.X does not have Kyc status: Granted` | Granting `ROLE_KYC` is not enough. The account needs a **registered issuer** via `addIssuer` plus a signed VC. This is why the project uses its own `TenorIdentityRegistry` instead of the Terminal3 credential path. |
| Every mint and transfer reverts on a fresh bond | ATS **requires** both an identity registry and a compliance module and ships neither. Deploy `src/periphery/` and wire both. |
| "There is no Control List in the Control tab" | There is. It is labelled **Block List**, because `isBlocklist` defaults to `true` in ATS's `CreateBond.tsx`. |
| A transfer fails and you cannot tell which gate blocked it | ATS ships `canTransferByPartition(from, to, partition, value, data) returns (bool status, bytes1 code, bytes32 reason)`. `reason` is the **selector of the blocking error**. Call it as a view before sending. |
| `createHoldFromByPartition` reverts on the real bond but not on `MockATS` | Operator authorisation. `MockATS` does not enforce it, the diamond does. Both counterparties must authorise `TenorSettlement` as an ATS operator. This is the most likely stage 2 failure. |
| A transfer to a working account fails on stage 2 only | HTS token association. A plain ERC-20 needs none, so stage 1 hides it. Set max auto-association on every demo account. |

Do not regenerate the interfaces in `src/interfaces/` from documentation. They were corrected
against the live ABI. In particular `operatorCreateHoldByPartition` **does not exist** (the real
name is `createHoldFromByPartition`) and `executeHoldByPartition` returns a **tuple**, not a bool.
Hedera and ATS documentation has been wrong in at least four places this team hit.

---

## Foundry

| Symptom | Cause and fix |
|---|---|
| Most tests fail on the signature or on the wrong caller, and the ones that pass look arbitrary | **`vm.prank` and `vm.expectRevert` apply to the next EXTERNAL call.** `_sign()` calls `settlement.hashQuote()`, so the cheatcode lands on `hashQuote` and the real call runs unpranked. Hoist the signature into a local **before** the cheatcode. The tell is that the passing tests are exactly the ones that already hoisted. |
| A test suite appears that nobody wrote, in a non-test file | A public getter whose name starts with `test` is collected by forge as a test case. Do not name state variables that way. This is why the flag is `permitAllForTestnet` and not `testnetPermitAll`. |
| `forge build` cannot find `forge-std` | The submodule is declared in `.gitmodules` but not checked out. `git submodule update --init --recursive`. `lib/` must stay out of `.gitignore`, or CI (`submodules: recursive`) goes red. |
| Stack too deep in `openRepo` | `via_ir = true` is already set in `foundry.toml`. Keep it. |
| `DocstringParsingError` | A NatSpec comment on a file-level constant. Use a plain `//` comment there. |
| A contract does not appear in Remix's deploy dropdown | An interface in the same file is selected. Pick the contract explicitly. |
| Compilation succeeds locally but the diamond rejects the call | Compiler settings must match ATS: `solc 0.8.28`, `evm_version = cancun`, optimizer on, 100 runs. A mismatch produces failures that look like permission bugs. |

---

## When the answer is not here

Search order, and it matters:

1. The ATS Solidity source at **v8.0.0** (commit `be4f860e`, released 2026-06-24). Anything written
   before that date has wrong role hashes: v8.0.0 broke storage with ERC-7201 namespacing.
2. A view call on testnet.
3. The `hedera-docs` MCP server, for leads only.

**Documentation is not a source of truth on this project.** Confirm anything load-bearing against
Solidity or against a transaction.
