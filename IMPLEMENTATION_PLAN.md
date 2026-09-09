# Tenor — implementation plan

Repo desk for tokenised securities on Hedera. **Submission: Sun 13 Sep, 12:00 EDT / 19:00 Istanbul.**

`STATUS.md` is what is true right now. `CLAUDE.md` is the working contract. **This file is the
build plan and the record of decisions**: what we are building, why, and what is closed.

---

## 1. What we are building

One contract, plus scripts, one small off-chain service, and a thin UI.

`openRepo(Quote, signature)` — the borrower accepts a lender's EIP-712 signed quote, and in a
**single call**: pull cash from the lender, create and execute the borrower's ATS hold so collateral
lands with the lender, create the return-leg hold, and schedule `closeRepo` via HIP-1215 at maturity.

`closeRepo` — called by the **network** at maturity. Never reverts. Two terminal branches:
borrower repurchases, or lender keeps the collateral.

Everything else is supporting cast.

**The three demo beats, built as features:**
1. Open crosses both legs in one transaction, no exposure window.
2. A non-verified counterparty tries to take delivery and the **token itself refuses**.
3. Maturity arrives and the **unwind executes with nobody touching anything**.

---

## 2. Toolchain: Foundry, deliberately

Foundry is the right call. The team is fluent in it, and the argument for Hardhat (that ATS uses it
and ships a TypeScript SDK) does not survive contact: we do not compile *against* ATS, we write four
small interfaces and call a deployed diamond, and every ATS operation we need is a contract call
`forge script` can make. The SDK is convenience, not necessity.

### foundry.toml

```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc = "0.8.28"
evm_version = "cancun"
optimizer = true
optimizer_runs = 100
via_ir = true

[rpc_endpoints]
hedera_testnet = "https://testnet.hashio.io/api"
```

Match ATS's compiler exactly (0.8.28 / cancun / 100 runs). Mismatched settings against a diamond
produce failures that look like permissions bugs. `via_ir` is codegen only, required for `openRepo`
to compile past "stack too deep", and does not affect ABI compatibility.

### What Solidity can and cannot reach on Hedera

| Service | From Solidity? | How |
|---|---|---|
| HTS (tokens, USDC) | **Yes** | System contract `0x167`, HIP-206. ERC-20 facade. |
| Schedule Service | **Yes** | System contract `0x16b`, HIP-1215. Proven on testnet. |
| **HCS (consensus topics)** | **No** | **No precompile exists.** HIP-1208 is still an open PR. |

