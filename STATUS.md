# Status

**Read this file first. Update it last.** It is the only place that records what is actually
true on chain. Everything else in this repo describes what we intend; this file describes what
has been observed.

Last updated: **9 Sep 2026**, by Mhd.
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
| `TenorSettlement` | **not deployed** | this is the next thing to change |
| Mock security (stage 1) | not deployed | `MockATS`, printed by `deployAll()` |
| Mock cash (stage 1) | not deployed | `MockERC20`, printed by `deployAll()` |

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

---

## Unproven, in order of how badly it hurts if it is false

| # | Unknown | Why it matters | How to settle it |
|---|---|---|---|
| 1 | **One contract call doing an ERC-20-facade cash transfer and an ATS hold execution together** | this is the atomic cross. It is the entire project and it has never run | stage 1 of `TESTNET.md`, step 3 |
| 2 | **What the network does when a scheduled call reverts** | `closeRepo`'s never-revert design and its two-branch structure assume: fires once, consumed, no retry | `ScheduleProbe.setShouldRevert(true)`, then `arm()`, then wait and read `status()` |
| 3 | **The gas floor for `scheduleCall`** | reported by another team at ~1.45M, not verified by us. If real, an under-gassed `openRepo` reverts with empty returndata | run `openRepo` with `--gas-limit 4000000` and read the actual gas used from the mirror node |
| 4 | ATS operator authorisation on the real diamond | `MockATS` does not enforce it, the real one does. Most likely stage 2 failure | stage 2 of `TESTNET.md` |
| 5 | HTS token association for the cash leg | a plain ERC-20 needs no association, so stage 1 hides this completely | stage 2 |
| 6 | Whether `forge test` is green after the cheatcode fixes | 13 of 18 were failing; the fix is committed, the run is not confirmed | `forge test` |

**Item 1 and item 2 are both answerable today and neither needs anything built.** Do them before
writing any new Solidity.

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
