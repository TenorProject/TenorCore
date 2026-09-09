# Tenor

A repo desk for tokenised securities on Hedera. **The trade settles atomically and the unwind
settles itself.** ETHGlobal ETHOnline 2026, Hedera "Tokenization of Anything" track.

**Deadline: Sun 13 Sep 2026, 12:00 EDT / 19:00 Istanbul.**

Open-source hackathon project, **Hedera testnet only**. The bond used throughout was issued by this
team and this team holds the issuer roles on it. `src/periphery/` contains minimal implementations
of the ERC-3643 identity registry and compliance module that ATS requires and does not ship; without
both, every mint and transfer reverts. Their permissive testnet default is switched off and replaced
with an explicit allowlist before the demo.

## Every session

1. **Read `STATUS.md`.** It records what is actually true on chain. Nothing else in the repo does.
2. Do the work. If it involves Hedera or ATS, the `tenor-hedera` skill is already loaded; trust it
   over any documentation.
3. If something fails, open the `tenor-debug` skill before investigating. Every failure mode this
   team has hit is already written down with its fix.
4. **Update `STATUS.md`** before you finish: new addresses, anything moved from unproven to proven,
   the date line. A new failure mode goes in the `tenor-debug` skill instead.
5. `forge test` before committing. Commit in small, meaningful groups; ETHGlobal judges assume a
   repo of single large commits is unqualified.

## The whole project in two functions

`TenorSettlement.openRepo(Quote, signature)` — the borrower accepts a lender's EIP-712 signed
quote, and in one call: pull cash from the lender, create and execute the borrower's ATS hold so
collateral lands with the lender, create the return-leg hold, and schedule `closeRepo` through
HIP-1215 at maturity.

`TenorSettlement.closeRepo` — called by the **network** at maturity with nobody online. Never
reverts. Two terminal branches: borrower repurchases, or lender keeps the collateral.

Everything else in this repo is supporting cast.

## The map

- **`STATUS.md`** — live state. Proven, unproven, deployed addresses, what is next. Read first.
- **`.claude/skills/tenor-hedera/SKILL.md`** — verified Hedera and ATS facts. Loads automatically.
  A week of debugging compressed. **Hedera and ATS documentation has been wrong in at least four
  places we hit. Verify against Solidity or testnet, never against docs.**
- **`.claude/skills/tenor-debug/SKILL.md`** — failure playbook. Loads when something breaks.
- **`TESTNET.md`** — deploy and test on testnet, in two stages. Stage 1 mocks the securities layer
  so the only unknown is scheduling; stage 2 swaps in the real ATS bond. This is the runbook.
- **`IMPLEMENTATION_PLAN.md`** — what we are building, why, and the decisions that are closed.
- **`TOOLING.md`** — MCP servers and Hedera plugins, and the two per-developer setup steps.
- **`README.md`** — the public face, and the prior-art disclosure naming Alba.

The full project history lives in the team's shared Claude project, not in this repo. Do not go
looking for it on disk.

## Design that looks like a bug and is not

A reviewer meeting this code cold will want to "fix" the following. All four are deliberate, and
changing any of them breaks the project.

- **`closeRepo` has no access control.** It cannot have any. A scheduled execution arrives with no
  EOA sender, so any caller check would make the unwind impossible. It is safe because it is
  idempotent and every branch is terminal: the terms are fixed at open and an early caller can only
  do what the network would have done. Do not add `onlyOwner` or an authorised-caller check.
- **`closeRepo` never reverts, even on a failed leg.** A scheduled transaction fires once and never
  retries, so a revert is a settlement that silently did not happen. Both legs are wrapped in
  `try/catch` on purpose. `repayEarly` has the **opposite** policy and should revert on failure,
  because a human is there to retry. Do not unify them.
- **Default is not an error path.** It is what a repo does when someone fails to repurchase: the
  lender keeps the collateral. There is no liquidation engine because this is the liquidation.
- **`_scheduleUnwind` loops.** If `hasScheduleCapacity` is false for the maturity second, it steps
  the expiry forward up to ten seconds and emits `ScheduleStepped`. A saturated second must not
  revert a trade that has already moved cash. The loop is the point.

