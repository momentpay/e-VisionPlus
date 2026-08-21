# Phase C3 — Retiring `cms_ledger_entries` as a write target

| Property | Value |
|---|---|
| Date | 2026-08-06 |
| Status | **Complete.** Nothing writes or reads `cms_ledger_entries` |
| Depends on | C2 complete: every reader migrated except the two this phase resolved |

---

## 1. What C3 is

C1 made the engine authoritative for writes; C2 moved the readers. Until C3 the
legacy table was still **written on every posting** and still read by two
modules, so the platform carried two ledgers with one of them redundant.

C3 removes it as a live table. The table and its schema still exist and still
hold history — dropping them is a data-retention decision, not an engineering
one — but nothing writes to it and nothing reads it.

---

## 2. The shape of the change

`InternalGlPoster.post/1` used to insert a `cms_ledger_entries` row and then
mirror it to the engine. **It now translates to an engine event and writes only
there.**

That inversion is the whole of C3 for 35 of the 37 call sites, because they go
through this one function.

### Why `InternalGlPoster` was not deleted

The plan said "delete `InternalGlPoster`". That turned out to be the wrong
target. **Thirty-five modules call it, and none of them knows its own
institution** — `post_interest(account_id, amount, posting_date, key)` supplies
an account and nothing else, while the engine requires `sys_id`/`bank_id` for
the period gate and GL consolidation.

Deleting the façade would have meant pushing `GL.InstitutionResolver` into
thirty-five call sites and changing every one of their signatures: more churn,
thirty-five places to get institution resolution wrong, and no benefit. The
translation has to live somewhere, and one place is better than thirty-five.

So `Posting.LegacyEvent` now holds that translation — extracted from
`Posting.Shadow`, where it had run throughout Phase B as a *mirror*. A mirror
and a system of record must not be able to disagree about what an event means,
which is why it is shared rather than duplicated.

The name `InternalGlPoster` is now misleading: it posts to the engine, not to an
internal table. Renaming is deferred under VMU-ADR-003 with every other rename.

---

## 3. The two C2 stragglers

### `CMS.CoreBankingAdapter` — extraction state

This was the last reader, and the only one needing something the new model
lacked: per-entry extraction state (`cms_ledger_entries.extracted_at`).

`gl_ledger_entries` *has* an `extracted_at`, but at **consolidated GL grain** —
one row per (institution, GL date, debit account, credit account) — while the
adapter extracts per account, per posting date, per entry. Reusing it would have
meant either sending consolidated totals where line detail is expected, or
marking a whole correspondence extracted because one of its entries was.

`GL.Extraction` is the answer: a table keyed on `(journal_entry_id, destination)`.

Two design points, both deliberate:

- **Beside the journal, not in it.** `journal_entries` records what was posted.
  Extraction is something that later happened *to* an entry, by a party outside
  the ledger. Writing it back mutates an accounting record to track a delivery
  concern.
- **Keyed by destination.** A single `extracted_at` can answer "was this sent"
  but not "sent to whom". Core banking today; a regulator feed or warehouse
  tomorrow. The composite key costs nothing now.

### `AccountStateCoordinator.query_today_velocity/2` — a dead read

The query filtered `transaction_code == "AUTH_<channel>"`, which
`CMS.LedgerEntry`'s changeset does not permit, against a table authorizations
never post to by design. It returned `{0, 0}` on every call and always would.

**Returning that literally is exactly behaviour-preserving** — no authorization
outcome changes — and it removes a database round-trip per authorization on the
hot path, which `CLAUDE.md` prohibits outright, in service of a constant.

This did **not** require the business decision that was blocking it. Removing a
dead read and fixing velocity are different changes: the defect is still open,
still documented in place, and still needs a decision, because the correct
source (`fas_authorizations`) would start declining transactions that pass today.

---

## 4. What the inversion exposed

Letting the rule decide the accounts is the point of the engine — but it changed
behaviour for callers whose explicit accounts differed from their rule, and made
two latent problems visible.

**1. `CoreBankingAdapter` had never run.** Every entry point raised
`key :id not found`. `CMS.LedgerEntry`'s primary key is `entry_id` and the
schema has no `id` field, yet `build_payload/3` and `mark_extracted/1` both
referenced `e.id`. This is the **third** instance of that exact slip, after
`HCS.ConsolidatedStatementGenerator` (`a.id`) and `CMS.StatementGenerator`.
Rewritten onto `journal_entries`, whose primary key *is* `id`, and verified
against real data: 667 entries across 19 accounts, replay marks zero.

**2. Legacy narratives were being discarded.** `RuleEngine` falls back to the
rule's `narrative_template` when an event carries no narrative, and legacy
callers supply no bindings — so a wallet load recorded the literal string
`"Wallet account load: {channel}"`, placeholder and all, in place of the
narrative the caller wrote. `LegacyEvent` now passes `attrs[:narrative]`
through. Caught by `WalletW1Test` on the first full run after the inversion.

**3. Recovery postings would have credited the wrong account.**
`COL.WriteOffProcessor.post_recovery/3` labels its posting `PAYMENT`, because
`cms_ledger_entries.transaction_code` has no `RECOVERY` member — but a recovery
credits **recovery income** (4004) where a payment credits the **receivable**
(1001). While the caller passed raw account codes that distinction survived by
accident; once the rule decides, it has to be a rule.

Measured against real data before choosing a fix: stored account pairs agree
with their rules everywhere except one anomalous row, so this is a code-path
divergence rather than a data one. Fixed properly — a `RECOVERY` event type, a
rule for each of the four credit-side products, and an **explicit `:event_type`
escape hatch** in `LegacyEvent` for callers whose intent the coarse legacy enum
cannot express. The alternative — letting callers pass raw account pairs — is
exactly the free-for-all that put two conflicting charts into one table.

---

## 5. Tests

C3 raised the setup bar: any test whose subject posts now needs the chart, the
rules, and an **open banking date** for its institution, because the period gate
refuses one that has none. Production gets all three from `seed_gl.exs`; a test
that mints an institution inline has to supply them.

That is the gate doing its job, not an inconvenience — an institution should be
opened for business before it can post — so the tests were updated rather than
the control weakened. `VmuCore.GLFixtures` provides both calls.

Assertions on `dr_amount`/`cr_amount` and `gl_account_dr`/`gl_account_cr` moved
to the journal entry's `amount` and `dr_gl_account`/`cr_gl_account`. Under
double entry the two amounts are equal by construction, so the single field
carries both.

---

## 6. Verified against real data

| | |
|---|---|
| `cms_ledger_entries` after a posting | **unchanged** |
| `journal_entries` after a posting | **+1** |
| Replayed idempotency key | `{:error, :duplicate}` — legacy contract preserved |
| `CoreBankingAdapter.extract_all/1` | 667 entries, 19 accounts, 206ms |
| Replayed extract | 0 entries, 0 accounts |

---

## 7. What remains

`cms_ledger_entries` still exists and still holds 2,272 historical rows. It is
inert: no writer, no reader.

Dropping it is a **data-retention decision**, not an engineering one — the rows
are the only record of pre-engine postings that the backfill did not reproduce
verbatim, and they cost nothing to keep. `CMS.LedgerEntry` is retained as the
schema describing them.
