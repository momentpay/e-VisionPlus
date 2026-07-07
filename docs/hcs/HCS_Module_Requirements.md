# HCS — Head/Corporate Card Services: Module Requirements

**Status:** 📝 Draft for review — drafted from VisionPlus corporate-card domain knowledge, cross-checked against `lib/vmu_core/hcs/`. Validate corporate product design with business before implementation planning.

---

## 1. Purpose & Scope

HCS runs **corporate card programs**: a company entity with a central credit facility, employee cards issued under it, hierarchical limit control (company → department → employee), spending controls, consolidated company statements, and central payment (company pays, not the employee).

## 2. Where HCS Sits

| Direction | Module | Contract |
|---|---|---|
| ← CIF | Company | Corporate customer (tier BUSINESS/CORPORATE) is the contracting entity |
| → CMS | Accounts | Employee cards are CMS accounts under company umbrella; company facility caps them |
| → CTA | Issuance | Bulk/individual employee card issuance |
| ← FAS | Authorization | Spending controls evaluated at auth (MCC/channel/amount per employee card) |
| → CMS | Payment | Central sweep: one company payment allocated across employee accounts |

## 3. VisionPlus Feature Inventory

### 3.1 Company & Program (FR-HCS-001 … 008)

| FR | Feature | Notes |
|---|---|---|
| 001 | Company onboarding: legal entity, facility limit, billing config | `company_onboarding.ex` |
| 002 | Company facility limit ≥ Σ employee limits enforcement | `limit_controller.ex` |
| 003 | Department/cost-center hierarchy with sub-limits | |
| 004 | Program types: individual-pay vs company-pay vs hybrid liability | |
| 005 | Company status lifecycle (active/suspended — suspension propagates to all employee cards) | |
| 006 | Company admin users (self-service card requests, limit moves) | |
| 007 | Billing cycle per company (single cycle for all employee cards) | |
| 008 | Company-level pricing (negotiated fees/interest overrides) | |

### 3.2 Employee Cards & Controls (FR-HCS-009 … 016)

| FR | Feature | Notes |
|---|---|---|
| 009 | Employee card issuance under company (individual + bulk) | `employee_card.ex` |
| 010 | Per-card limit within company facility | |
| 011 | Spending controls: MCC allow/block lists, channel, per-txn cap, daily/monthly caps | `spending_control.ex` |
| 012 | Control evaluation at authorization time (FAS hook) | verify wiring into FAS pipeline |
| 013 | Employee on/off-boarding: card issue on hire, block on exit | |
| 014 | Cost-center tagging of transactions (expense integration) | |
| 015 | Cash access toggle per card | |
| 016 | Temporary control lift (travel window) | |

### 3.3 Statements & Payment (FR-HCS-017 … 022)

| FR | Feature | Notes |
|---|---|---|
| 017 | Consolidated company statement (all employee cards, grouped) | `consolidated_statement*.ex` |
| 018 | Central payment sweep: company account debited, allocated across cards | `payment_sweep.ex` + Oban |
| 019 | Individual-pay reminder flow (hybrid programs) | |
| 020 | Expense-system export (file/API per company) | |
| 021 | Company MI: spend by department/MCC/employee | Roadmap 8.8 |
| 022 | Delinquency at company level (facility past-due → all cards) | |

## 4. Current Implementation Map (`lib/vmu_core/hcs/`)

`company.ex`, `company_onboarding.ex`, `employee_card.ex`, `limit_controller.ex`, `spending_control.ex`, `consolidated_statement.ex`, `consolidated_statement_generator.ex`, `payment_sweep.ex`, `oban/` — skeleton covers company, cards, limits, controls, statements, sweep.

## 5. Gap Analysis (initial — verify during planning)

| Area | Assessment |
|---|---|
| Company, employee card, limits, controls, consolidated statement, sweep | ✅ Modules exist (depth unverified) |
| **Spending-control evaluation wired into FAS auth pipeline (FR-012)** | ⬜ verify — `authorization.ex` has no HCS call; likely the key integration gap |
| Department hierarchy (FR-003), company admin self-service (FR-006) | ⬜ Not found |
| Liability models (FR-004), company pricing overrides (FR-008) | ⬜ verify |
| Expense export (FR-020) | ⬜ Not found |
| Ops/admin UI | ⬜ None (Roadmap 9.15) |

## 6. Open Questions

1. Liability model(s) for v1: company-pay only would simplify sweep + delinquency significantly.
2. Where do spending controls run — inside `FAS.Authorization`'s `with` chain (latency-sensitive) or inside ASC per-account state?
3. Expense integrations required (SAP Concur? file-based?)
