---
name: tenor-hedera
description: Hard-won facts about Hedera, Asset Tokenization Studio v8.0.0 and HIP-1215 scheduled calls, verified against source code and testnet during the Tenor build. Load before writing or debugging any Solidity, script or service in this repo, and before trusting Hedera or ATS documentation.
---

## Context for this repository

Tenor is an open-source hackathon project for ETHGlobal ETHOnline 2026, running entirely on
**Hedera testnet**. The bond used throughout was issued by this team, on testnet, and this team
holds the issuer roles on it. Everything below is integration knowledge about Hedera's own
Asset Tokenization Studio, gathered while building a settlement layer on top of it, and was
verified against the published open-source contracts at v8.0.0 or measured on public testnet.

`TenorIdentityRegistry` and `TenorCompliance` in `src/periphery/` are minimal implementations of
two interfaces ATS **requires**: an ERC-3643 identity registry and compliance module. Without both,
every mint and transfer of an ATS security reverts. ATS ships neither, and its production
credential path depends on issuer infrastructure that is not available for a testnet demo. Their
permissive `permitAllForTestnet` flag is a development default for a token we issued ourselves; it is
switched off and replaced with an explicit two-address allowlist before the demo, so that the
compliance rejection is a real one.

# Tenor: verified Hedera and ATS facts

Everything here was confirmed against ATS source at v8.0.0 (commit `be4f860e`, 2026-06-24) or
measured on Hedera testnet. **The official docs are wrong in at least four documented places.
Verify against Solidity, not documentation.**

## Build settings

`solc 0.8.28`, `evm_version = "cancun"`, optimizer on, `optimizer_runs = 100`. These match ATS's
own hardhat config. Mismatched settings against a diamond produce failures that look like
permissions bugs.

## What Solidity can and cannot reach

| Service | Reachable? | How |
|---|---|---|
| HTS (tokens, USDC) | Yes | System contract `0x167`, HIP-206, ERC-20 facade |
| Schedule Service | Yes | System contract `0x16b`, HIP-1215 |
| **HCS (consensus topics)** | **No** | No precompile. HIP-1208 is an open PR. Needs a Hedera SDK service. |

`forge test` cannot reach `0x167` or `0x16b`. Local tests need mocks and prove very little.
Real testing is `forge script --rpc-url hedera_testnet --broadcast` only.

## HIP-1215, measured on testnet

```solidity
address constant HSS = address(0x16b);
function scheduleCall(address to, uint256 expirySecond, uint256 gasLimit, uint64 value, bytes callData)
    external returns (int64 responseCode, address scheduleAddress);
function hasScheduleCapacity(uint256 expirySecond, uint256 gasLimit) external view returns (bool);
```

- Response code **22** is SUCCESS.
- **gasLimit 200_000 works. 2_000_000 fails `hasScheduleCapacity`** — there is a per-second
  capacity ceiling. Hedera's own tutorial suggests 2_000_000; it is not universally safe.
- **The calling contract is the payer**, not the caller. It must hold HBAR.
- Cost: ~0.12 HBAR (12,002,340 tinybar) per scheduled execution at 200k gas.
- Scheduling costs ~1.5M gas at call time.
- Measured drift: **134 ms** past the requested second (schedule `0.0.10393574`).
- Check `hasScheduleCapacity` first and **step the expiry forward on failure**, never revert the
  surrounding trade.
- A scheduled target has **no EOA sender**, so it cannot have access control.
- A scheduled transaction **fires once and never retries**. A revert is a settlement that silently
  did not happen.

## Gas floor on scheduleCall, and the 63/64 rule

`scheduleCall` **reverts with empty returndata when starved of gas**. The HIP's "never reverts"
covers business failures, not gas starvation, so a failure here gives you no reason string at all.

Another team measured the floor for the precompile itself at **1,445,312 to 1,468,750 gas**,
independent of the gas requested for the *scheduled* call. Our own `ScheduleProbe.arm()` used
**1,511,069** total, which is consistent with that floor plus a little overhead, so treat the number
as credible.

EIP-150's 63/64 rule matters here: an outer limit of 1.5M hands the precompile only ~1.457M, which
is inside the failure band. Any transaction that calls `scheduleCall` and also does other work
(`openRepo` does a cash transfer, two hold creations and a hold execution) needs a **generous outer
gas limit, 3,000,000 or more**. Hedera's per-transaction ceiling is 15M, so there is room.

