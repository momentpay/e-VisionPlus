# Koṣa — GL & Posting Module: design and build plan

| Property | Value |
|---|---|
| Date | 2026-08-01 · **Phase A complete 2026-08-03** |
| Status | **Phase A built and tested. Phase 4A (account-code remap) complete. Phase B not started.** |
| Supersedes | The three-way GL merge in [`architecture/Wallet_App_Dependency_Migration.md`](../architecture/Wallet_App_Dependency_Migration.md) §0.2/§0.3/§0.5 |
| Does **not** supersede | §0.4 — the live interest misclassification. Fix that immediately and independently |
| Primary reference | `docs/reference_doc/way4-GL-Implementation.txt` — OpenWay WAY4™ Accounting, R/N 03.48.30 |
| Also references | Koṣa Handbook DOC-109 (Posting), DOC-110 (General Ledger), DOC-109A (Financial Execution) |

---

## 0. Build status (2026-08-03)

Phase A is built, seeded and tested. **22 tests green against real Postgres.** Nothing is wired to live posting paths — `InternalGlPoster` still writes `cms_ledger_entries`, exactly as intended for Phase A.

| Phase | State | Delivered |
|---|---|---|
| **A1** Chart of accounts | done | `gl_accounts` (30 active, 1 retired), `GL.Account`, `GL.ChartOfAccounts`. `normal_balance` derived from class and enforced by a DB check constraint |
| **A2** Posting rules as data | done | `posting_rules` (19 rules), `Posting.Rule`, `Posting.Rules`. Transcribed from live code, not from this document |
| **A3** Posting aggregate | done | `PostingSet → PostingEntry → PostingLeg` + `JournalEntry`. Double entry enforced by a **deferred constraint trigger**, verified by attempting to break it three ways |
| **A4** GL ledger, periods, exceptions | done | `gl_ledger_entries`, `gl_periods` (GiST no-overlap), `gl_banking_dates`, `gl_posting_exceptions`, `GL.Periods` gate |
| **A5** Rule engine | done | `Posting.RuleEngine.execute/1` — event → rule → period gate → set/entry/legs → journal → GL consolidation, one transaction, idempotent |
| **A6** Tests | done | 10 chart/rule integrity + 12 engine tests, real Postgres per `CLAUDE.md` |
| **4A** Account-code remap | done | See [`Phase_4A_Account_Code_Remap.md`](Phase_4A_Account_Code_Remap.md) |
| **B** Shadow mode | **built, off by default** | `GL.InstitutionResolver`, `Posting.Shadow`, `Posting.ShadowDiff`, Shadow Diff admin tab, 14 tests |
| **C** Cutover | not started | Next — one call site at a time, once the diff is clean over real traffic |

### Phase B — how to run it

```elixir
# config/dev.exs
config :vmu_core, VmuCore.Posting.Shadow, enabled: true
```

Every `InternalGlPoster` write is then also mirrored through `RuleEngine` into the new tables. `InternalGlPoster` stays authoritative: `Shadow.mirror/1` runs **after** the real write, always returns `:ok`, and rescues everything — a shadow failure cannot change what the legacy posting returns.

Watch **GL → Shadow Diff**. Cutover is defensible when `mismatch` and `orphan` are zero over a meaningful sample of real traffic. `missing_shadow` is expected for anything posted before the switch was turned on, which is why the diff takes a `since` window.

### Phase B results (2026-08-03)

`mix run priv/repo/gl_shadow_traffic.exs 500` drives postings through the **legacy** poster with shadow on and reports the diff.

| | |
|---|---|
| Posted through `InternalGlPoster` | **500** |
| Matched exactly | **500 (100%)** |
| Mismatched | **0** |
| Missing from shadow | **0** |
| Idempotent replay | 10/10 reported `:duplicate` on both sides |
| Throughput | ~99 postings/sec *including* the shadow write |
| Shadow ledger balance | 373,352.35 debits = 373,352.35 credits |

Across 10 event types and all four products, consolidating into 9 account correspondences per day over 3 days. Trial balance by class comes out correctly signed — assets debit-heavy, liabilities and revenue credit-heavy.

