<p align="center">
  <img src="tenor-logo.svg" alt="Tenor" width="104" />
</p>

<h1 align="center">Tenor</h1>

<p align="center">
  <b>Lending protocol for tokenised securities on Hedera.<br/>
  The trade settles atomically, and the unwind settles itself.</b>
</p>

<p align="center">
  ETHGlobal ETHOnline 2026 · Hedera "Tokenization of Anything" · Privy
</p>

<p align="center">
  <a href="https://tenor-develop.up.railway.app/market">Live demo</a> ·
  <a href="https://x.com/tenor_protocol">@tenor_protocol</a>
</p>

---

## The problem

Hedera's Asset Tokenization Studio issues real, compliance-gated securities. It **cannot settle
them against money**. There are zero `payable` functions across its 104 facets, no
delivery-versus-payment, and no atomic swap. Its own documentation describes a DvP flow built on a
"lock hash" that does not exist anywhere in the code.

So a bond issued through ATS can be minted, transferred and frozen, but it cannot be traded against
cash in one transaction. Tenor is that missing settlement layer.

## What it does

A borrower posts a tokenised bond as collateral and receives USDC. The price is set off-chain first: the borrower posts a funding request, lenders answer with signed EIP-712 quotes at zero gas, and the borrower picks the one they want.

That choice triggers openRepo, one transaction that does everything at once: cash moves from lender to borrower, the bond goes into escrow, and the maturity unwind is scheduled as a HIP-1215 call in the same breath. This solves the two hard parts of a repo trade on-chain. The open is atomic, so neither side is ever exposed. The close happens on the date without a keeper, a cron job, or a clearinghouse standing in the way.

From there the borrower has two paths. Repay early with repayEarly, and the bond comes straight back. Or let maturity hit, and the scheduled close fires itself, transferring the collateral to the lender. Nobody runs it, nobody can forget it, nobody pays for it but the contract itself.

## Deployed on Hedera testnet

