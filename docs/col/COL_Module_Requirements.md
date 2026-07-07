# COL — Collections & Recovery: Module Requirements

**Status:** 📝 Draft for review — drafted from VisionPlus collections domain knowledge, cross-checked against `lib/vmu_core/col/`. Validate strategies/bucket policy with SME/business before implementation planning.

---

## 1. Purpose & Scope

COL manages **delinquent accounts from first missed payment through recovery or write-off**: queueing by days-past-due (DPD), collector workflows, promises to pay, hardship/workout plans, agency placement, write-off, and post-write-off recoveries. CMS owns the delinquency *state* (bucket aging in EOD); COL owns the *treatment*.

## 2. Where COL Sits

| Direction | Module | Contract |
|---|---|---|
| ← CMS | Delinquency | EOD bucket roll creates/updates collection cases by DPD |
| ← DPS | Exclusion | Open-dispute transactions excluded from collection pressure |
| → CMS | Financial | Write-off posting, recovery posting, payment-plan restructure |
| → Letters/Comms | Dunning | Letter/SMS/email triggers per strategy step |
| → CDM | Feedback | Collection outcome feeds behavioral scoring |
| → Bureau | Reporting | Charged-off status in Metro2 |

## 3. VisionPlus Feature Inventory

### 3.1 Case Management (FR-COL-001 … 010)

| FR | Feature | Notes |
|---|---|---|
| 001 | Auto case creation on delinquency (DPD threshold per product) | |
| 002 | DPD buckets: 1–29, 30, 60, 90, 120, 150, 180+ with bucket-roll history | schema has 30/60/90/120 |
| 003 | Queue segmentation: bucket × balance band × risk score × product | |
| 004 | Collector assignment (individual + team + capacity rules) | |
| 005 | Case notes, contact history (call outcomes, right-party-contact) | |
| 006 | Promise to pay: amount + date, kept/broken tracking, auto-verification against payments | schema has promise fields |
| 007 | Next-action scheduling + follow-up work queues | |
| 008 | Case statuses: OPEN / PROMISED / WORKOUT / AGENCY / WRITTEN_OFF / RECOVERED / CLOSED | implemented |
| 009 | Cure detection: payment clears past-due → case auto-close + bucket reset | |
| 010 | Legal-track flag + litigation hold | |

### 3.2 Strategies & Dunning (FR-COL-011 … 017)

| FR | Feature | Notes |
|---|---|---|
| 011 | Strategy engine: per bucket/segment → ordered treatment steps (SMS day 3, call day 7, letter day 15 …) | |
| 012 | Dunning letter generation per bucket with templates | `dunning_job.ex` exists |
| 013 | Contact-frequency caps (regulatory harassment limits) | |
| 014 | Hardship/workout plans: restructure, reduced APR, payment holiday — with approval levels | |
| 015 | Settlement offers (lump-sum discount) with authority matrix | |
| 016 | Self-cure carve-out (low-risk early bucket gets no outreach for N days) | |
| 017 | Block-code application per bucket (C-block at 30 DPD etc.) | |

### 3.3 Agency, Write-off & Recovery (FR-COL-018 … 025)

| FR | Feature | Notes |
|---|---|---|
| 018 | Agency placement: assignment file out, activity/payment file in, commission accounting | |
| 019 | Agency recall + churn between agencies | |
| 020 | Write-off at policy DPD (typically 180) with approval + GL posting | `write_off_processor.ex` exists |
| 021 | Post-write-off recovery ledger (payments against charged-off principal) | |
| 022 | Recovery agency / debt-sale processing | |
| 023 | Interest/fee suppression post charge-off | |
| 024 | Deceased/bankruptcy special handling (proof-of-claim, stop-collection) | |
| 025 | Collections MI: roll rates, cure rates, promise-kept %, recovery % | Roadmap Phase 8 |

## 4. Current Implementation Map (`lib/vmu_core/col/`)

| File | Covers |
|---|---|
| `collection_case.ex` | Case schema (`col_collection_cases`): bucket, outstanding, status, assignment, promise, write-off fields |
| `collection_queue_job.ex` | Queue/bucket processing job |
| `dunning_job.ex` | Dunning letter trigger job |
| `write_off_processor.ex` | Write-off processing |

## 5. Gap Analysis (initial — verify during planning)

| Area | Assessment |
|---|---|
| Case schema, queue job, dunning job, write-off | ✅ Exist (depth/strategy unverified) |
| Strategy engine (FR-011) — treatments are likely hardcoded in jobs | 🔄 verify |
| Contact history / call outcomes (FR-005) | ⬜ Not found |
| Promise auto-verification against payments (FR-006b) | ⬜ verify |
| Hardship/workout plans (FR-014), settlement offers (FR-015) | ⬜ `workout_plan_id` field exists; no plan module |
| Agency placement files (FR-018/019) | ⬜ `assigned_to` field only |
| Post-write-off recovery accounting (FR-021–023) | ⬜ Not found |
| Dispute exclusion (DPS link) | ⬜ Not found — should check open disputes before escalation |
| Ops UI (Roadmap 6.13–6.16) | ⬜ Pending |

## 6. Open Questions

1. Bucket/strategy policy matrix per product (business input — drives the strategy engine design).
2. Agency file formats (per agency) and commission terms.
3. Write-off DPD + approval matrix; regulatory provisioning interplay (IFRS 9 staging?).
4. Regulatory contact caps in target market(s).
