<p align="center">
  <img src="tenor-logo.svg" alt="Tenor" width="104" />
</p>

<h1 align="center">Tenor</h1>

<p align="center">
  <b>Compliance-gated lending against tokenised securities on Hedera.<br/>
  The trade settles atomically, and the unwind settles itself.</b>
</p>

<p align="center">
  ETHGlobal ETHOnline 2026 · Hedera "Tokenization of Anything" · Privy
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

A borrower posts a tokenised bond as collateral and receives USDC. At maturity they repay and get
the bond back, or they do not and the lender keeps it. Two hard parts, both solved on-chain:

**The open must be atomic.** Cash and collateral cross in a single contract call. Either both move
or neither does, so neither side is ever exposed.

**The close must actually happen on the date.** On every other chain that means a keeper bot, a
cron job, or a clearinghouse that can fail on exactly the day it matters. Tenor hands the closing
leg to the network at the moment the trade is struck, as a HIP-1215 scheduled contract call.
Nobody runs it. Nobody can forget. Nobody pays for it but the contract itself.

## Proven on Hedera testnet

Not claims. Every row is a public transaction.

| What | Evidence |
|---|---|
| The network executed our unwind with nobody online | schedule `0.0.10474468`, `executed_timestamp` `1789123560.025816284` |
| Drift from the requested second | **25.8 ms** |
| The scheduled execution succeeded, it did not revert | `result: SUCCESS`, `scheduled: true` |
| **The contract paid its own settlement fee** | 0.0503 HBAR debited from the contract, no user transaction |
| Atomic open against the **real ATS bond and real USDC** | tx `0xee272d7c6f02972df1b6d2f254c38cf9ea731b53511d2708e80d669382a339bf`, 2,380,918 gas |
| Independent HIP-1215 measurement | `ScheduleProbe`, schedule `0.0.10393574`, 134 ms |

ATS bond: [`0xc2dadb01462b766bb2f58c9638b32e97200ca07d`](https://hashscan.io/testnet/contract/0xc2dadb01462b766bb2f58c9638b32e97200ca07d)

The default branch is the one worth reading. At maturity, with the borrower unfunded, the network
called `closeRepo`, it settled as `Defaulted`, the lender took the collateral, and the transaction
came back **SUCCESS**. A scheduled transaction fires once and never retries, so a revert there
would be a settlement that silently did not happen. Default is a business outcome, not an error,
and the contract is written so it can never revert.

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

Claude was used for research, design review, and drafting parts of the contracts and docs. Every
Hedera and ATS claim here was verified against the published v8.0.0 Solidity or against a testnet
transaction, because both the documentation and the model were wrong in several places.

## Licence

See LICENSE.
