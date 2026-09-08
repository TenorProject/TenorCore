# Tenor

A repo desk for tokenised securities on Hedera. **The trade settles atomically and the unwind
settles itself.** ETHGlobal ETHOnline 2026, Hedera "Tokenization of Anything" track.

**Deadline: Sun 13 Sep 2026, 12:00 EDT / 19:00 Istanbul.**

## The whole project in two functions

`TenorSettlement.openRepo` — in one call: pull cash from the lender, execute the borrower's ATS
hold so collateral lands with the lender, create the return-leg hold, and schedule `closeRepo`
through HIP-1215 at maturity.

`TenorSettlement.closeRepo` — called by the **network** at maturity with nobody online. Never
reverts. Two terminal branches: borrower repurchases, or lender keeps the collateral.

Everything else in this repo is supporting cast.

## Read these before working

- **`.claude/skills/tenor-hedera/SKILL.md`** — verified Hedera and ATS facts. Loads automatically.
  A week of debugging compressed. **Hedera and ATS documentation has been wrong in at least four
  places we hit. Verify against Solidity or testnet, never against docs.**
- **`IMPLEMENTATION_PLAN.md`** — build plan, file layout, day-by-day schedule.
- **`TOOLING.md`** — MCP servers and Hedera plugins, and the two per-developer setup steps.

## State

**Proven:** HIP-1215 scheduled contract calls work. Schedule `0.0.10393574` executed **134 ms**
past its target second, paid by the contract, ~0.12 HBAR at 200k gas. `ScheduleProbe` is in the
repo and rerunnable.

**Working:** an ATS bond exists on testnet (`0xc2dadb01462b766bb2f58c9638b32e97200ca07d`) with our
own identity registry and compliance module wired in, and it mints.

**Not yet built or tested, and it is the whole project:** `TenorSettlement.openRepo` doing the
atomic cross. One contract call that pulls USDC through the ERC-20 facade *and* executes an ATS
hold has never run. That is the highest-risk unknown.

**Still unanswered:** what the network does when a scheduled call reverts. `ScheduleProbe` has a
`shouldRevert` flag built for exactly this. The two-branch design of `closeRepo` depends on it.

## Conventions

- Foundry. `solc 0.8.28`, `evm_version = cancun`, optimizer 100 runs, matching ATS's own config.
- `forge test` **cannot reach `0x16b` or `0x167`**. Local tests need mocks and prove little. Real
  testing is `forge script --rpc-url hedera_testnet --broadcast` only.
- **HCS is unreachable from Solidity** (no precompile; HIP-1208 is an open PR). The audit trail is
  an off-chain service in `services/hcs/` driven by contract events. So emit richly.
- Cash leg is **USDC**, an HTS token, not HBAR. `closeRepo` is called by the network with no value
  attached, so repurchase cash cannot arrive as `msg.value`. Allowance-and-pull works both ways.
- `address(this).balance` is **tinybars** (8 dp); `msg.value` is **weibar** (18 dp).
- Addresses: the wallet presents the **long-zero** form. Every grant and whitelist must use it.
- Verify contracts as they deploy: `forge verify-contract --verifier sourcify`.

## Do not

- Re-read ATS from scratch. The findings are in the skill file.
- Build a rates engine. The repo rate is a trade input.
- Build a separate liquidation engine. It is the default branch of `closeRepo`.
- Add an order book, matching engine, prediction market, or futures.
- Raise the scheduled gas limit above 200_000. 2_000_000 fails `hasScheduleCapacity`.

## Non-negotiable

- **Prior-art disclosure naming Alba** in the README, the submission description, and the video.
  ETHGlobal cleared this build on that condition. See README.
- Commit often, from all three accounts, with verified emails. Single large commits are assumed
  unqualified by the judges.
- Document AI assistance as we go.
- Video 2 to 4 minutes, 720p, no phone recording, **no speeding up the footage** (manually checked,
  disqualification).

## Working style

Challenge assumptions. Verify against primary sources rather than reasoning from intuition: several
expensive mistakes in this project came from confident guesses. Avoid em-dashes in drafted text.
