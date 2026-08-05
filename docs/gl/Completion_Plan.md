# Koṣa — completion plan

| Property | Value |
|---|---|
| Date | 2026-08-05 |
| Baseline | `compare/Kosa_Handbook_Alignment_Assessment.md` (2026-08-01) |
| Purpose | What the GL programme closed, what it did not, and what to do next |

---

## 1. Where GL stands

| | Status |
|---|---|
| **C1** — engine authoritative for writes | done, all 5 products |
| **C2** — migrate readers off `cms_ledger_entries` | **done 2026-08-05** — 18 call sites across 16 modules; 2 readers deliberately not migrated |
| **C3** — stop writing the legacy table, delete `InternalGlPoster` | **blocked on those 2** |

C2 is complete for every reader that *can* migrate. Two remain, each blocked on something real rather than on effort — see `Phase_C2_Reader_Migration.md` §6:

| Reader | Blocked on |
|---|---|
| `CMS.CoreBankingAdapter` | needs a per-posting-set extraction-state table; `gl_ledger_entries.extracted_at` is the wrong grain |
| `CMS.AccountStateCoordinator.query_today_velocity/2` | the query is **dead** and fixing it changes authorization outcomes — a business decision |

**HCS was on this list and should not have been.** The claim that it was invisible to the posting engine rested on a query that counted `product = "HCS"` — a product that does not exist. HCS cards hang off real `cms_accounts` rows and had 135 journal entries all along, matching their 135 legacy rows exactly. Both readers migrated 2026-08-05. See `Phase_C2_Reader_Migration.md` §6a.

### C2 found a real accounting defect

`RuleEngine.consolidate/4` accumulated the GL with a read-modify-write, and lost updates under concurrency: `journal_entries` totalled 1,737,568.84 against `gl_ledger_entries`' 1,728,263.33, a **9,305.51 shortfall over 19 postings**. The journal — the customer-facing view — was correct throughout; only the bank's books were short, and nothing raised. Fixed with an atomic upsert, historical rows repaired, invariant now asserted by tests.

**This is the argument for finishing C3 rather than living with two ledgers.** The defect was invisible for as long as nothing compared the two representations. The trial balance found it in its first run.

### What C3 needs

1. Build the `CoreBankingAdapter` extraction-state table (small, self-contained).
2. Get a decision on the velocity defect.
3. Then stop writing `cms_ledger_entries` and delete `InternalGlPoster`.

### HCS is now a first-class product (2026-08-05)

Migrating the HCS readers exposed a modelling gap rather than a blocker: HCS
posted to the **consumer** card accounts `1001`/`2001`, so corporate fleet
exposure was indistinguishable from a consumer credit card on the balance
sheet — while the two HCS accounts already in the chart had never received a
posting.

HCS now carries the same six concerns every other product does: chart accounts
(`1006`, new `1009`, `2002`), 16 posting rules across `HCS_FLEET` and
`HCS_CORPORATE`, a resolver overlay, a `Cutover` entry, seed data, and tests.
**That set is the template for adding the next product.**

---

## 2. What the GL programme actually closed

Measured against the assessment's Tier 1, not asserted:

| | Assessment said | Now |
|---|---|---|
| **A1 — no Posting domain** | *"posting rules hardcoded across seven modules… highest-leverage fix in the entire list"* | **Closed.** `Posting.RuleEngine`, `PostingSet → Entry → Leg`, 24 rules as data, DB-enforced double entry |
| **A2 — no chart of accounts as data, no accounting period** | *"five codes in a docstring… audit exposure with a regulatory edge"* | **Closed.** `gl_accounts` (30), `gl_periods` with open/close/lock, banking dates, closed-period exception quarantine |
| **A3 — configuration not versioned or effective-dated** | *"retrofit cost grows with every product added"* | **Open.** Verified: 0 such columns across all four parameter tables |
| **A4 — no Decision Record pattern** | *"ten-plus domains require it; one JSONB column exists"* | **Open.** 5 decision columns exist, all ad-hoc, no shared pattern |
| **A5 — spine is card-shaped, not rail-independent** | deliberately deferred | **Still deferred** — correctly. Trigger is a committed second rail |

Two of four Tier-1 patterns closed, including both of the ones called highest-leverage.

### Also delivered along the way

**Fifteen real defects**, none of which were on any plan.

