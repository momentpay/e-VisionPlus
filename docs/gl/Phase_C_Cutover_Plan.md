# Phase C — Cutover plan

| Property | Value |
|---|---|
| Date | 2026-08-03, rollout 2026-08-04 |
| Status | **C1 complete — all five products authoritative on the new engine. C2 (readers) and C3 (retire legacy table) not started.** |
| Depends on | Phase B equivalence: 500/500 postings matched, zero mismatches |

---

## 0. Terminology — and what this plan does NOT change

**"Legacy" here means one specific thing: `CMS.InternalGlPoster` writing to
`cms_ledger_entries`.** It is our own code, built earlier in this project, and
it is running right now. It does not refer to VisionPlus, a mainframe, or any
external system. It is "legacy" only relative to the new GL module.

| Term used below | What it actually is |
|---|---|
| **legacy** / legacy poster | `CMS.InternalGlPoster` → `cms_ledger_entries` |
| **engine** / new engine | `Posting.RuleEngine` → `posting_sets` / `journal_entries` / `gl_ledger_entries` |

### Authorization is not involved

This plan changes **which GL implementation is authoritative**. It does not
change *when* posting happens, and it does not touch the authorization path at
all.

`FAS.Authorization` writes an `AuthorizationRecord`, a `PendingHold`, and an
OTB decrement via `AccountStateCoordinator` — and **no GL entry**. That is
correct and deliberate:

* an authorization is a *reservation*, not a financial event. It may expire,
  reverse, or clear for a different amount. Booking it would create a
  receivable for something that has not happened;
* the auth path answers an ISO 8583 message under a network timeout, and a
  double-entry write with period validation does not belong there;
* the cleared amount frequently differs from the authorized amount, and the GL
  must record what actually settled.

GL posting happens **at settlement** (`FAS.SettlementPostingAdapter`, which
also clears the pending hold) and **at EOD** (interest, fees, statements). The
two systems are linked by *reference* — clearing matches an auth by approval
code and RRN — not by transaction.

    0100 AUTH   →  OTB + PendingHold + AuthorizationRecord      (no GL)
       ↓ hours–days
    CLEARING    →  matched to the auth via approval code / RRN
       ↓
    SETTLEMENT  →  GL entries posted, hold cleared               (GL here)
       ↓
    EOD         →  interest, fees, statements                    (more GL)

**OTB is an operational balance; the ledger is an accounting balance.** They
are different numbers by design, updated by different processes at different
times, and reconciled — not kept in lockstep.

---

## 1. What "cutover" can and cannot mean

The original plan said Phase C moves call sites onto the new engine "one at a time". Checking the code changes what that has to look like.

**`cms_ledger_entries` is read by at least twelve modules**, including `CMS.AccountStateCoordinator` (the authorization hot path), `CMS.CoreBankingAdapter` (the GL extract), `CMS.ChargeOffRecovery`, `EOD.AgeBucketsJob`, `PrepaidLedger`, `PaymentIntake` and the fee/adjustment commands.

So cutover **cannot** mean "stop writing the legacy table". Doing that in one step would break authorization, EOD and the bank extract simultaneously. It has to be split:

| Step | Meaning | Reversible by |
|---|---|---|
| **C1 — flip authority** | The engine's write becomes **mandatory**: if it fails, the posting fails. `cms_ledger_entries` keeps being written for readers | One config line |
| **C2 — migrate readers** | Move each of the twelve readers onto `journal_entries` / `gl_ledger_entries`, one at a time | Per-reader revert |
| **C3 — retire** | Stop writing `cms_ledger_entries`; delete `InternalGlPoster` | Only after C2 completes |

C1 is the real decision point. Everything before it is additive; C1 is where the new engine can break a posting.

## 2. The difference between shadow and cutover

One line:

| | Shadow (Phase B) | Cutover (Phase C1) |
|---|---|---|
| Engine write fails | logged, swallowed, posting stands | **posting fails and rolls back** |

That is the whole change. The mapping is unchanged and already proven across 500 postings.

## 3. C0 — closed-period behaviour must be configurable first

