# Status

**Read this file first. Update it last.** It is the only place that records what is actually
true on chain. Everything else in this repo describes what we intend; this file describes what
has been observed.

Last updated: **9 Sep 2026**, `deployAll()` and a real `openRepo()` both completed via Claude Code;
schedule `0.0.10439570` pending, expected to fire ~13:41:54 UTC.
Submission deadline: **Sun 13 Sep 2026, 12:00 EDT / 19:00 Istanbul.**

---

## How to use this file

At the **start** of a session: read the three tables below. Do not re-derive state by reading
contracts or scanning HashScan; if something is not here, it has not been proven.

At the **end** of a session, or after any testnet transaction:

1. Move anything you proved from *Unproven* to *Proven*, with the transaction or schedule id.
2. Add any new addresses to *Deployed*.
3. If a run failed, add the symptom to `.claude/skills/tenor-debug/SKILL.md`, not here.
4. Change the "Last updated" line.

An entry belongs in *Proven* only if a transaction on public testnet shows it. Passing
`forge test` is not proof of anything on this list, because `forge test` cannot reach `0x16b`
or `0x167`.

---

## Deployed on Hedera testnet

| What | Address / id | Notes |
|---|---|---|
| ATS bond | `0xc2dadb01462b766bb2f58c9638b32e97200ca07d` | issued by this team, this team holds the issuer roles |
| `ScheduleProbe` | `0x3102F4Bcba8F781B6d7cf697A5af32EE829A1438` | HIP-1215 evidence rig, rerunnable |
| `TenorIdentityRegistry` | *fill in from `.env`* | wired into the bond, without it every mint reverts |
| `TenorCompliance` | *fill in from `.env`* | same |
| `TenorSettlement` (stage 1) | `0x8f9EE0a9Aae23fDe01e12cF6A6c9F024C59D4DB9` | funded with 5 HBAR at construction; balance confirmed 500,000,000 tinybars on the mirror node |
| Mock security (stage 1) | `0xF1905080409B05590e9dADA9836F2dd612136BAE` | `MockATS`, borrower holds 100e18 QTY |
| Mock cash (stage 1) | `0xbb0Bc9B3eB630e6e1ea4df3D23DF4Dd8d285603e` | `MockERC20`, lender holds PRINCIPAL, borrower holds REPURCHASE, lender has approved settlement for max |

Addresses live in `.env`, which is gitignored. Copy them here when they stop changing, so the
next person does not have to ask for them.

---

## Proven on testnet

| Claim | Evidence |
|---|---|
| A contract can schedule its own future call through HIP-1215, and the network fires it with nobody online | schedule `0.0.10393574` |
| The drift between the requested second and execution is negligible | **134 ms** measured |
| The **calling contract** pays for the scheduled execution | ~0.12 HBAR at a 200,000 inner gas limit |
| `hasScheduleCapacity` refuses a 2,000,000 inner gas limit | 200,000 succeeds; this is why `SCHEDULE_GAS` is 200,000 |
| An ATS bond mints once our own identity registry and compliance module are wired in | bond address above |
| `address(this).balance` reads **tinybars**, not weibar | contract read `2000000000` for a 20 HBAR balance |
| Stage 1 `deployAll()` fully complete: `TenorSettlement` funded, `MockATS`/`MockERC20` deployed, lender and borrower positioned, lender's approval done | balances and allowance read back correct on testnet, see *Deployed* table above |
| **The atomic cross: `openRepo` pulling cash, creating and executing the borrower's hold, creating the return hold, and scheduling `closeRepo` all in ONE real transaction** | tx `0x6f1bb8013a99a085779fa7383ce6606f6b2a07b60cc2db73657a9d04501cf201`, status success, gas used 1,959,528 of a 4,000,000 limit. `status()` reads back `Open`, `repurchase owed` correct |
| **`scheduleCall` from inside real `openRepo` execution (not `ScheduleProbe`) succeeds well under the gas floor concern** | same tx as above. `--gas-limit 4000000` was enough with headroom to spare; the 63/64 forwarding worry from `TESTNET.md` did not bite in practice here |
| A schedule created by `openRepo` (not `ScheduleProbe`) is visible and pending on the mirror node | schedule `0.0.10439570`, `expiration_time` `1788961314` matching `maturity` exactly, `executed_timestamp: null`, `wait_for_expiry: true` |
| **Early repayment: `repayEarly()` closes the repo before maturity, cash and collateral both round-trip** | second repo `repo-2-early`, opened tx `0xa54fd7d7f300348c5443f352cb03584ff56b8793b335ebe7fa962d257a702a2b`, closed via `repayEarly()` (plain `forge script --broadcast`, no precompile in this call path so it needed none of the `cast` workaround). `status()` reads back `2` (Closed) well before its `maturity` |