**Consequence: the HCS audit trail is a separate off-chain service, not contract code.** It needs a
Hedera SDK (Go or TypeScript, Parsa's choice) submitting `TopicMessageSubmitTransaction`. This is a
real deliverable with an owner, not a line in `openRepo`. It would have been required under Hardhat
too, so it is not a cost of choosing Foundry.

### What Foundry does cost us

- **`forge test` cannot reach `0x16b` or `0x167`.** Local tests need mocks, and passing them means
  very little. The real mechanism only runs via `forge script --rpc-url hedera_testnet --broadcast`.
  Budget for that loop now, do not discover it on the 11th.
- Hedera's EVM differs from forge's local EVM in gas behaviour and unit conventions. Expect gas
  estimation through `forge script` to be off; be ready to set gas explicitly.
- **Verification works.** HashScan uses Sourcify and Hedera runs its own instance, so
  `forge verify-contract --verifier sourcify` satisfies the stated qualification requirement.

### Interfaces we hand-write

Four, in `src/interfaces/`. **Verify every signature against the deployed ABI on day 1 before
building on it.** Too much of the ATS documentation has already turned out to be wrong.

---

## 3. File layout

```
src/
  TenorSettlement.sol              # THE contract
  interfaces/
    IHederaScheduleService.sol     # HIP-1215, address 0x16b
    IHoldByPartition.sol           # ATS holds
    IIdentityRegistry.sol          # isVerified(address)
    ICompliance.sol                # transferred/created/destroyed/canTransfer
  periphery/
    TenorIdentityRegistry.sol      # written, minimal isVerified + allowlist
    TenorCompliance.sol            # written, non-reverting hooks
  probe/
    ScheduleProbe.sol              # HIP-1215 evidence, keep it in the repo
  mocks/
    MockATS.sol                    # hold surface: total = available + held
    MockERC20.sol                  # stands in for USDC
                                   # 0x16b is handled with vm.mockCall, not a mock contract
script/
  01_DeployPeriphery.s.sol         # identity registry + compliance module
  02_WireBond.s.sol                # setIdentityRegistry + setCompliance on the ATS bond
  TestnetFlow.s.sol                # the walkthrough: deployAll / openRepo / status /
                                   # fundRepurchase / repayEarly / closeRepo
services/
  hcs/                             # Hedera SDK, Go or TS. Topic create + message submit.
                                   # Watches settlement events, writes the audit trail.
test/
  TenorSettlement.t.sol
```

`STATUS.md` records which of these are deployed. Do not infer deployment from a file existing.

---

## 4. The contract

```solidity
enum Status { None, Open, Closed, Defaulted }

struct Repo {
    address lender;          // provides cash, receives collateral
    address borrower;        // provides collateral, receives cash
    address security;        // ATS diamond address
    bytes32 partition;
    uint256 collateralQty;
    address cash;            // USDC, HTS token via the ERC-20 facade
    uint256 principal;       // cash moved at open
    uint256 repurchase;      // cash moved at close, principal * (1 + rate*days/360)
    uint64  maturity;        // unix seconds
    uint256 haircutBps;
    bytes32 openHoldId;      // borrower's hold, open destination
    bytes32 closeHoldId;     // lender's hold, created at open
    address scheduleAddress;
    Status  status;
}
```

### Rate agreement: RFQ, not an order book

Repo against a *specific* security is a **specials** trade. General collateral repo has an order
book because the collateral is fungible; specials are negotiated, which is why Tradeweb and
BrokerTec run RFQ for them. So: the borrower publishes a request, lenders return signed quotes, the
borrower executes the one they accept. We are not competing on price formation.

Nothing is negotiated on-chain and nothing can be substituted, because the terms are bound by the
lender's signature. The lender signs a 12-field `Quote` (EIP-712, domain `Tenor` v1); the borrower
calls `openRepo` and the contract recovers the signer and requires it to equal `q.lender`.

| | Setup, once | Per trade |
|---|---|---|
| Lender | `approve(cash, TenorSettlement, working amount)` | sign a Quote, **zero transactions** |
| Borrower | authorise TenorSettlement as an ATS operator | `openRepo`, **one transaction** |

There is no EIP-2612 `permit` on HTS (HIP-376 gives approve/allowance/transferFrom only), so the
lender's one-time approval cannot be removed. Advise a working amount rather than infinite: the
allowance is standing, bounded only by `quoteExpiry` and the fact that each `requestId` opens once.

### openRepo

1. `msg.sender == q.borrower`; `requestId` unused; quote not expired; quote not cancelled;
   maturity in the future; contract holds enough HBAR to pay for the scheduled unwind.
2. Recover the EIP-712 signer and require it to equal `q.lender`.
3. `IERC20(cash).transferFrom(lender, borrower, principal)`.
4. `createHoldFromByPartition(partition, borrower, hold, "")` then `executeHoldByPartition(..., lender, qty)`.
   The contract creates the hold itself, so **hold expiry is set here** (`maturity + HOLD_BUFFER`)
   rather than asserted. That removes a whole class of failure.
5. `createHoldFromByPartition(partition, lender, hold, "")` for the return leg. This is what locks
   the collateral for the term: the lender cannot move it away and leave nothing to give back.
6. `hasScheduleCapacity(maturity, GAS)`; if false, **step the expiry forward**, do not revert the trade.
7. `scheduleCall(address(this), maturity, GAS, 0, abi.encodeWithSelector(this.closeRepo.selector, id))`.
8. Store, set `Open`, **emit a rich event**. The HCS service listens for it; the contract cannot
   write to HCS itself.

Reverting anywhere in `openRepo` is correct and safe: nothing has moved yet.

### closeRepo

```solidity
function closeRepo(bytes32 id) external {   // no access control: no EOA sender exists
    Repo storage r = repos[id];
    if (r.status != Status.Open) return;    // idempotent, never revert

    bool funded = IERC20(r.cash).allowance(r.borrower, address(this)) >= r.repurchase
               && IERC20(r.cash).balanceOf(r.borrower)               >= r.repurchase;

    if (funded) {
        // wrap both in try/catch so nothing unexpected can revert the whole call
        // cash borrower -> lender, then execute closeHoldId back to borrower
        r.status = Status.Closed;
    } else {
        r.status = Status.Defaulted;        // lender keeps the collateral
    }
}
```

**A scheduled transaction fires once and never retries.** A revert here is a settlement that
silently did not happen. The default branch is not an error path, it is what a repo does when
someone fails to repurchase.

### Events matter more than usual

Since HCS is unreachable from Solidity, every event is the only handoff to the audit trail. Emit
enough on open, close, early repayment and default that the HCS service can write a complete record
without re-reading chain state. The declared set is `RepoOpened`, `RepoClosed`, `RepoRepaidEarly`,
`RepoDefaulted`, `ScheduleStepped`, `QuoteCancelled`, `Funded`. There is no `MarginCall`; it was
removed with the oracle.

### Constants proven on testnet

| Thing | Value |
|---|---|
| Schedule Service | `0x16b` |
| HTS system contract | `0x167` |
| Scheduled gas limit | **200_000 works. 2_000_000 fails `hasScheduleCapacity`.** |
| Cost per scheduled settlement | ~0.12 HBAR, paid by **this contract** |
| Gas to schedule | ~1.5M at `openRepo` time |
| Measured drift | **134 ms** (schedule `0.0.10393574`) |
| `address(this).balance` | tinybars, 8 dp |
| `msg.value` | weibar, 18 dp |

---

## 5. Decisions already made, do not relitigate

- **Foundry.** Settled above. OpenZeppelin added for `EIP712` and `ECDSA`; `remappings.txt` committed.
- **RFQ with EIP-712 signed quotes**, not an order book and not a matching engine. Two other teams
  in this track are competing on price formation; we are not. See above.
- **Cash leg is USDC** (HTS token, native Circle issuance on Hedera), not HBAR. Mechanical reason,
  not narrative: `closeRepo` is called by the network with no value attached, so the repurchase cash
  cannot arrive as `msg.value`. Allowance-and-pull works in both directions.
- **HCS is an off-chain service**, driven by contract events. Not optional, not contract code.
- **Compliance via our own `TenorIdentityRegistry` and `TenorCompliance`**, not the ATS Terminal3 VC
  path. Already written.
- **Repo rate is a trade input**, not a mechanism. Compute `repurchase` off-chain and pass it in.
  No rates engine. It is a different rate from the bond's coupon.
- **Liquidation is the default branch of `closeRepo`.** No separate engine.
- **No oracle and no margin call.** Removed deliberately, not skipped. A margin call is only
  meaningful if there is a remedy, and there is none here: collateral is fixed at open and locked
  in a hold, there is no way to post more and no early liquidation. The haircut is the risk
  control, which is how bilateral term repo actually works. An admin-typed "mark" with an advisory
  event was theatre and a judge would have found the hole in one question. Stated as a design
  position in the README.
- **Early repayment** at the full repurchase amount, no rebate, no lender consent needed. Safe
  because the lender is strictly better off. The orphaned schedule is a quiet no-op.
- Not building: order book, matching engine, prediction market, futures, rehypothecation.

---

## 6. What happens next, in order

**As of 9 Sep the settlement contract has never run on testnet.** Four days remain. The queue below
is ordered by risk, not by convenience. Do not start an item before the one above it is green, and
do not start building anything new while items 1 and 2 are open.

Each item states how you know it worked. If it did not, open the `tenor-debug` skill before
investigating, then record what you learned in `STATUS.md`.

### 1. Confirm the unit suite (minutes)

```bash
forge test
```

**Green when:** 18 of 18 pass. If tests fail on signatures or on the wrong caller, it is the
cheatcode-hoisting trap, not your logic. See `tenor-debug`.

### 2. Settle the reverting-schedule question (20 minutes, can run in parallel)

`ScheduleProbe` is already deployed. `setShouldRevert(true)`, then `arm(900, 200000)`, then wait
and read `status()` and the schedule on HashScan.

**Answered when:** you can say whether a reverting scheduled call is consumed with no retry.
**Why it is second:** `closeRepo`'s entire two-branch, never-revert design assumes it is. If the
network retries, that design is wrong and we would rather know on the 9th than the 12th.

### 3. Stage 1 of `TESTNET.md` end to end (the critical path)

Mock securities, mock cash, **real HIP-1215**. Deploy, open one repo, watch the schedule fire.

**Green when:** the cash transfer and both hold operations appear in **one** transaction record on
HashScan, a pending schedule is visible with a future expiry, and at maturity the repo reaches
`Closed` without any transaction of ours settling it.

This proves the two things `forge test` cannot: that one call can cross both legs, and that the
network runs our unwind. Everything after this is presentation.

Use `--gas-limit 4000000`. An empty revert here is gas, not logic.

### 4. Both close branches, plus the compliance rejection

Default (skip `fundRepurchase`, wait, expect `Defaulted` without a revert) and early repayment
(`repayEarly`, then confirm the orphaned schedule fires harmlessly). Then switch
`permitAllForTestnet` off, whitelist exactly the two counterparties, and have a third account be
refused by the token itself.

**Green when:** all three film cleanly.

### 5. Stage 2, the real securities layer

Swap `MockATS` for the ATS bond and `MockERC20` for an HTS token. Expect operator authorisation and
token association to bite, in that order.

**Cut this if item 4 is not finished by Thursday night.** A complete demo on mocks beats a broken
one on the real bond, as long as the README is honest about which is which.

### 6. Presentation: UI, HCS service, verification, video

Contracts verified on HashScan via Sourcify as they deploy, not on the last day. Thin UI and the
HCS audit trail are both cuttable. The video is not.

### Calendar

| Day | Target |
|---|---|
| **Wed 9** | items 1, 2 and 3. Stage 1 green on testnet. |
| **Thu 10** | item 4. Start item 5 only if item 4 is done. |
| **Fri 11** | UI, verification, README. **Feature freeze at end of day.** |
| **Sat 12** | Two full rehearsals from a script, then video, then **submit tonight**. |
| Sun 13 | Buffer only. Deadline 19:00 Istanbul. |

**Choosing between one more feature and a rehearsed video: choose the video.** Async judging screens
to roughly the top 20% before a human speaks to us, and it screens on the tape.

## 7. Non-negotiables

- **Disclosure in the first README commit**: prior art naming Alba, what is shared, what differs.
  Also required in the submission description and the video. ETHGlobal cleared the build on this condition.
- **Commit often, from all three accounts, with verified emails.** Repos with single large commits
  are assumed unqualified.
- **Verify contracts on HashScan** (`forge verify-contract --verifier sourcify`) as they deploy.
  Stated qualification requirement.
- **Document AI assistance** as we go. Reconstructing it on the 12th is miserable.
- Video 2 to 4 minutes, 720p minimum, no phone recording, **no speeding up the footage** (manually
  verified, disqualification).