**The one behavioural divergence, and it is deliberate:**

| | |
|---|---|
| Legacy accepted a posting into a **closed period** | yes |
| Shadow accepted it | **no** — quarantined |

`InternalGlPoster` has no concept of an accounting period and will post into a closed one without complaint. The engine refuses and records a `GL_DATE_IN_CLOSED_PERIOD` exception. **This is the control working**, and it is the regulatory exposure the handbook alignment assessment flagged — but Phase C must plan for it, because any current process that back-dates into a closed period will start being refused.

An earlier run made this vivid by accident: dates spread over 6 days crossed into July, which `seed_gl.exs` closes, and the engine correctly quarantined **290 of 600** postings. The traffic script now draws dates from inside the open period and probes the closed-period case explicitly.

**Defect found by the shadow diff — which is the point of Phase B.** `InstitutionResolver` cached only the institution, keyed on account reference. Once an account had been resolved for one product, `resolve/2` returned a hit for *every* product — so a credit account resolved as a debit account, and `FEE` silently failed to mirror while `INTEREST` on the same account succeeded, purely because interest ran first and poisoned the entry. The cache now records which product table the account was found in. A regression test covers it.

**Also shipped:** `VmuCore.GL.ExportMap` (core-banking translation seam), `priv/repo/seed_gl.exs` (idempotent, 7 institutions, 21 periods), and a General Ledger admin screen with Chart of Accounts / Posting Rules / Periods / Exceptions tabs.

### Defects found and fixed while building

| | |
|---|---|
| Interest booked to **4001 Fee Revenue** instead of 4002 | Fixed. Also unblocked `INTEREST` in the adapter's reverse lookup, where it was unreachable because `FEE` returned an identical pair |
| **Two conflicting charts** writing to one table — 2001/2002/4001/5001/5002/1006 each meant two things | Reconciled onto one chart; 16 historical rows migrated with pre-image retained |
| Account **5003** used by live wallet postings, registered in no chart | Found by the FK on `posting_rules`. Registered as retired; wallet moved to 2006 |
| **3002** assigned to a new purpose while `DPS` already used it | Caught before it shipped. Cash clearing moved to 3005; DPS moved onto 3003/3004, which the chart already reserved for it |
| `statement_reversal` reversing interest against **2001 as income** | Corrected to 4002/1003 |
| **11 seed rows violating double entry** (`insert_all` bypasses the changeset) | Seed source fixed and rows repaired. Trial balance now balances: 162,712.24 both sides |

---

## 1. Recommendation

**Build a first-class GL & Posting module natively in `vmu_core`, and retire the three existing implementations into it.** This replaces the proposed three-way merge.

The merge was the wrong shape. It would reconcile two divergent trees plus a dependency that is being deleted, cost real effort, and end with **exactly the architecture we already have** — posting rules hardcoded across seven modules, five account codes in a docstring, no accounting periods, no posting rules as data. All merge cost, no structural gain.

A rewrite converts that same effort into the single highest-leverage change identified in the alignment assessment. It also **dissolves the merge problem** rather than solving it: we harvest from both trees into a new module and delete both sources. There is no reconciliation to get wrong, because nothing is being reconciled.

### 1.1 Why now is unusually favourable

This is the best-resourced moment this work has had, and the inputs will not get better by waiting:

| Input | What it gives us |
|---|---|
| **WAY4 Accounting manual** | A mature, production-proven accounting model from a real card platform — particularly its date semantics and entry-closing model, which are the parts nobody gets right from first principles |
| **Koṣa DOC-109 / DOC-110** | Target-state domain shape: Posting Set → Entry → Leg; Journal → Ledger Account → Period |
| **`WalletGl.ChartOfAccounts`** | A real, working 26-account chart with `owner_app` attribution — becomes seed data instead of a design exercise |
| **`vmu_core`'s `InternalGlPoster`** | 14 posting functions covering credit, debit, prepaid and wallet — proven behaviours to preserve, including idempotency semantics |
| **Avenza's M5 work** | The reconciliation-mirror and drift-check idea, and a documented account-code reconciliation |
| **Known defects** | The interest→4001 misclassification and the hardcoded `× 100` currency assumption — both fixable by design rather than patch |