Phase B surfaced the one genuine behavioural divergence: `InternalGlPoster` posts into a closed accounting period without complaint; the engine refuses and quarantines.

Under shadow that is harmless. **Under cutover it would abort the legacy posting too** — so an EOD re-run for a day whose period had been closed would start failing where it previously succeeded.

`RuleEngine` therefore takes an explicit closed-period policy:

```elixir
config :vmu_core, VmuCore.Posting.RuleEngine,
  on_closed_period: :allow   # :quarantine | :allow
```

* **`:quarantine`** — refuse the posting, record the exception. The correct end state, and the default while nothing is cut over.
* **`:allow`** — post anyway **and still record the exception**. Behaviour-preserving relative to legacy, but no longer silent.

`:allow` is strictly better than the legacy behaviour it replaces: legacy accepts a back-dated posting and says nothing, whereas `:allow` accepts it and tells you. Tightening to `:quarantine` becomes a separate, deliberate control decision rather than a side effect of cutover.

### Why this is not just deferring the problem

WAY4's own model expects postings for a day to arrive *after* the next banking date opens — its "Close GL" runs at the very end of daily processing, after the new date is open, precisely so late entries for the closing day land correctly. The operational rule that falls out is: **do not close a period until EOD for every day in it has run.** The exception table is the safety net that says when that rule was broken.

## 4. C1 — per-product authority

```elixir
config :vmu_core, VmuCore.Posting.Cutover,
  products: ["PREPAID"]
```

For a product in that list, the engine write happens in the same transaction as the legacy write and a failure aborts both. For anything else, shadow behaviour is unchanged.

Per-product rather than per-call-site because the products are the real blast-radius boundary — a prepaid defect cannot touch credit — and because `InternalGlPoster` already resolves the product for shadow, so no caller changes at all.

### Suggested order

Lowest blast radius first, each its own commit, each verified against the diff before and after:

1. **`WALLET`** — newest product, lowest volume, no EOD dependency
2. **`PREPAID`** — closed-loop, no network settlement
3. **`DEBIT`** — real network settlement, higher volume
4. **`CREDIT`** — interest, fees, statements, EOD. Last, and only after a full EOD cycle has run clean under shadow

## 5. Exit criteria before each step

- Shadow diff shows zero mismatches for that product over a real sample
- A full EOD cycle has run with the product in shadow
- `gl_posting_exceptions` reviewed and empty, or every entry explained

## 6. Verified behaviour

Exercised against real Postgres, with a GL date deliberately placed in a closed period:

| Scenario | Legacy row | Engine set | Meaning |
|---|---|---|---|
| WALLET in shadow, closed period | **kept** | refused | Shadow never blocks a posting |
| WALLET **cut over**, closed period | **rolled back** | refused | `{:error, {:cutover_failed, "WALLET", {:quarantined, ...}}}` — the engine can now say no |
| WALLET cut over, valid date | kept | written | Normal path unaffected |
| **DEBIT still in shadow**, closed period | **kept** | refused | Cutting over WALLET does not touch DEBIT — blast radius holds |
| WALLET cut over, policy `:allow` | kept | written | Posts, **and still records the exception** — permitted, not silent |

The rolled-back case matters most: a row the engine rejected must not survive in `cms_ledger_entries`, because twelve modules read that table and would otherwise see a posting the engine refused.

## 7. Rollout log

| Date | Product | Result |
|---|---|---|
| 2026-08-03 | **WALLET** | 150/150 posted, 150 engine sets, 0 legacy-without-engine. DEBIT unaffected |
| 2026-08-04 | **PREPAID** | 80/80, gap 0 |
| 2026-08-04 | **DEBIT** | 80/80, gap 0 |
| 2026-08-04 | **CREDIT / CREDIT_CARD** | Gated on EOD (§8). 400 mixed postings, 0 failures; EOD 10/10/10 with 6/6 matched |

**C1 is complete — every product is authoritative on the new engine.**

