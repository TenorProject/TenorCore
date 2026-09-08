# Tenor

**A repo desk for tokenised securities on Hedera. The trade settles atomically, and the unwind
settles itself.**

Built for ETHGlobal ETHOnline 2026.

## What it does

A repurchase agreement is a loan dressed as a sale: one party sells a bond for cash today and
agrees to buy it back at a set price on a set date. It has two hard parts. The opening leg must be
atomic, or one side is briefly exposed. The closing leg must actually happen on the date, and on
every other chain that means a keeper bot, a cron job or a clearinghouse that can fail on exactly
the day it matters.

Tenor hands the closing leg to the network at the moment the trade is struck.

- **Open** crosses collateral against USDC in a single contract call. Both legs move or neither does.
- **The unwind** is created at open as a HIP-1215 scheduled contract call and executed by the Hedera
  network itself at maturity. Measured drift on testnet: **134 ms** (schedule `0.0.10393574`).
- **Compliance is enforced by the token.** The collateral is an ERC-3643 / ERC-1400 security issued
  through Hedera's Asset Tokenization Studio. A counterparty who is not in the identity registry
  cannot take delivery, because the transfer itself reverts.

## Why this needed building

Asset Tokenization Studio issues compliance-gated securities and **cannot settle them against
money**. There are zero `payable` functions across its 104 facets, no DvP, and no atomic swap. Its
own documentation describes a delivery-versus-payment flow built on a "lock hash" that does not
exist anywhere in the code. The settlement layer in this repo is that missing piece.

## Prior art and disclosure

This project was built from scratch during ETHOnline 2026. No code, configuration or assets from
any prior project were reused.

**Alba** ([showcase](https://ethglobal.com/showcase/alba-ma7bi),
[repo](https://github.com/acollette/alba)) won Hedera's ETHGlobal Lisbon 2026 prize using the
Hedera Schedule Service to execute a loan maturity leg without a keeper. We reached the same
underlying primitive independently.

*What we share:* the observation that a dated obligation can be created at trade time and executed
by the network with no off-chain trigger.

*What differs:* Alba is crypto-collateralised revolving credit settled on Base, with Hedera acting
as a scheduling co-processor and Axelar carrying the message back. Tenor is Hedera-native
end to end and settles a compliance-gated security against cash as delivery versus payment, with an
identity registry deciding who may take delivery.

Other prior art reviewed: Asseto (ioBuilders and Hashgraph, closed source, order books and atomic
DvP on Hedera), Broadridge DLR and JPMorgan Kinexys (institutional tokenised repo on permissioned
ledgers), Fnality with HQLAˣ (cross-chain intraday repo swap), Term Finance (tri-party repo modelled
in Solidity, keeper-driven), and the Aberdeen / Lloyds / Archax tokenised collateral trade on Hedera
under FCA oversight.

This approach was confirmed with ETHGlobal support before the build began.

## Repo

| Path | What |
|---|---|
| `src/TenorSettlement.sol` | The settlement contract. Open and close. |
| `src/interfaces/` | Hand-written ATS and HIP-1215 interfaces. |
| `src/periphery/` | Minimal identity registry and compliance module ATS does not ship. |
| `src/probe/ScheduleProbe.sol` | HIP-1215 evidence rig. Rerunnable. |
| `services/hcs/` | Consensus-service audit trail. HCS is unreachable from Solidity. |
| `IMPLEMENTATION_PLAN.md` | Build plan. |
| `TOOLING.md` | Dev setup. |

## Build

```bash
forge build
forge test
forge script script/01_DeployPeriphery.s.sol --rpc-url hedera_testnet --broadcast
```

## AI assistance

Claude was used for research, prior-art review, and drafting parts of the contracts and docs. All
Hedera and ATS findings recorded here were verified against source code or against testnet.

## Licence

See LICENSE.
