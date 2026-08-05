# Phase C2 — Migrating readers off `cms_ledger_entries`

| Property | Value |
|---|---|
| Date | 2026-08-05 |
| Status | **Complete for every reader that can migrate. Three remain, each for a stated reason (§6).** |
| Depends on | C1 complete: all five products authoritative, 1,703 postings compared with zero disagreements |

---

## 1. What C2 is

C1 made the new engine authoritative for **writes**. Twelve modules still **read** `cms_ledger_entries`, so the legacy table is still written for them. C2 moves those readers across; C3 then stops writing the legacy table.

### The read API

Readers do not want ledger *rows* — they want answers: *"how much did this account pay during the cycle"*, *"how many postings has it had"*, *"which accounts posted on this date"*. Twelve hand-written queries against `journal_entries` would spread the new schema across the codebase and make any future change to it a twelve-file edit.

`VmuCore.GL.LedgerQuery` answers those questions instead: `sum_amount/1`, `count/1`, `exists?/1`, `account_refs/1`, `entries/1`.

It accepts **legacy transaction codes** and translates to the new event vocabulary, so a migrating reader does not also have to change what it means:

| Legacy `transaction_code` | New `event_type` |
|---|---|
| `PURCHASE` | `PURCHASE`, **`WITHDRAWAL`** |
| `ADJUSTMENT` | **`ADJUSTMENT_CREDIT`**, **`ADJUSTMENT_DEBIT`** |
| everything else | 1:1 |

Those two exceptions are exactly where a silent bug would hide — wallet withdrawals post as `PURCHASE` in the legacy enum, and both adjustment directions collapse to one code there.

---

## 2. Blocker, now resolved: the new tables did not contain history

Verified against live data before any reader moved:

```
legacy rows with no engine counterpart:  33
earliest: 2026-03-16      latest: 2026-08-03
```

Shadow mode was switched on 2026-08-03. **Every posting before that existed only in `cms_ledger_entries`.** Migrating a reader at that point would have silently made it blind to all pre-shadow history — for `CMS.AccountStateCoordinator`, understating a balance on the authorization path with nothing raised or logged.

### Backfill result (2026-08-04)

`priv/repo/backfill_gl_history.exs --apply`

| | |
|---|---|
| Unmirrored at start | 33 (2026-06-02 .. 2026-07-31) |
| Replayed | **30** |
| Orphans removed | **3** — ledger rows whose `account_id` exists in *no* product table |
| **Remaining unmirrored** | **0** |

**The dry run surfaced a real gap in `posting_rules`.** 17 of the 33 rows had no rule at all: `cms_accounts` backs *both* the `CREDIT` and `CREDIT_CARD` product labels — `InstitutionResolver.resolve_product/1` returns `CREDIT` for that table, while `PURCHASE`, `CASH_ADV`, `DISPUTE_CREDIT` and the adjustment directions were registered only under `CREDIT_CARD`. Five rules added (24 total), with pairs taken from what the rows actually store rather than re-derived.

### Parity verified

| | Legacy | LedgerQuery | |
|---|---|---|---|
| Accounts in agreement | — | — | **19/19** |
| Portfolio total | 1,737,568.84 | 1,737,568.84 | equal |
| Row count | 2,271 | 2,271 | equal |
| Per transaction code | | | all 8 match |

Reaching parity also required removing 18 `seed_gl_demo` rows — engine-only placeholders created to populate the GL screens before real data existed.

---

## 3. Readers migrated

Sixteen call sites across fourteen modules now read `GL.LedgerQuery`, or — for the trial balance — `gl_ledger_entries` directly.

| Reader | What it asked the ledger | Now |
|---|---|---|
| `CMS.ChargeOffRecovery` | recovered total per account | `sum_amount(idempotency_key_prefix: "RECOVERY-")` |
| `CMS.CreditBalanceRefund` | refunds already paid out | `sum_amount(idempotency_key_prefix: "refund:<id>:")` |
| `EOD.AgeBucketsJob` | payments per account in window | `sum_amount(transaction_code: "PAYMENT", from:, to:)` |
| `CMS.StatementGenerator` | payments in cycle | same shape |
| `COL.PromiseVerification` | payments since a promise | same shape |
| `CMS.PaymentIntake` | duplicate reference guard | `exists?(idempotency_key:)` |
| `TRAMS.Oban.PostingCycleJob` | duplicate posting guard | `exists?(idempotency_key:)` |
| `TRAMS.Oban.AuthExpirySweepJob` | is clearing in flight | `exists?(idempotency_key:)` |
| `FAS.SettlementPostingAdapter` | already posted | `exists?(idempotency_key:)` |
| `FAS.GL.VmuCoreGlAdapter` | posting status; reconciliation extract | `exists?/1` + `entries/1` |
| `FAS.GL.GlReconciliation` | which settlement keys posted | `posted_keys/1` |
| `TRAMS.Reconciliation` | settlement totals; unposted breaks | `count` + `sum_amount` + `posted_keys/1` |
| `CMS.FinancialAdjustment` | adjustments for an account | `entries(transaction_code: "ADJUSTMENT")` |
| `CMS.FeeWaiver` | fee entries; the entry being waived | `entries(transaction_code: "FEE")` |
| `CMS.Oban.AccountLifecycleSweepJob` | accounts active since cutoff | `account_refs_query/1` as a subquery |
| Admin `account_component`, `accounts_page`, `visionplus_live` | display | `entries/1` |
| `FAS.GL.TrialBalance` | GL by account and month | `gl_ledger_entries` + `gl_accounts` names |

### API added during the migration