| What | Address |
|---|---|
| **`TenorSettlement`** | [`0x9198Bc6E73F7310Dd2D7160cB91A0937c75ebc22`](https://hashscan.io/testnet/contract/0x9198bc6e73f7310dd2d7160cb91a0937c75ebc22) · `0.0.10475244` |
| ATS bond (collateral) | [`0xc2dadb01462b766bb2f58c9638b32e97200ca07d`](https://hashscan.io/testnet/contract/0xc2dadb01462b766bb2f58c9638b32e97200ca07d) · `0.0.10391608` |
| USDC (cash leg) | `0.0.429274` (EVM: `0x0000000000000000000000000000000000068cda`) |
| `ScheduleProbe` | [`0x3102F4Bcba8F781B6d7cf697A5af32EE829A1438`](https://hashscan.io/testnet/contract/0x3102F4Bcba8F781B6d7cf697A5af32EE829A1438) |

## Proven on Hedera testnet

Every row is a public transaction against the **real ATS bond and real USDC**.

| What | Evidence |
|---|---|
| **Atomic open**: cash and collateral cross in ONE transaction | tx [`0x698e9c3e…01bcfc`](https://hashscan.io/testnet/transaction/0x698e9c3e9a6cea3509c38573004ae86a1c011881c1b14adca45185a2bb01bcfc), `SUCCESS`, 2,007,269 gas |
| **Early repayment**: cash to the lender, collateral out of escrow, in one call | tx [`0x8c6e16c5…0140e0`](https://hashscan.io/testnet/transaction/0x8c6e16c5860075a34b9bc0124d99521b79eee21552722a2d978680d4eb0140e0), `SUCCESS`, 303,658 gas |
| **The network executed our unwind with nobody online** | schedule `0.0.10474468`, `executed_timestamp` `1789123560.025816284` |
| Drift from the requested second | **25.8 ms** |
| The scheduled execution succeeded, it did not revert | `result: SUCCESS`, `scheduled: true` |
| **The contract paid its own settlement fee** | 0.0503 HBAR debited from the contract, no user transaction |
| Independent HIP-1215 measurement | `ScheduleProbe`, schedule `0.0.10393574`, 134 ms |

The default branch is the one worth understanding. At maturity, with the borrower unfunded, the
network calls `closeRepo`, which checks funding before moving anything, marks the repo `Defaulted`,
and transfers the escrowed collateral to the lender in the same call. A scheduled transaction fires
once and never retries, so the contract is written to never revert here: default is a business
outcome, not an error. If that transfer itself fails, for example a compliance check blocking the
lender, the repo still finalizes as `Defaulted` rather than reverting, and delivery can be retried
permissionlessly through `claimCollateral`. <!-- TODO: cite a fresh default tx hash against the
current deployment here before submitting -->

## How the sponsors are used

### Hedera

**[`TenorSettlement.openRepo`](https://github.com/TenorProject/TenorCore/blob/83c68b0/src/TenorSettlement.sol#L226-L299)**

One function, three Hedera services, reached three different ways:

- **Asset Tokenization Studio** issues the collateral, an ERC-3643 / ERC-1400 bond we minted
  ourselves on testnet, and enforces compliance on every movement. ATS requires an identity
  registry and a compliance module and **ships neither**, so `src/periphery/` implements both.
  Without them every mint and transfer reverts.
- **HTS** carries the cash leg through the ERC-20 facade at `0x167`. There is no EIP-2612 `permit`
  on HTS, so the whole approval flow is designed around a single standing allowance per side.
- **Schedule Service (HIP-1215)** at `0x16b` is why this exists on Hedera and nowhere else.
  `scheduleCall` runs inside the same transaction that opens the trade.

### Privy

**[`providers.tsx`](https://github.com/TenorProject/tenor-app/blob/main/src/app/providers.tsx)**

Privy is how both counterparties reach the product. The lender signs an EIP-712 quote off-chain and
sends **zero transactions**, so the signing surface is the product, and Privy makes it reachable by
someone who has never held a wallet. We also convert Privy's raw secp256k1 key into Hedera's
DER-encoded hex so a user can import the same account into HashPack and is never locked into us.

## Design decisions worth defending

**Price discovery is RFQ, not an order book.** Lending against a *specific* security is a specials
trade, which is why Tradeweb and BrokerTec negotiate them rather than matching them. Lenders sign a
12-field EIP-712 quote off-chain; the borrower executes the one they accept in one transaction.
Terms are bound by the signature, so nothing can be substituted or re-priced in flight.

**No price oracle and no margin call.** Deliberate, not skipped. A margin call is only meaningful
if there is a remedy, and here there is none: collateral is fixed at open and escrowed for the
term. The haircut agreed at open is the risk control, which is how bilateral term lending actually
works. Nothing reliably prices a bond minted last week; pretending otherwise would be the weaker
design and there would be a feed to manipulate.

**Liquidation is the default branch of `closeRepo`, not an engine.**

**Compliance is enforced by the token itself.** A counterparty outside the identity registry cannot
take delivery, because the transfer reverts inside ATS. Not a check in our UI.

**The collateral is escrowed by the contract**, not delivered to the lender. One approval per side,
no ERC-1400 hold lifecycle to manage. This is a collateralised loan, not a true-sale repurchase
agreement, and we describe it as such.

## Architecture

```
lender ──signs EIP-712 quote (no transaction)──┐
                                               ▼
borrower ──openRepo()──►  TenorSettlement  ──► cash   lender → borrower      (HTS, 0x167)
                                           ──► bond   borrower → escrow      (ATS diamond)
                                           ──► scheduleCall(closeRepo, maturity)  (0x16b)
                                                        │
                          ... term passes, nobody online ...
                                                        ▼
                         Hedera executes closeRepo:  repaid → bond back to borrower
                                                     unpaid → bond to lender
```

The audit trail runs off-chain in the app, submitting contract events to an HCS topic. HCS has no
Solidity precompile (HIP-1208 is still an open PR), so it cannot be written from the contract.

## Repo

| Path | What |
|---|---|
| `src/TenorSettlement.sol` | The settlement contract. Open, close, early repayment, recovery. |
| `src/interfaces/` | Hand-written ATS and HIP-1215 interfaces, verified against the live ABI. |
| `src/periphery/` | The identity registry and compliance module ATS requires and does not ship. |
| `src/probe/ScheduleProbe.sol` | HIP-1215 evidence rig. Rerunnable. |
| `test/TenorSettlement.t.sol` | 29 tests, written to double as the testnet runbook. |
| `script/TestnetFlow.s.sol` | Step-by-step testnet walkthrough, one entrypoint per step. |
| `TESTNET.md` | Deploy and test on Hedera testnet, in two stages. |
| `STATUS.md` | What is deployed and what is proven, with transaction ids. |

Front end and HCS audit trail: **[TenorProject/tenor-app](https://github.com/TenorProject/tenor-app)**

## Build

```bash
forge build
forge test
```

`forge test` cannot reach `0x16b` or `0x167`, so a green suite proves branch logic and nothing
about Hedera. The integration is proven on testnet only; see **[TESTNET.md](TESTNET.md)**.

## AI assistance

Claude was used throughout, across both repos, in three concrete ways:

- **Research and drafting.** Hedera and ATS behavior researched via Claude Code with the official
  Hedera MCP servers (`hedera-docs`, `hedera-testnet`), then verified against the live ATS v8.0.0
  Solidity or a real testnet transaction before anything was trusted. The Hedera docs got several
  things wrong (the lock-hash DvP flow, clearing-mode irreversibility, hold expiration semantics);
  see `TOOLING.md` and `.claude/skills/tenor-hedera/SKILL.md` for the specifics.
- **Autocompletion during implementation.** Standard inline completion while writing Solidity,
  scripts, and the frontend.
- **Debugging.** Used to narrow down failures during testnet integration, particularly around
  ATS compliance reverts and schedule service call encoding.

Every architectural decision (RFQ over an order book, no oracle, bond over equity, dropping the
ATS hold model for direct escrow) was made and is defended by the team; see "Design decisions
worth defending" above. `CLAUDE.md`, `IMPLEMENTATION_PLAN.md`, `STATUS.md`, and `.claude/skills/`
are committed in full and track the actual verified state of the project, not a plan written and
abandoned. Judges are welcome to read them.

## Licence

See LICENSE.