Final verification with all five cut over: 400 postings, 0 failures, **1,400 matched, 0 mismatched, 0 orphaned**, ~89 postings/sec including the engine write, shadow ledger balanced. The only two unmatched rows are `TRAFFIC-CLOSEDPERIOD-*` probes from runs made *before* credit was cut over, when the engine correctly refused them.

## 8. EOD verified under shadow — the gate for CREDIT

A real EOD cycle was run with CREDIT still in shadow:

| Job | Result |
|---|---|
| `AccrueInterestJob` | 10/10 accounts, **6 interest postings**, all mirrored |
| `AgeBucketsJob` | 10/10 |
| `GenerateStatementJob` | **0/10 → fixed → 10/10**, see below |

All six interest postings matched exactly, `1003/4002` on both sides — Accrued Interest Receivable to Interest Income, the Phase 4A remap holding through EOD:

```
match  75e1e410  legacy 1003/4002  shadow 1003/4002 CREDIT/INTEREST
match  7759edb1  legacy 1003/4002  shadow 1003/4002 CREDIT/INTEREST
match  8b6615f3  legacy 1003/4002  shadow 1003/4002 CREDIT/INTEREST
match  b55a09e7  legacy 1003/4002  shadow 1003/4002 CREDIT/INTEREST
match  cf96d959  legacy 1003/4002  shadow 1003/4002 CREDIT/INTEREST
match  e1860140  legacy 1003/4002  shadow 1003/4002 CREDIT/INTEREST
```

### Two pre-existing defects fixed to get EOD running

Statement generation was broken for **every** account. Two separate bugs, stacked:

1. **`StatementGenerator.daily_balances_for/4` used a schemaless query** —
   `from s in "cms_daily_balance_snapshots"` — so Ecto had no field definition
   to cast `account_id` against and passed the string straight to Postgrex,
   which wants a 16-byte binary for a `uuid` column. Every other query in that
   module uses a schema module and casts correctly. Fixed with
   `type(^account_id, Ecto.UUID)`.

2. **The caller invoked `InterestEngine.minimum_payment/2`, which does not
   exist.** The only definition is the component-based `/5`
   (`interest + fees + past_due + max(1% principal, floor)`), and `min_pct` was
   being passed where `fees_due` belongs.

   The configured rule is different: every product sets
   `min_payment_calculation = PERCENTAGE_OF_BALANCE` with `min_payment_pct = 5.0`
   and `min_payment_floor = 25.00`. Added
   `InterestEngine.minimum_payment_pct_of_balance/3` implementing exactly that —
   `max(balance × pct, floor)`, capped at the balance so a floor above a small
   balance cannot demand more than the cardholder owes. The component-based `/5`
   is untouched for products configured that way.

   **Units guard:** `pct` is a percentage (`5.0` = 5%), matching the parameter
   cascade and the admin UI. A value below 1 raises rather than silently billing
   1/100th of the correct amount. Nine tests in
   `test/gl/minimum_payment_test.exs`.

After both fixes: `GenerateStatementJob` 10/10, and a full EOD posts and mirrors cleanly.

One pre-shadow interest row (`…-2026-06-20`) has no engine set. Expected: it predates shadow mode.

## 9. Status

**CREDIT and CREDIT_CARD are not cut over.** They carry interest, fees and statements, and the statement job is currently broken (§8) — fix that first.

Current configuration:

```elixir
config :vmu_core, VmuCore.Posting.Cutover,
  products: ["WALLET", "PREPAID", "DEBIT"]

config :vmu_core, VmuCore.Posting.RuleEngine,
  on_closed_period: :allow
```

### Before adding CREDIT

1. Fix `GenerateStatementJob` — it fails for every account today.
2. Run a full EOD **including statements** and confirm the diff stays clean.
3. Review `gl_posting_exceptions`. Under `:allow` a back-dated posting succeeds and is logged; under `:quarantine` it would fail. Confirm nothing legitimate is landing there before tightening.
4. Then `products: [..., "CREDIT", "CREDIT_CARD"]`.

### Remaining after that

C2 (migrate the twelve readers off `cms_ledger_entries`) and C3 (retire the legacy table). Neither has started.
