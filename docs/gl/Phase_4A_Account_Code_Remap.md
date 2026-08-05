# Phase 4A — Account-code remap onto the reconciled chart

| Property | Value |
|---|---|
| Date | 2026-08-02 |
| Status | **Planned, ready to execute** |
| Decision | [VMU-ADR-005](../decisions/005-stored-value-liability-treatment.md) — stored value is a liability |
| Why now | The two blockers I raised against doing this immediately **do not survive contact with the data** — see §1 |

---

## 1. Correction: the blockers I raised were not supported by the data

When VMU-ADR-005 was written I recorded two reasons this could not be executed yet. Both were reasonable concerns and **both turned out to be wrong at current scale.** Checking rather than assuming reversed the conclusion:

### 1.1 "The core banking export is an external contract"

`CMS.CoreBankingAdapter` does export `gl_account_dr`/`gl_account_cr` to a bank's core banking system. But:

- **`config :vmu_core, :core_banking_adapter` is not set in any config file.** The adapter has never been configured for `:http`, `:file` or `:kafka` mode.
- **`SELECT count(*) FROM cms_ledger_entries WHERE extracted_at IS NOT NULL` returns 0.** Not one row has ever been extracted, in any environment.

**No bank has ever received a GL extract from this system.** There is no established contract to break. The argument therefore inverts: fixing the chart now means the first extract a bank ever receives is already correct. Every day of delay makes this strictly worse, never better.

### 1.2 "Historical rows become ambiguous at the cutover"

`cms_ledger_entries` holds **30 rows**, spanning 2026-03-16 to 2026-07-28, across 19 accounts. It is dev and seed data, not production history. Migrating 30 rows is trivial; regenerating them is also viable.

### 1.3 What the data did reveal

The breakdown surfaced posting variants present in **neither** code set:

| transaction_code | Dr / Cr | Rows | Note |
|---|---|---|---|
| DISPUTE_CREDIT | 3001 / 1001 | 9 | `CardAccountCodes` says 2001/1001 — a third variant |
| PURCHASE | 1001 / 2001 | 7 | matches |
| DEPOSIT | 1006 / 5001 | 3 | debit stored value |
| DEPOSIT | 1006 / 5002 | 3 | prepaid stored value |
| ADJUSTMENT | 1001 / 9001 | 2 | in neither code set |
| FEE | 1004 / **4001** | 1 | `InternalGlPoster` posts 1004/**2002** — already divergent |
| INTEREST | 1003 / **4002** | 1 | already using the corrected account |
| INTEREST | 1003 / **2001** | 1 | the old mapping — both variants coexist |
| CASH_ADV | 1002 / 2001 | 1 | matches |
| PAYMENT | **2001** / 1001 | 1 | `InternalGlPoster` posts **3001**/1001 |
| ADJUSTMENT | 5001 / 1001 | 1 | 5001 as a debit against a receivable |

Two conclusions. First, the ledger is **already internally inconsistent** — this is not a clean state being disturbed. Second, some rows were written outside the posting functions (seed data inserted directly), so the migration must key on the actual stored pair, not on what a function would have produced.

No `5003` rows exist: wallet has never posted.

---

## 2. Scope

**53 modules reference `LedgerEntry` or `InternalGlPoster`.** Most only read. **14 hold hardcoded 4-digit account codes:**

| File | Codes |
|---|---|
| `cms/internal_gl_poster.ex` | 26 |
| `fas/gl/card_account_codes.ex` | 6 |
| `dps/dispute.ex` | 6 |
| `lms/gl_provisioner.ex` | 4 |
| `col/write_off_processor.ex` | 4 |
| `cms/payment_reversal.ex` | 4 |
| `col/settlement_command.ex` | 3 |
| `cms/statement_reversal.ex` | 2 |
| `cms/payment_intake.ex` | 2 |
| `cms/financial_adjustment.ex` | 2 |
| `cms/credit_balance_refund.ex` | 2 |
| `asm/operator_portal.ex` | 2 |
| `fas/gl/trial_balance.ex` | 1 |
| `vmu_core_web/live/admin/account_component.ex` | 1 |

