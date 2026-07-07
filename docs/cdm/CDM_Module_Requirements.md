# CDM — Credit Decision Management: Module Requirements

**Status:** 📝 Draft for review — drafted from VisionPlus credit-decisioning domain knowledge, cross-checked against `lib/vmu_core/cdm/` and the mw_risk integration (FAS-P2). Validate scorecards/policy with credit-risk SME before implementation planning.

---

## 1. Purpose & Scope

CDM makes the **credit decisions**: application approval at origination, initial limit assignment, ongoing behavioral rescoring, limit increases/decreases, and authorization-strategy inputs. It consumes bureau + internal behavior; it writes limits and risk grades back to CMS.

**Boundary:** *transaction-time fraud/risk scoring* is mw_risk (wired into FAS, FAS-P2). CDM is *account-level credit risk* on slower cycles (origination, monthly review).

## 2. Where CDM Sits

| Direction | Module | Contract |
|---|---|---|
| ← CIF | Applicant | Identity, employment/income, existing exposure |
| ↔ Bureau | Scores | Application pull + monthly refresh (`bureau_adapter.ex`) |
| → CMS | Limits | Initial limit at booking; limit change via `AccountStateCoordinator.refresh_limit` |
| ← CMS/COL | Behavior | Utilization, payment behavior, delinquency history feed rescoring |
| → FAS (indirect) | Strategy | Risk grade can drive auth strategy parameters (STIP limits, overlimit tolerance) |

## 3. VisionPlus Feature Inventory

### 3.1 Origination (FR-CDM-001 … 010)

| FR | Feature | Notes |
|---|---|---|
| 001 | Application intake: applicant data, product requested, channel | |
| 002 | Application dedupe + existing-customer detection (CIF) | |
| 003 | Bureau pull: score + tradelines + inquiries | `bureau_adapter.ex` |
| 004 | Application scorecard: bureau + demographic + affordability variables | `application_scorer.ex` |
| 005 | Policy rules (knockouts): age, income floor, DBR/DTI cap, blacklist, sanctions | |
| 006 | Decision outcomes: APPROVE / DECLINE / REFER (manual review queue) | |
| 007 | Initial limit allocation: score band × income multiple × product caps | `limit_allocator.ex` |
| 008 | Manual override with reason + authority level (4-eyes above threshold) | Roadmap 6.19 |
| 009 | Adverse-action reason codes for declines (regulatory) | |
| 010 | Application audit trail: inputs, score, rules fired, decision, operator | |

### 3.2 Portfolio Management (FR-CDM-011 … 020)

| FR | Feature | Notes |
|---|---|---|
| 011 | Behavioral scoring: monthly rescore from utilization/payment/delinquency | `behavioral_rescorer.ex` |
| 012 | Auto limit increase program: eligibility rules + offer + acceptance | |
| 013 | Limit decrease / line management on risk deterioration | rescorer applies actions |
| 014 | Account restriction action (block on severe deterioration) | rescorer calls `notify_status_change` |
| 015 | Bureau refresh cadence + trigger-based repull | |
| 016 | Customer-level exposure control across accounts (CIF roll-up) | depends on CIF FR-022 |
| 017 | Cross-sell / pre-approval lists | |
| 018 | Risk-grade migration reporting (vintage, roll rates) | Roadmap Phase 8 |
| 019 | Champion/challenger strategy testing | |
| 020 | Model governance: scorecard versioning, monitoring (PSI/KS), re-validation trail | |

## 4. Current Implementation Map (`lib/vmu_core/cdm/`)

| File | Covers |
|---|---|
| `application_scorer.ex` | Application scoring |
| `limit_allocator.ex` | Initial limit assignment |
| `behavioral_rescorer.ex` | Monthly rescore + limit/restriction actions — **known issue:** calls `VmuCore.Shared.AccountStateCoordinator.notify_status_change/2` and `refresh_limit/2` under the wrong namespace (module lives at `VmuCore.CMS.AccountStateCoordinator`) — compile warning today, runtime crash when invoked |
| `bureau_adapter.ex` | Bureau integration |
| mw_risk (external umbrella) | Transaction-time risk — separate concern, already wired to FAS |

## 5. Gap Analysis (initial — verify during planning)

| Area | Assessment |
|---|---|
| Application scoring, limit allocation, behavioral rescorer, bureau adapter | ✅ Exist (depth unverified) |
| **Namespace bug in `behavioral_rescorer.ex`** | ❌ Fix required before rescorer actions can run |
| Application entity/workflow (intake → decision → booking, REFER queue) | ⬜ Scorer exists; no application schema/queue found |
| Policy knockout rules (FR-005), adverse-action codes (FR-009) | ⬜ verify inside scorer |
| Auto limit-increase offers (FR-012) | ⬜ Not found |
| Customer-level exposure control (FR-016) | ⬜ blocked on CIF roll-up |
| Model governance (FR-020) | ⬜ Not found |
| Ops UI: scoring log, review queue, manual override (Roadmap 6.17–6.19) | ⬜ Pending |

## 6. Open Questions

1. Origination in v1 scope? (If accounts are booked via migration/ops only, application workflow can defer.)
2. Bureau(s) per market + pull cost constraints (drives refresh cadence).
3. Limit-increase regulatory rules (opt-in required in some markets).
4. Scorecard ownership: internal models vs bureau generic scores at launch.