`idempotency_key` (exact, and lists), `idempotency_key_prefix`, `inserted_from` / `inserted_to` (row-write time, deliberately distinct from posting date), list-valued `account_ref`, `account_refs_query/1` (composable subquery, with an `Ecto.UUID` cast for comparison against `uuid` columns), and `posted_keys/1`.

### One identifier changed

`FeeWaiver.waive_by_entry_id/1` is gone. `cms_ledger_entries` had a surrogate primary key; the posting tables have no single column meaning the same thing. Fee entries are now identified by `idempotency_key`, which is the better identifier anyway — stable across both models, what the backfill joined on, and meaningful to read in an audit trail.

---

## 4. What the migration found

Six defects, none of which were on the plan.

**1. The GL lost writes under concurrency.** `RuleEngine.consolidate/4` accumulated `gl_ledger_entries` by reading the row, adding in Elixir, and writing the total back. Two postings into the same correspondence on the same date both read the same row, and the second update overwrote the first. Nothing raised — the journal entry was written either way, so the customer-facing view stayed correct while the bank's books quietly under-reported.

Found by building the trial balance, which is precisely the report that makes it visible: `journal_entries` totalled 1,737,568.84 against `gl_ledger_entries`' 1,728,263.33 — a **9,305.51 shortfall over 19 postings**, every one dated 2026-08-03, the only day this database had concurrent posting traffic.

Fixed with an atomic upsert (`ON CONFLICT DO UPDATE SET amount = amount + EXCLUDED.amount`) against the unique index that already existed. Historical rows repaired by `priv/repo/repair_gl_consolidation.exs`, which rebuilds the GL from the journal and **aborts** rather than touching any entry carrying lifecycle state (a non-OPEN status, a generation above 1, or an extraction timestamp). Two regression tests now assert the invariant the bug violated: the GL total must equal the journal total.

**2. The fee-waiver screen on the legacy console never worked.** It passed a **map** to `FeeWaiver.waive/1`, which does `Keyword.fetch!/2`, so every submission raised and a `rescue` turned it into a generic error message. It also passed an `:amount` the module has no concept of — a waiver reverses the original entry in full. Corrected while retiring `waive_by_entry_id/1`.

**3. The trial balance named five accounts out of thirty.** A hardcoded map against the chart Phase A made authoritative, in a report whose entire purpose is naming accounts. It also summed every institution together, which reconciles against no one's books — `report/3` now takes an institution, and grouping moved from `posting_date` to `gl_date`, the correct axis for a trial balance.

**4. Adjustment direction was inferred from a GL account code.** The admin display decided CREDIT vs DEBIT by testing whether the debit leg was `"1001"`. Right today, and exactly the class of assumption Phase 4A's account remap invalidated elsewhere. `posting_sets.event_type` states it outright.

**5. `PromiseVerification` carried a dead injection seam.** `@ledger_entry_schema` was `compile_env`-injected and no config ever set it; the only value it could take was its own default.

**6. The dormancy sweep asked the wrong question.** It tested for *any* product's ledger activity against a `cms_accounts` row — harmless only because ids could never collide across products. Now filtered to `product: "CREDIT"`, which is also what makes the `Ecto.UUID` cast in `account_refs_query/1` safe.

---

## 5. Tests

`test/support/gl_fixtures.ex` exists because the first migrated reader exposed a trap. `gl_accounts` and `posting_rules` are reference data seeded by `seed_gl.exs`, not by a migration, so inside the Ecto sandbox both tables start empty and the engine silently finds no rule for anything.

Before C2 that was invisible: no test read the posting tables, so a shadow write that found no rule changed nothing anyone asserted on. It is visible now — a migrated reader returns **zero** rather than failing, because `LedgerQuery` sums an empty set. That is a passing-looking test measuring nothing.

Any test whose subject touches the posting engine calls `GLFixtures.seed_posting_engine!/0` and `GLFixtures.open_institution!/2`.

---

## 6. Not migrated, and why

| Reader | Reason |
|---|---|
| `CMS.CoreBankingAdapter` | Needs per-entry `extracted_at` extraction state. `gl_ledger_entries` *has* an `extracted_at` column, but at **consolidated GL grain** — one row per (institution, gl_date, dr, cr) — while the adapter extracts per account, per posting date, per entry. Not the same thing. Needs its own extraction-state table keyed by posting set |
| `HCS.FleetReport`, `HCS.ConsolidatedStatementGenerator` | **HCS is invisible to the posting engine.** `InstitutionResolver` covers `cms_accounts`, debit, prepaid and wallet only, and `journal_entries` holds **0 HCS rows out of 2,271**. Migrating them would silently return zero — the same trap §5 describes, but in production. HCS needs posting rules and a resolver entry first |
| `CMS.AccountStateCoordinator.query_today_velocity/2` | **The query is dead.** It filters `transaction_code == "AUTH_<channel>"`, but `LedgerEntry`'s changeset permits eleven codes and none is `AUTH_*` — and authorizations never post to GL by design. Consequence: the daily velocity **count** limit never fires, and the amount check degrades to a single-transaction check. Documented in place; not migrated and **not fixed**, because fixing it changes authorization outcomes. That is a business decision, not a migration step |

---

## 7. Exit criteria per reader

- Backfill complete, `unmirrored = 0` ✅
- The reader's own query and `LedgerQuery` return identical results over a real sample ✅
- Tests green ✅
- One commit per reader, independently revertible

---

## 8. Status

**Complete.** 692 tests green. The three readers in §6 are each blocked on something real — a missing table, a missing product registration, and a business decision — not on effort.

**C3 can now proceed for everything except those three.** `cms_ledger_entries` is still written by `InternalGlPoster` and still read by them, so the table cannot be dropped yet. What C3 can do is stop new code reaching for it, and close out the three above.