---

## Unproven, in order of how badly it hurts if it is false

| # | Unknown | Why it matters | How to settle it |
|---|---|---|---|
| 2 | **What the network does when a scheduled call reverts** | `closeRepo`'s never-revert design and its two-branch structure assume: fires once, consumed, no retry | `ScheduleProbe.setShouldRevert(true)`, then `arm()`, then wait and read `status()` |
| 4 | ATS operator authorisation on the real diamond | `MockATS` does not enforce it, the real one does. Most likely stage 2 failure | stage 2 of `TESTNET.md` |
| 5 | HTS token association for the cash leg | a plain ERC-20 needs no association, so stage 1 hides this completely | stage 2 |
| 6 | Whether `forge test` is green after the cheatcode fixes | 13 of 18 were failing; the fix is committed, the run is not confirmed | `forge test` |
| 7 | **Whether `closeRepo` actually fires unattended at maturity for a *real* `openRepo`-created schedule** | item 1/3 (below) proved `openRepo` schedules correctly; this is the other half — nobody has watched one fire yet outside `ScheduleProbe` | wait for schedule `0.0.10439570` (repo `repo-1`, still Open) to reach `executed_timestamp`, expected ~13:41:54 UTC 9 Sep 2026, then re-run `status()` |
| 8 | **Whether an orphaned schedule (repo already closed by `repayEarly`) really fires and does nothing, as the never-revert design assumes** | this is the specific claim `TESTNET.md` step 6 asks you to film | wait for schedule `0.0.10439736` (repo `repo-2-early`, already Closed) to reach `executed_timestamp`, expected ~13:51:46 UTC 9 Sep 2026, confirm `status()` still reads `2` and nothing reverted |

Items 1 and 3 from this list are now **Proven**, below — settled 9 Sep 2026.

---

## Built but not deployed

- `src/TenorSettlement.sol` — the whole project. RFQ with EIP-712 signed quotes, `openRepo`,
  `closeRepo`, `repayEarly`, `cancelQuote`, `sweep`.
- `test/TenorSettlement.t.sol` — 18 tests. Written to double as the testnet runbook: each test
  documents what is mocked and what replaces it on chain.
- `script/TestnetFlow.s.sol` — one entrypoint per step, 15 minute term so a schedule can be watched.
- `src/periphery/` — identity registry and compliance module, deployed and wired.
- `src/mocks/` — `MockATS`, `MockERC20`.

## Not started

- `services/hcs/` — the off-chain audit trail. Owner Parsa. Not on the critical path.
- The thin UI. Owner Parsa.
- The video. Owner Mhd.

---

## Decisions that are closed

Do not reopen these. The reasoning is in `IMPLEMENTATION_PLAN.md` section 5, and reopening one
costs a day we do not have.

Foundry, not Hardhat. RFQ with signed quotes, not an order book or a matching engine. USDC as the
cash leg, not HBAR. HCS off-chain, not in the contract. No price oracle and no margin call. The
repo rate is a trade input, not a mechanism. Liquidation is the default branch of `closeRepo`, not
a separate engine.