Note `asm/operator_portal.ex` and `account_component.ex` — GL codes have leaked into the operator UI layer.

---

## 3. The remap

| From | To | Meaning |
|---|---|---|
| `5001` (as stored value) | **2004** | Debit Deposit Liability |
| `5002` (as stored value) | **2005** | Prepaid Stored-Value Liability |
| `5003` | **2006** | Wallet Stored-Value Liability |
| `1006` (as cash clearing) | **3002** | Bank Cash / Funding Clearing |
| `2001` (as interest income) | **4002** | Interest Income |
| `2002` (as fee income) | **4001** | Fee Revenue |
| `4001` (as interchange income) | **4003** | Interchange Income |

**Context-dependent, not a blind find-and-replace.** `5001` is Interchange/MDR Expense when FAS uses it and Debit Deposit Liability when `InternalGlPoster` uses it; `1006` is a real HCS receivable in `hcs/*`. Each site is remapped by *meaning*, verified against `posting_rules`.

---

## 4. Steps

Each independently committable and verifiable.

| # | Step | Verification |
|---|---|---|
| **4A.1** | **Export mapping layer** in `CoreBankingAdapter`: internal code → exported code, defaulting to identity. Built even though nothing is live, because it is the seam that lets the internal chart and a bank's chart diverge later without a second remap. This is WAY4's own GL-account-plan-to-CBS mapping | Extract payload renders through the map; identity map produces byte-identical output |
| **4A.2** | **Remap `InternalGlPoster`** — 26 codes, the largest single site | Each pair matches its `posting_rules` reconciled pair |
| **4A.3** | **Remap the remaining 12 modules** by meaning, one commit per module | No hardcoded 4-digit code outside `VmuCore.GL` and the legacy-mapping table |
| **4A.4** | **Migrate the 30 historical rows**, keyed on the stored pair plus `transaction_code`, with the pre-image retained | Row count unchanged; every `gl_account_dr`/`cr` resolves to an active `gl_accounts` row; totals per account reconcile to the pre-image |
| **4A.5** | **Clear the reconciliation state** — `posting_rules.legacy_*` set to NULL, `gl_accounts.legacy_conflict` cleared, `5003` retired | `Rules.pending_cutover/0` and `ChartOfAccounts.conflicts/0` both return `[]` |
| **4A.6** | **Add a guard test** — fails if any 4-digit GL code appears outside the GL module | Test present and passing |

### 4.1 Why the export layer comes first

It is the only step that is *not* reversible by a later code edit: once a bank starts receiving extracts, the codes in them are fixed. Building the indirection before the first extract costs almost nothing; retrofitting it afterwards means renegotiating an integration.

---

## 5. Risks

| Risk | Mitigation |
|---|---|
| A code is remapped by pattern rather than by meaning | Remap per module against `posting_rules`, never by global replace. `5001` and `1006` each mean two different things depending on the caller |
| The 11 rows in variants belonging to no code set | Migrate on the stored pair, not on what a function would emit. Rows whose pair matches no rule are listed for review rather than guessed at |
| Downstream readers key on old codes | `fas/gl/trial_balance.ex` and the two UI files are in the 14 and are remapped with the rest |
| A future module reintroduces a hardcoded code | 4A.6's guard test |

---

## 6. What this does not do

Phase 4A remaps the **existing** posting paths onto the reconciled chart. It does **not** move them onto the new Posting/GL module — call sites still call `InternalGlPoster` and still write `cms_ledger_entries`.

That migration remains Phase B/C of [`GL_Module_Design_and_Plan.md`](GL_Module_Design_and_Plan.md). Doing 4A first is what makes it simpler: the shadow diff then compares two implementations using **one** chart of accounts, instead of also having to reconcile codes at the same time.
