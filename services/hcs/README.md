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

Events to consume: `RepoOpened`, `RepoClosed`, `RepoDefaulted`, `MarginCall`, `ScheduleStepped`.

## Build notes

- Go or TypeScript, whichever is faster for you. The Hedera plugin `native-services-js` covers the
  JS SDK patterns; see `TOOLING.md`.
- `TopicCreateTransaction` once, then `TopicMessageSubmitTransaction` per event.
- Read back through the mirror node REST API for the UI. Free, public, no indexer.
- Optional and cheap: a HIP-991 fee on the topic makes submission cost money at the protocol layer.
  Only if there is time.

Owner: Parsa. Skeleton due Tue 9, consuming real events Wed 10.