## Units: a ten-order-of-magnitude mismatch

- `address(this).balance` returns **tinybars** (8 decimals). 20 HBAR reads as `2000000000`. We
  measured this directly.
- `msg.value` on a payable call arrives in **weibar** (18 decimals).
- `eth_getBalance` over JSON-RPC also reports **weibars**, so a script reading a balance and the
  contract reading its own balance disagree by 1e10. Reported by another team; consistent with ours.
- `address(this).balance >= 5 ether` can therefore never be true in a Hedera contract. The
  dangerous mirror image is a threshold set too LOW, which passes trivially and leaves an
  underfunded contract whose scheduled call silently never fires.

## Address forms

A Hedera account has two EVM representations and contracts treat them as different addresses:
the **long-zero** form (`0x00000000000000000000000000000000009d85a4` for `0.0.10323364`) and an
ECDSA alias. MetaMask here presents **long-zero**. Every role grant, whitelist entry and registry
entry must use the exact form the wallet presents.

## Asset Tokenization Studio v8.0.0

**ATS has no cash leg.** Zero `payable` functions across 104 facets, no `msg.value`, no
`IHederaTokenService` import anywhere. ATS tokens cannot receive or move value. The cash side is
entirely ours. Copy the pattern from Mass Payout's `LifeCycleCashFlow.sol` (`associateToken` + `IERC20`).

**ATS ships no DvP, no atomic swap, no HTLC.** `docs/ats/user-guides/hold-operations.md` describes a
DvP flow using a "lock hash" and recommends it for HTLCs. **There is no lock hash.** No hash field on
the `Hold` struct, no hash-lock fields exist anywhere in the Solidity. Do not plan around it.

**Holds are the settlement primitive.**
```solidity
struct Hold { uint256 amount; uint256 expirationTimestamp; address escrow; address to; bytes data; }
```
- Tokens stay in the holder's account, moving from available to held balance.
- Only the `escrow` may execute or release. Partial execution is supported.
- **`to = address(0)` gives an open-destination hold**: the escrow names the recipient at settlement
  time. This is what makes holds usable for settlement.
- Expiration is mandatory. **After expiry anyone can permissionlessly reclaim to the holder.**
  Always assert hold expiry outlives any schedule that depends on it.

**Hold function names, verified against the live diamond** (the earlier guesses were wrong):
`createHoldFromByPartition(bytes32 partition, address from, Hold hold, bytes operatorData)` is the
operator-side creator. There is no `operatorCreateHoldByPartition`. And
`executeHoldByPartition(HoldIdentifier, address to, uint256 amount)` returns
`(bool success_, bytes32 partition_)`, not a bare bool.

**No EIP-2612 `permit` on HTS tokens.** HIP-376 gives `approve`, `allowance` and `transferFrom`
through the ERC-20 facade and nothing more. The facade is network-provided, so you cannot add
`permit`. Any signature-based flow still needs one on-chain approval per spender.

**Clearing is a global mutually-exclusive mode (a configuration constraint).** While active, normal transfers, redeems, hold
creation *and maturity redemption* all revert. Do not enable it.

**Compliance chain, in the order it fails:**
```solidity
verifyKycStatus = (!internalKycActivated || status == GRANTED) && isExternallyGranted(...)
```
The external branch is ANDed **unconditionally**; the internal setting alone does not determine the outcome. Zero
external lists passes vacuously. Then `_validateIdentifiedAccount` staticcalls the identity registry.

- **`isVerified(address)` is the only function ATS ever calls on the identity registry**, in one place.
  An **empty return passes**; only a failed call reverts.
- `ICompliance` needs `transferred`, `created`, `destroyed`, `canTransfer`, called from eight places
  via `functionCall` (state-changing). **These hooks must never revert.**
- `setIdentityRegistry` and `setCompliance` need **`ROLE_TREX_OWNER`**, not `DEFAULT_ADMIN_ROLE`.
- The bond creation form accepts any address as Identity Registry with no interface check. Pasting an
  external KYC list there gives `IdentityRegistryCallFailed()` `0xad87849e` on every mint, and the
  same mistake on the compliance slot gives `ComplianceCallFailed()` `0x67fba102`.