### 1.2 Why GL is unusually safe to rewrite

Rewriting the money path sounds reckless. For this particular subsystem it is not, because posting has three properties most subsystems lack:

1. **Append-only.** No in-place mutation to migrate.
2. **Self-verifying.** Double entry means the new implementation must balance, and the trial balance is a total check, not a sample.
3. **Shadow-testable.** The old and new implementations can run side by side on real traffic writing to separate tables, and every entry can be diffed before anything is cut over.

That last property is the whole safety argument, and §5 is built on it.

---

## 2. What to take from WAY4, and what to leave

WAY4's model is large and shaped by requirements we do not have — chiefly that it is *subordinate to a bank's core banking system* and must export into it. Copying it wholesale would be a year of work for capability nobody has asked for. The judgement below is the substance of this proposal.

### 2.1 Take

| WAY4 concept | Why | Our form |
|---|---|---|
| **Macrotransaction** (`M_TRANSACTION`) — a generated posting instruction that expands into balanced entries | This is precisely Koṣa's Posting Set and precisely what we lack. It is the thing that makes posting rules data instead of code | `Posting.PostingSet` + a `posting_rules` table |
| **Two entry levels** — Journal Entry (`GL_TRACE`, per contract account) and GL Entry (`GL_TRANSFER`, per GL account, consolidated) | Separates "what happened to this customer's account" from "what the bank's books say". We currently conflate them in one `cms_ledger_entries` table | `Posting.JournalEntry` (subledger) → `GL.LedgerEntry` (consolidated) |
| **Four distinct dates** — Transaction, Posting, Local/GL, Banking | **The single most valuable thing in the reference.** We have one `posting_date`. The reversal case alone justifies it: a reversal posts with the *original* transaction's posting date but records to the GL on the *current* date. Retrofitting this later is painful; designing it in is free | Four columns, defined once in §4.3 |
| **Banking date + GL entry closing** | This is the accounting period the assessment flagged as a regulatory exposure. Open → Extracted → Closed, with turnover updated on close | `GL.BankingDate`, `GL.Period` |
| **GL Trace Exceptions** — entries whose GL date falls in a closed period | An excellent operational control, and nearly free once periods exist. WAY4's rule is that this table should always be empty in a healthy system | `GL.PostingException` + an ops screen |
| **Chart of Accounts as data**, with asset/liability classification and account masks | Already have the content; needs a table and a registry API | `gl_accounts` seeded from the 26 |
| **Entry codes / descriptions derived from transaction type and account correspondence** | Makes narratives configurable rather than string-built at each call site | Part of the posting rule |

### 2.2 Leave

| WAY4 concept | Why not |
|---|---|
| **Subsidiary GL account** (the third, middle level) | Exists so WAY4 can mirror a bank's CBS chart of accounts. We have no CBS to mirror. **Design the model so it can be inserted later** — a bank customer wanting CBS export will need it — but do not build it now |
| **UFX export pipes / CBS export** | No integration requirement today. The closing model is built; the export is not |
| **Contract account hierarchy** (Main/Sub, Liability) | We already express this differently, via HCS company → employee/fleet cards. Do not import a second hierarchy concept |
| **Time zones, interbranch entries** | Single-region today |
| **The global-parameter surface** (`INTEREST_DELAY`, `PAYMENT_DUE_ADVANCE`, `DUE_TO_WRK_DAY`, `POST_DUE`, `INTEREST_IN_CYCLE`, …) | Our equivalent is the SYS→BANK→LOGO→BLOCK cascade. Map the handful we actually need into it; do not reproduce the catalogue |

---

## 3. Scope boundary — Posting vs General Ledger

Koṣa separates these into two domains (DOC-109, DOC-110) and WAY4 separates them too (macrotransaction/journal entry versus GL entry). We follow that split as **two namespaces in one module tree** — not two applications, which would be speculative before either exists.