From Phases A–C1: the interest→4001 misclassification, two conflicting charts writing one table, account `5003` used but registered nowhere, my own `3002`/DPS collision, `statement_reversal` treating a liability as income, 11 seed rows violating double entry, statement generation broken by a schemaless UUID cast **and** a call to a function that never existed, and a `posting_rules` coverage gap that only a history backfill could have exposed.

From C2 (see `Phase_C2_Reader_Migration.md` §4): **the GL losing writes under concurrency** — a 9,305.51 shortfall the trial balance found on its first run; the legacy console's fee-waiver screen having never worked at all; the trial balance naming 5 accounts of 30 and summing every institution together; adjustment direction inferred from a GL account code; a dead `compile_env` injection seam in `PromiseVerification`; and the dormancy sweep asking about every product's activity rather than its own.

Plus: the admin menu standard, `config/test.exs` no longer binding production ports, a shared `GLFixtures` test helper that closes a class of silently-passing test, and a fully green suite (692 tests, nothing excluded) where three test files had been silently stale or non-compiling.

---

## 3. What remains, in priority order

### Now — finish what is started

**C3**, and the three C2 stragglers it depends on. See §1. Nothing else should start first — two dual-written ledgers is the state in which the concurrency defect above stayed invisible.

### Next — A3, effective-dated configuration

Still the retrofit whose cost compounds. It is also a **prerequisite** for three Tier-2 domains: Tax, Pricing and a Fee catalog all need "what did this rule say on date X".

Doing it after Tax rather than before means building Tax twice.

### Then — Tax (Tier 2, B1)

The hard regulatory blocker for GCC/India go-live. Small and self-contained once A3 exists: Catalog → Rule → Result → Exemption, the same shape the handbook uses for Fee, Pricing and Interest.

### Then — Fraud operations (Tier 2, B2)

Detection already exists in `mw_risk` and is wired into the auth path. What is missing is the operational half: alerts, cases, investigation workflow, analyst UI. **This is not a detection-engine build**, and scoping it as one would be a large and unnecessary project.

### Then — Limit Management as a domain (Tier 2, B3)

The capability exists five times over in five product silos. Consolidating it is what makes cross-product customer exposure answerable — currently it is not.

### Interleave — A4, Decision Records

Small, additive, no dependencies. Generalise FAS's `decision_path` into a shared concern and apply it to Limits and Risk as the first consumers. Cheapest of the four Tier-1 patterns and the one that gets more expensive per domain added.

### Later — Pricing (B4), Treasury (B5)

Pricing should follow Fee's restructure so the two share a shape. Treasury is needed before Settlement can be built properly, but nothing forces it yet.

---

## 4. Housekeeping still open

| | |
|---|---|
| **Party registry orphan** | Still 7 tables with **zero Elixir code**, verified today. Either finish the port or drop the migrations — leaving schema-without-code invites someone to assume the feature exists. A decision, not a build |
| **`CLAUDE.md` is badly stale** | Still describes the project at "Phase 0" with five files built, and an 11-app umbrella that was never created. It is the first thing a new developer or agent reads |
| **Handbook index drift** | `README.md` / `DOC-100` still describe a superseded 15-document set. Reported; the architecture team's call |

`CLAUDE.md` is the highest-value of these and the cheapest.

---

## 5. What I would not do next

**Not the rail-independence extraction (A5).** It remains correct to wait for a committed second rail. The A2A/Instant Payments vendor decision is the trigger; doing it speculatively means restructuring the two best-working parts of the codebase with no forcing requirement.

**Not new domain docs.** Per VMU-ADR-002 the handbook is advisory and the channel is one-directional. Publishing as-built documents is the obligation; writing more target-state prose is the architecture team's job.

**Not the `vmu_core` → Koṣa code rename.** VMU-ADR-003 deferred it indefinitely and nothing has changed.

---

## 6. Recommended sequence

```
1. GL C2 — migrate readers            ✅ done 2026-08-05
2. GL C3 — retire cms_ledger_entries   (3 blockers first: extraction-state
                                         table, HCS posting rules, velocity
                                         decision)
3. A3    — effective-dated config      (prerequisite for 4 and 6)
4. Tax                                  (regulatory blocker)
5. A4    — Decision Records             (interleave; small)
6. Fraud operations                     (ops half only, not detection)
7. Limits as a domain
8. Pricing, Treasury
```

Step 2 is finishing work. Step 3 is the last compounding-cost item. Everything from 4 onward is net-new capability and can be reordered on business priority without penalty.