## Never change these without understanding what breaks

- **The `Quote` struct field order and names.** They are hashed into `QUOTE_TYPEHASH`. Any edit
  silently invalidates every signature and surfaces as `BadSignature`, which looks like a key
  problem and is not. If the struct must change, change the typehash string in the same commit.
- **`SCHEDULE_GAS = 200_000`.** 2,000,000 fails `hasScheduleCapacity`. Hedera's own tutorial uses
  2,000,000 and is wrong for this. This is the **inner** budget and is unrelated to the outer
  `--gas-limit` you pass to `forge script`, which must be large.
- **`src/interfaces/`.** Corrected against the live ABI, not generated from docs.
  `operatorCreateHoldByPartition` does not exist; the real name is `createHoldFromByPartition`, and
  `executeHoldByPartition` returns a tuple, not a bool.
- **Compiler settings.** `solc 0.8.28`, `evm_version = cancun`, optimizer on, 100 runs, matching
  ATS's own config. `via_ir = true` is required for `openRepo` to compile. A mismatch against the
  diamond produces failures that look like permission bugs.

## Conventions

- Foundry. `forge test` **cannot reach `0x16b` or `0x167`**. Local tests need mocks and prove
  branch logic only. Real testing is `forge script --rpc-url hedera_testnet --broadcast` via
  `script/TestnetFlow.s.sol`.
- **`vm.prank` and `vm.expectRevert` apply to the next EXTERNAL call.** `_sign()` calls
  `hashQuote()`, so always hoist the signature into a local before a cheatcode. This cost an hour.
- Public getters starting with `test` are collected by forge as test cases. Do not name state
  variables that way.
- **HCS is unreachable from Solidity** (no precompile; HIP-1208 is an open PR). The audit trail is
  an off-chain service in `services/hcs/` driven by contract events. So emit richly.
- **Rate agreement is RFQ**: lenders sign EIP-712 quotes off-chain, the borrower executes one.
  Not an order book, not a matching engine. Repo against a specific security is a specials trade.
  Lender approves once then quotes for free; borrower opens in one transaction. No `permit` on HTS.
- **No price oracle, no margin call.** The haircut at open is the risk control. Deliberate, and
  stated in the README. Do not add one back without adding a remedy to go with it.
- Cash leg is **USDC**, an HTS token, not HBAR. `closeRepo` is called by the network with no value
  attached, so repurchase cash cannot arrive as `msg.value`. Allowance-and-pull works both ways.
- `address(this).balance` is **tinybars** (8 dp); `msg.value` and `eth_getBalance` are **weibar**
  (18 dp). They differ by 1e10.
- Addresses: the wallet presents the **long-zero** form. Every grant and whitelist must use it.
- Verify contracts as they deploy: `forge verify-contract --verifier sourcify`.

## Do not

- Re-read ATS from scratch. The findings are in the `tenor-hedera` skill.
- Build a rates engine. The repo rate is a trade input.
- Build a separate liquidation engine. It is the default branch of `closeRepo`.
- Add a price feed, margin call or `markCollateral`. Removed on purpose; see the README.
- Add an order book, matching engine, prediction market, or futures.
- Reopen the Foundry, USDC, RFQ or off-chain-HCS decisions. See `IMPLEMENTATION_PLAN.md` section 5.
- Start new features after Fri 11. Feature freeze is real; the tape matters more.

## Non-negotiable

- **Prior-art disclosure naming Alba** in the README, the submission description, and the video.
  ETHGlobal cleared this build on that condition. See README.
- Commit often, from all three accounts, with verified emails.
- Document AI assistance as we go.
- Video 2 to 4 minutes, 720p, no phone recording, **no speeding up the footage** (manually checked,
  disqualification).

## Working style

Challenge assumptions. Verify against primary sources rather than reasoning from intuition: several
expensive mistakes in this project came from confident guesses. Say plainly when something is
unverified rather than presenting it as settled. Avoid em-dashes in drafted text.