```
lib/vmu_core/gl/
├── posting/            VmuCore.Posting.*   — DOC-109
│   ├── posting_set.ex          the aggregate: one financial execution
│   ├── posting_entry.ex        one balanced Dr/Cr pair within a set
│   ├── posting_leg.ex          one directional movement
│   ├── posting_rule.ex         rule as data: event type → legs
│   ├── rule_engine.ex          expands a business event into a PostingSet
│   └── journal_entry.ex        subledger: per product-account activity
│
└── ledger/             VmuCore.GL.*        — DOC-110
    ├── chart_of_accounts.ex    registry: register/2, valid?/1, classification
    ├── account.ex              gl_accounts schema
    ├── ledger_entry.ex         consolidated GL entry
    ├── banking_date.ex         current banking date, open/close
    ├── period.ex               accounting period lifecycle + locking
    ├── posting_exception.ex    GL-date-in-closed-period control
    └── trial_balance.ex        (port the existing one — it works)
```

**Ownership rule, stated so it is enforceable:** `VmuCore.Posting` is the **only** writer of journal and ledger entries. No other module posts. Every current posting call site becomes a caller of `Posting.execute/1` with a business event, not a builder of ledger rows.

That single rule is what closes the top finding in the alignment assessment.

---

## 4. Model sketch

### 4.1 The flow

```
business event  →  PostingRule lookup  →  PostingSet (balanced, validated)
                                              │
                            ┌─────────────────┴─────────────────┐
                            ▼                                   ▼
                    JournalEntry rows                    GL LedgerEntry rows
                 (per product account,                 (per GL account, consolidated
                  the subledger)                        by account correspondence + GL date)
```

### 4.2 Posting rules as data

The current 14 `InternalGlPoster` functions each hardcode an account pair and a narrative. Those become **rows**, seeded from the existing functions so behaviour is preserved exactly:

| event_type | product | debit | credit | narrative template |
|---|---|---|---|---|
| `PURCHASE` | CREDIT | 1001 | 2001 | `Purchase {merchant}` |
| `INTEREST` | CREDIT | 2001 | **4002** | `Interest {cycle}` |
| `FEE` | CREDIT | 2001 | 4001 | `{fee_type} fee` |
| `DEBIT_DEPOSIT` | DEBIT | … | … | … |

Note the `INTEREST` row is where the §0.4 defect stops being possible: the mapping is data, reviewable in one place, rather than a function clause in one of seven modules.

### 4.3 The four dates — defined once

| Date | Meaning | Set by |
|---|---|---|
| `transaction_date` | When the transaction actually happened | The source document / network |
| `posting_date` | When the financial consequence takes effect. Drives FX rule selection, fee calculation, interest cycle start. **For a reversal, this is the original entry's posting date** | Business rule |
| `gl_date` | When it lands on GL accounts. Normally equals the banking date. **For a reversal, this is the current banking date, not the original** | The posting engine |
| `banking_date` | The current open banking day | `GL.BankingDate` |

If `gl_date` falls before the last close point, the entry is written to `posting_exceptions` rather than silently landing in a closed period.

### 4.4 Money

`Decimal` end to end, with **currency minor-unit scale resolved from the chart of accounts / currency table**, never a hardcoded `× 100`. This removes the latent KWD/BHD/OMR (3-decimal) and JPY (0-decimal) defect by construction rather than by patch.

---

## 5. Migration strategy — shadow, compare, cut over

The safety of this whole proposal rests here.

### Phase A — Build, wired to nothing
New module, new tables (`posting_sets`, `posting_entries`, `posting_legs`, `posting_rules`, `journal_entries`, `gl_accounts`, `gl_ledger_entries`, `gl_periods`, `posting_exceptions`). Chart of accounts seeded from the 26. Posting rules seeded from the 14 existing functions. Unit tests only. **Nothing in production changes.**

### Phase B — Shadow mode
Every existing posting call *also* calls `Posting.execute/1`, writing to the new tables. The old path remains authoritative. A comparison job diffs old versus new continuously: same accounts, same amounts, same idempotency keys, same totals.

