# Deploying and testing Tenor on Hedera testnet

Two stages, deliberately. **Do not skip stage 1.**

`forge test` cannot reach `0x16b` or `0x167`, so two things are unproven when the unit suite is
green: that HIP-1215 actually fires our settlement, and that ATS accepts our hold calls. If you
change both layers at once and it breaks, you will not know which one broke. Stage 1 isolates the
scheduling. Stage 2 swaps in the real securities layer.

---

## Prerequisites

**Two ECDSA accounts**, because the lender signs and the borrower sends. Get them from the
[Hedera portal](https://portal.hedera.com/) and fund both from the faucet. They must be **ECDSA**,
not ED25519, or they cannot drive an EVM RPC at all.

Your wallet presents the **long-zero** address form (`0x000...009d85a4` for `0.0.10323364`), not an
ECDSA alias. Every address you configure must be the form the wallet actually presents.

```bash
cp .env.example .env
```

```bash
HEDERA_RPC_URL=https://testnet.hashio.io/api
LENDER_PRIVATE_KEY=0x...      # signs quotes, funds the deployment
BORROWER_PRIVATE_KEY=0x...    # sends openRepo
REQUEST_ID=repo-1             # change this for every new trade
```

---

## Stage 1: prove the scheduling

Mock securities, mock cash, **real HIP-1215**.

### 1. Deploy

```bash
forge script script/TestnetFlow.s.sol --sig "deployAll()" \
  --rpc-url hedera_testnet --broadcast
```

Copy `TENOR_SETTLEMENT`, `SECURITY` and `CASH` from the output into `.env`.

This deploys the settlement contract **with 5 HBAR**. It is the payer for every scheduled unwind,
roughly 0.12 HBAR each, and `openRepo` reverts below `MIN_HBAR_PER_REPO` (0.3 HBAR). It also mints
the mock bond to the borrower, mints mock cash to both, and sends the lender's single standing
approval.

**Watch the units.** `msg.value` is weibar (18 dp), so `5e18` is 5 HBAR. But
`address(this).balance` reads back in **tinybars** (8 dp), which is what `MIN_HBAR_PER_REPO` is
denominated in. Locally in `forge test` the same balance is in wei, so that guard is far weaker
under unit test than it is here. Do not be surprised by the difference.

### 2. Verify the contracts

```bash
forge verify-contract <TENOR_SETTLEMENT> src/TenorSettlement.sol:TenorSettlement \
  --verifier sourcify --rpc-url hedera_testnet
```

Verified contracts on HashScan are a stated prize requirement, so do this as you go rather than on
the last day.

### 3. Open the repo

```bash
forge script script/TestnetFlow.s.sol --sig "openRepo()" \
  --rpc-url hedera_testnet --broadcast
```

The lender signs off-chain and sends nothing. The borrower sends **one** transaction.

**Then open that transaction on HashScan and check the thing that matters:** the cash transfer and
both hold operations appear in the *same* transaction record. That is the atomic cross, and it is
demo beat one.

### 4. Find the pending schedule

```bash
forge script script/TestnetFlow.s.sol --sig "status()" --rpc-url hedera_testnet
```

Take `schedule` from the output and look it up on HashScan. **A pending schedule with a future
expiry, that nobody has to run, is the shot.** Screenshot it.

### 5. Let the network settle it

```bash
forge script script/TestnetFlow.s.sol --sig "fundRepurchase()" \
  --rpc-url hedera_testnet --broadcast
```

Then **wait**. Term is 15 minutes. Do not call `closeRepo` yourself; that is the entire point. When
the time passes, re-run `status()`: status should read `2` (Closed), the collateral is back with
the borrower, and no transaction of yours settled it.

Compare the schedule's `executed_timestamp` against its `expiration_time` on the mirror node and
record the drift. `ScheduleProbe` measured **134 ms**.

### 6. Now run the branches that matter

- **Default.** New `REQUEST_ID`, open, then skip `fundRepurchase` and wait. At maturity the repo
  should go `Defaulted` (status `3`) **without reverting**, and the lender keeps the collateral.
  This is the branch that proves the settlement guarantee, and it films well.
- **Early repayment.** New `REQUEST_ID`, open, then `repayEarly()`. Collateral returns
  immediately. Wait for maturity anyway and confirm the orphaned schedule fires and does nothing.
- **Tampered quote.** Edit `REPURCHASE` in the script downward, re-run `openRepo()`, and watch it
  revert on the signature. This is the security beat.

### 7. Debugging

`closeRepo()` is exposed as a manual entrypoint so you can exercise the logic without waiting for
maturity. Use it while iterating, but the **demo must be the unattended run**.

If a transaction reverts with only a selector, decode it against the errors in
`TenorSettlement.sol`, or read the failure from the mirror node:

```
https://testnet.mirrornode.hedera.com/api/v1/contracts/results?timestamp=<consensus.timestamp>
```

`error_message` carries the 4-byte selector. Two you have already met:
`0xad87849e` is `IdentityRegistryCallFailed()` and `0x67fba102` is `ComplianceCallFailed()`.

---

## Stage 2: the real securities layer

Only start this once stage 1 is fully green.

### What changes

| | Stage 1 | Stage 2 |
|---|---|---|
| `SECURITY` | `MockATS` | the real ATS bond, `0xc2dadb01462b766bb2f58c9638b32e97200ca07d` |
| `CASH` | `MockERC20` | an HTS token through the ERC-20 facade |
| Partition | `bytes32(uint256(1))` | the bond's actual partition |
| Quantities | 100e18 | the bond's real decimals |

### Three things that will bite

**Operator authorisation.** `MockATS` does not enforce it, the real diamond does. The borrower and
the lender must each authorise `TenorSettlement` as an ATS operator, or
`createHoldFromByPartition` reverts. This is the single most likely stage 2 failure.

**Token association.** HTS tokens must be associated with an account before it can receive them.
A plain Solidity ERC-20 needs no such step, so stage 1 hides this entirely. Set max
auto-association on every demo account.

**Compliance.** Both counterparties must pass `isVerified` on the identity registry. While
`permitAllForTestnet` is on, everyone passes. Before filming, switch it off and whitelist exactly
the two counterparties, so that the rejection in demo beat two is a real one. Then try to open a
repo with a third, unverified account and watch the token itself refuse.

### Verifying eligibility before you send

ATS already exposes a read-only check, which saves guessing at why a transfer failed:

```solidity
canTransferByPartition(from, to, partition, value, data)
  returns (bool status, bytes1 code, bytes32 reason)
```

`reason` is the **selector of the blocking error**, so it tells you which gate failed rather than
just that one did.

---

## Demo checklist

- [ ] Atomic open: cash and both hold operations in one transaction record on HashScan
- [ ] Pending schedule visible with a future expiry, owned by nobody
- [ ] Unattended settlement at maturity, with the measured drift
- [ ] Default branch: unfunded repo settles without reverting, lender keeps collateral
- [ ] Early repayment, and the orphaned schedule harmlessly firing afterwards
- [ ] Unverified counterparty refused by the token itself
- [ ] All contracts verified on HashScan
