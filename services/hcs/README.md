# HCS audit trail

**HCS is unreachable from Solidity.** There is no consensus-service precompile; HIP-1208 is still
an open pull request. HTS has one at `0x167` and the Schedule Service has one at `0x16b`, but topic
messages can only be submitted through a Hedera SDK.

So this is a small off-chain service, not contract code. It would have been required under Hardhat
too, so it is not a cost of choosing Foundry.

## What it does

Watch `TenorSettlement` events and write each one to an HCS topic, so the full trade history carries
consensus timestamps the network assigned rather than ones we assigned, and anyone can replay it
from a public mirror node with no indexer and no permission.

Events to consume, exactly as declared in `src/TenorSettlement.sol`:

| Event | Meaning for the audit trail |
|---|---|
| `RepoOpened` | the trade struck: both legs crossed, unwind scheduled |
| `RepoClosed` | borrower repurchased, collateral returned |
| `RepoDefaulted` | borrower did not repurchase, lender kept the collateral. Carries a `reason` string |
| `RepoRepaidEarly` | closed before maturity; the schedule that later fires is a no-op |
| `ScheduleStepped` | the requested maturity second was saturated and the unwind moved forward |
| `QuoteCancelled` | a lender withdrew an outstanding quote |
| `Funded` | HBAR arrived to pay for scheduled executions |

There is no `MarginCall` event. It was removed on purpose along with the oracle; see the README.
Do not write a consumer for it.

## Build notes

- Go or TypeScript, whichever is faster for you. The Hedera plugin `native-services-js` covers the
  JS SDK patterns; see `TOOLING.md`.
- `TopicCreateTransaction` once, then `TopicMessageSubmitTransaction` per event.
- Read back through the mirror node REST API for the UI. Free, public, no indexer.
- Optional and cheap: a HIP-991 fee on the topic makes submission cost money at the protocol layer.
  Only if there is time.

## Status

**Not started.** Owner: Parsa. This is the last unbuilt deliverable and it is not on the critical
path: the settlement contract and the testnet demo come first. If time runs out, a UI reading the
mirror node directly still tells the story; a missing HCS trail costs less than a missing unwind.

See `STATUS.md` for what is proven and what is next.