**This is where correctness is actually established** — on real traffic, against real data, with no risk, for as long as it takes to build confidence. It is the same discipline that has repeatedly caught real bugs in this codebase: verify against real data, never against config alone.

### Phase C — Cut over, one call site at a time
Seven call sites, **lowest volume and lowest blast radius first** — `lms/gl_provisioner`, then `its/*`, then `col/write_off_processor`, then `hcs`, then `cms/purchase_posting`, then `fas/settlement_posting_adapter`, and `cms/internal_gl_poster` last. Each cutover is one commit, independently revertible, verified against the shadow diff before and after.

### Phase D — Retire
Delete `InternalGlPoster`, `FAS.GL.VmuCoreGlAdapter`, `CardAccountCodes`, and the `wallet_gl` / `wallet_shared_kernel` dependencies. At this point [`Wallet_App_Dependency_Migration.md`](../architecture/Wallet_App_Dependency_Migration.md) reduces to deleting six `mix.exs` lines, because its hard parts have been absorbed here.

### Phase E — The capability that never existed
Accounting periods with open/close/lock, the GL-date exception control, and an ops screen for both. This is net-new — the regulatory exposure the alignment assessment flagged — and it is deliberately **last**, so it lands on a foundation that is already proven rather than on a rewrite in flight.

---

## 6. Risks, honestly

| Risk | Mitigation |
|---|---|
| **It is the money path** | Shadow mode (Phase B) means correctness is proven on real traffic before anything cuts over. No phase is irreversible |
| **Scope creep into WAY4's full model** | §2.2 is an explicit "leave" list. The subsidiary-GL middle layer is the one deliberately designed *for* but not built |
| **Losing behaviour encoded in the 14 existing functions** — idempotency keys, `on_conflict`, Decimal handling | Seed the rules **from** those functions rather than from the reference document. The shadow diff catches any divergence |
| **This becomes a reason to defer the live interest bug** | It must not. §0.4 of the migration doc is a two-line fix; ship it this week, independently |
| **Avenza diverges further while this is built** | Avenza's GL is superseded by this work. Once Phase A lands, stop reconciling against it — say so explicitly, or the eleventh instance of merge drift becomes the twelfth |

---

## 7. What this changes elsewhere

| Document | Change |
|---|---|
| [`Wallet_App_Dependency_Migration.md`](../architecture/Wallet_App_Dependency_Migration.md) | §0.2, §0.3, §0.5 superseded — no three-way merge, no `ChartOfAccounts` port, no Avenza reconciliation. §0.4 stands |
| [`Kosa_Handbook_Alignment_Assessment.md`](../compare/Kosa_Handbook_Alignment_Assessment.md) | Tier-1 items **A1** (no Posting domain) and **A2** (chart of accounts, periods) are both addressed by this single piece of work |
| [`Kosa_Domain_Ownership_Map.md`](../architecture/Kosa_Domain_Ownership_Map.md) | §4.1 "Posting has no owner" gets an owner |
| [`decisions/README.md`](../decisions/README.md) | Needs a new ADR recording this decision, and it supersedes VMU-ADR-011/012 outright |

---

## 8. Open questions for review

1. **Subledger scope.** Should `JournalEntry` cover every product account (credit, debit, prepaid, wallet, loyalty), or start with card products only? Recommendation: all of them — the 14 existing functions already span them, so the coverage exists and splitting it would create a second posting path.
>> Answer: We should add for all 
2. **Banking date granularity.** One global banking date, or per-SYS/BANK in the parameter cascade? WAY4 is per-institution. Recommendation: per-BANK, since EOD already runs per-institution.
>> Answer: Agree, It should be per-BANK
3. **Do we keep a reconciliation mirror at all?** Avenza's mirrored into `WalletGl.GlPostingStore`, which is being deleted. Recommendation: drop the mirror, keep the *idea* as a native drift check between the subledger and the GL — which is what it was really for.
>> Answer: Agree
4. **Timing.** This is materially larger than the wallet-app removal it replaces. It should be sized against Way4 parity Phase 2/3 rather than slotted in beside a dependency cleanup.
>> Answer: Agree
