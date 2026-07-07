# LMS — Loyalty Management System: Module Requirements

**Status:** 📝 Draft for review — drafted from VisionPlus loyalty domain knowledge, cross-checked against `lib/vmu_core/lms/` (the richest of the "long-tail" modules — 16 files). Validate program economics with product before implementation planning.

---

## 1. Purpose & Scope

LMS runs the **rewards program**: schemes and plans, enrollment, points earn (rate tiers per MCC/spend), the points ledger, redemption (catalog/cashback/statement credit), expiry, merchant-funded offers, and the GL liability provision for outstanding points.

## 2. Where LMS Sits

| Direction | Module | Contract |
|---|---|---|
| ← CMS/TRAMS | Earn basis | Posted transactions drive accrual (`cms_interface.ex`) |
| → CMS | Redemption | Statement-credit redemptions post via ledger |
| → GL | Liability | Points liability provision (`gl_provisioner.ex`) |
| ← MBS | Offers | Merchant-funded accelerators + merchant settlement of redemptions |
| → HCS | Corporate | Corporate program earn pooling (company-level) |

## 3. VisionPlus Feature Inventory

### 3.1 Program Setup (FR-LMS-001 … 008)

| FR | Feature | Notes |
|---|---|---|
| 001 | Scheme (program) definition per SYS/BANK | `scheme.ex` |
| 002 | Plans within scheme (earn rules variant per product/LOGO) | `plan.ex` |
| 003 | Rate tiers: points per currency unit by MCC group / spend band / channel | `rate_engine.ex` · `rate_tier.ex` |
| 004 | Accelerators/promotions (2× weekends, merchant-funded multipliers) | |
| 005 | Exclusions (cash advance, fees, gambling MCC earn = 0) | |
| 006 | Points valuation + currency (points ↔ money rate for accounting) | |
| 007 | Grouping (family/corporate pooling) | `group.ex` |
| 008 | Program calendar: earn windows, blackout, expiry policy | |

### 3.2 Enrollment & Earn (FR-LMS-009 … 015)

| FR | Feature | Notes |
|---|---|---|
| 009 | Enrollment: auto at account boarding vs opt-in; per-account plan link | `enrollment.ex` |
| 010 | Accrual engine on posted transactions (never on auth) | `points_engine.ex` + Oban `points_calculation_job` |
| 011 | Points ledger: append-only earn/redeem/expire/adjust entries | `points_ledger.ex` |
| 012 | Reversal-aware accrual (points clawback on transaction reversal/chargeback) | verify — ties to TRAM events |
| 013 | Manual points adjustment with 4-eyes | |
| 014 | Balance inquiry (account + group pooled) | |
| 015 | Tier status (silver/gold) from rolling earn | |

### 3.3 Redemption, Expiry & Accounting (FR-LMS-016 … 024)

| FR | Feature | Notes |
|---|---|---|
| 016 | Redemption types: statement credit, cashback, catalog, partner transfer | `redemption.ex` · `redemption_processor.ex` |
| 017 | Redemption validation: sufficient balance, min blocks, account in good standing | |
| 018 | Merchant settlement of redemptions (pay merchant for fulfilled reward) | `merchant_settlement*.ex` |
| 019 | Points expiry: FIFO aging + expiry sweep + pre-expiry notification | Oban job exists — verify |
| 020 | GL provisioning: liability accrual at points valuation; release on redeem/expire | `gl_provisioner.ex` |
| 021 | Breakage estimation reporting | |
| 022 | Points transfer between accounts (same customer) | |
| 023 | Statement display feed (earned/redeemed/balance per cycle) | |
| 024 | Points liability report | Roadmap 8.7 |

## 4. Current Implementation Map (`lib/vmu_core/lms/`)

`scheme.ex`, `plan.ex`, `rate_engine.ex`, `rate_tier.ex`, `group.ex`, `enrollment.ex`, `account.ex` (LMS account), `points_engine.ex`, `points_ledger.ex`, `cms_interface.ex`, `redemption.ex`, `redemption_processor.ex`, `merchant_settlement.ex`, `merchant_settlement_service.ex`, `gl_provisioner.ex`, `oban/` (points calculation + others).

This is the most structurally complete non-core module — the skeleton maps to nearly every FR group above.

## 5. Gap Analysis (initial — verify during planning)

| Area | Assessment |
|---|---|
| Scheme/plan/tier/enroll/earn/ledger/redeem/GL skeleton | ✅ Exists across the board (depth unverified) |
| Reversal/chargeback clawback (FR-012) | ⬜ verify — should hook TRAM `authorization_reversed`/`chargeback_created` events |
| Accelerators & merchant-funded offers (FR-004) | ⬜ verify rate_engine flexibility |
| Expiry notifications (FR-019b), breakage (FR-021) | ⬜ verify |
| Points on statement (FR-023) | ⬜ not in `trams_statement_lines` — needs a statement feed |
| Ops/admin UI | ⬜ None (Roadmap 9.14) |

## 6. Open Questions

1. Program economics: points valuation, expiry horizon, exclusion list — business inputs that gate GL provisioning correctness.
2. Should clawback subscribe to TRAM lifecycle events (clean) or scan reversal ledger entries (simpler)?
3. Catalog/partner redemption in v1, or statement-credit only?
