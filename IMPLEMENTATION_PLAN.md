# Tenor — implementation plan

Repo desk for tokenised securities on Hedera. **Submission: Sun 13 Sep, 12:00 EDT / 19:00 Istanbul.**

Read `ethonline-2026/tenor-handoff.md` for the full context. This file is the build plan only.

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

[rpc_endpoints]
hedera_testnet = "https://testnet.hashio.io/api"
```

Match ATS's compiler exactly (0.8.28 / cancun / 100 runs). Mismatched settings against a diamond
produce failures that look like permissions bugs.

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
  01_DeployPeriphery.s.sol
  02_WireBond.s.sol                # setIdentityRegistry + setCompliance on the ATS bond
  03_DeploySettlement.s.sol
  04_Demo.s.sol                    # the filmed sequence, end to end
services/
  hcs/                             # Hedera SDK, Go or TS. Topic create + message submit.
                                   # Watches settlement events, writes the audit trail.
test/
  TenorSettlement.t.sol
```

Delete `Counter.sol`, `Counter.s.sol`, `Counter.t.sol` in the first commit.

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
enough on `openRepo`, `closeRepo`, margin call and default that the HCS service can write a complete
record without re-reading chain state.

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

## 6. Five days

| Day | Deliverable | Owner |
|---|---|---|
| ~~Mon 8~~ | *done:* toolchain, interfaces verified against the live ABI, periphery, probe, RFQ settlement contract, mocks, unit tests | — |
| **Wed 9** | `forge build` and `forge test` green. One repo opens **on testnet**: both legs cross in one transaction. Unwind scheduled, visible on HashScan. **Run the `ScheduleProbe` revert experiment.** | Mahdiye (contract), Mhd (probe) |
| **Thu 10** | Unwind fires at maturity end to end. Both close branches confirmed on testnet. Non-verified counterparty rejection working. HCS service consuming real events. | All |
| **Fri 11** | Thin UI, contracts verified on HashScan via Sourcify. **Feature freeze at end of day.** | Parsa (app), Mahdiye (contract), Mhd (review) |
| **Sat 12** | Two full rehearsals from a script, then video, README, submit. **Submit tonight, not Sunday.** | Mhd (video), all |
| Sun 13 | Buffer only. Deadline 19:00 Istanbul. | — |

**On the 10th, choosing between one more feature and a rehearsed video: choose the video.**
Async judging screens to roughly the top 20% before a human speaks to us, and it screens on the tape.

---

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