**`getTotalSecurityHolders` is not monotonic.** It decrements via `removeTokenHolder` when a holder's
total balance hits zero. But total = available + locked + **held**, so an address with tokens in an
unexecuted hold still occupies a register slot.

**Role hashes** (all changed in v8's ERC-7201 migration; anything predating 2026-06-24 is wrong):
```
ROLE_KYC                   0x754f499f9fdfbb089d12bdec817a6863d593d8a3ea7f546c00a5cafd20957bfc
ROLE_INTERNAL_KYC_MANAGER  0xdd78fdcd1b38a5360405cef8d91e758ad0f42bf2ced681b803b3c2704b0a32a7
ROLE_KYC_MANAGER           0xec811504e835acf29535b5b62307b08000468f0c61ca6163ed6f17a03629b91e
ROLE_CONTROL_LIST          0x6ed9a91e996c6475ecdc28ecbdbe9bd1122fc62b30cdbe6da8271884b51ec74d
ROLE_TREX_OWNER            0xd9e1264632ee9a37e8673a0c55a0a1d8b38c758e843084168ee08cd2d1f7e6f0
```

## Cash leg

USDC is native on Hedera as an **HTS token** issued by Circle. Reached from Solidity via the ERC-20
facade. Accounts must be **associated** before receiving; set max auto-association on demo accounts.

Use USDC rather than HBAR for a mechanical reason: `closeRepo` is called by the network with **no
value attached**, so repurchase cash cannot arrive as `msg.value`. Allowance-and-pull works in both
directions.

## Solidity notes from this project

- A file-level constant cannot carry NatSpec. `///` or `/**` above one gives
  `DocstringParsingError: Documentation tag @notice not valid for file-level variables`. Use `//`.
- NatSpec binds to the **next declaration**, so a header block above a file-level constant lands on it.

## Live testnet addresses

```
account         0.0.10323364  / 0x00000000000000000000000000000000009d85a4 (long-zero)
ATS bond        0.0.10391608  / 0xc2dadb01462b766bb2f58c9638b32e97200ca07d
ScheduleProbe   0.0.10393539  / 0x3102F4Bcba8F781B6d7cf697A5af32EE829A1438
proven schedule 0.0.10393574
```

## Verification

HashScan uses Sourcify and Hedera runs its own instance:
`forge verify-contract --verifier sourcify`. Verifying contracts is a stated prize requirement.


## Reported by other teams, not independently verified

Credible and consistent with what we have measured, but we have not reproduced these ourselves.
Verify before relying on any of them.

**A HAPI `CryptoTransfer` credits a contract's balance without running its code.** An EVM transfer
to the same contract runs `receive()`; a HAPI-level transfer does not, and still reports SUCCESS.
Consequence for us: our `Funded` event will not fire if someone tops the contract up from a wallet
rather than through the EVM. Do not use that event to track the HBAR float; read the balance.

**A rejected `deleteSchedule` is a silent no-op.** Transaction status comes back SUCCESS and the
refusal exists only in the returned `int64`. This is the same pattern as every Hedera system
contract, and it is why we check `rc != HEDERA_SUCCESS` after `scheduleCall`. If we ever add
`deleteSchedule` on early repayment, it must check the return code too. Reportedly Hedera's own
payments-scheduler template discards it.

**Schedule delete authorisation.** The schedule's `admin_key` is the *creating contract's*
ContractID. An unrelated EOA, an unrelated contract, and even the deploying EOA of the owning
contract all get `INVALID_SIGNATURE`. If true this is a useful property: only the contract that
created a schedule can cancel it.

**`hasScheduleCapacity(now + 1)` returns false** despite the HIP stating a one-second minimum, and
`false` conflates "this second is saturated" with "this expiry is invalid". Our `_scheduleUnwind`
loop treats false as retryable and steps forward, which is safe but would waste all ten iterations
on a permanently invalid expiry before reverting `NoScheduleCapacity`.

**x402 on Hedera cannot settle into a contract call.** `@x402/hedera` builds only a
`TransferTransaction`, and the facilitator rejects anything else with
`invalid_exact_hedera_payload_contains_non_transfer_ops`. Not relevant to Tenor, which does not use
x402, but it rules out escrow-on-receipt for anything on that rail.
