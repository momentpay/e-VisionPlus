# VisionPlus (vmu_core) — Development Roadmap & Phase Tracker

> Last updated: 2026-06-17 (Phase 4B complete)  
> Active branch: `momentPay/funny-shtern-c5181f`  
> Admin UI: `/visionplus/admin` · Legacy terminal: `/visionplus`

---

## System Architecture Overview

```
Parameter Hierarchy (top → bottom, each level inherits from parent):

  SYS (Processor)
   └─ BANK / Organisation
       └─ LOGO / Product
           └─ BLOCK (sub-product override)

Operational Hierarchy (card lifecycle):

  Customer (CIF)
   └─ Account (CMS)
       └─ Card (CTA)
           └─ Transaction (TRAMS/FAS)
```

### Business Modules in codebase
| Module | Directory | Purpose |
|--------|-----------|---------|
| FAS | `fas/` | Financial Authorization System |
| CMS | `cms/` | Card Management System (accounts, EOD, interest) |
| CIF | `shared/customer.ex` | Customer Information File |
| CTA | `cta/` | Card Transaction Admin (activation, PIN, embossing) |
| DPS | `dps/` | Dispute Processing System |
| TRAMS | `trams/` | Transaction & Clearing Management |
| COL | `col/` | Collections & Dunning |
| CDM | `cdm/` | Credit Decision Management |
| MBS | `mbs/` | Merchant Business Services |
| LMS | `lms/` | Loyalty Management System |
| HCS | `hcs/` | Head/Corporate Card Services |
| ASM | `asm/` | Account Statement Management (operator portal) |

---

## Phase Status Legend

| Symbol | Meaning |
|--------|---------|
| ✅ | Complete |
| 🔄 | In Progress |
| ⏳ | Planned — next up |
| 📋 | Planned — backlog |
| ❌ | Blocked |

---

## PHASE 1 — Admin Foundation & Parameter Hierarchy ✅ COMPLETE

**Goal:** Replace monolithic `visionplus_live.ex` with a proper architecture.  
**Route:** `/visionplus/admin`

### Deliverables

| # | Item | Status | File |
|---|------|--------|------|
| 1.1 | Dark-theme design system CSS | ✅ | `priv/static/assets/admin.css` |
| 1.2 | Shared AdminUI function components | ✅ | `lib/vmu_core_web/components/admin_ui.ex` |
| 1.3 | Root AdminLive shell (sidebar + topbar) | ✅ | `lib/vmu_core_web/live/admin/admin_live.ex` |
| 1.4 | SYS parameter view/edit | ✅ | `lib/vmu_core_web/live/admin/system_component.ex` |
| 1.5 | Organisation (BANK) CRUD with all VisionPlus dropdowns | ✅ | `lib/vmu_core_web/live/admin/organization_component.ex` |
| 1.6 | Logo/Product CRUD — 5-step wizard (50+ fields) | ✅ | `lib/vmu_core_web/live/admin/logo_component.ex` |
| 1.7 | Extended LogoParameter schema + option functions | ✅ | `lib/vmu_core/shared/logo_parameter.ex` |
| 1.8 | BankParameter org_type field | ✅ | `lib/vmu_core/shared/bank_parameter.ex` |
| 1.9 | Migration: logo extended fields + org_type | ✅ | `priv/repo/migrations/20260617000001_*.exs` |
| 1.10 | Rename legacy to VisionPlusLiveLegacy | ✅ | `lib/vmu_core_web/live/visionplus_live.ex` |
| 1.11 | Router: add admin routes, keep legacy | ✅ | `lib/vmu_core_web/router.ex` |
| 1.12 | CSRF token fix (LiveView session) | ✅ | `admin_live.ex` head section |

---

## PHASE 2 — BLOCK Parameter Admin ✅ COMPLETE

**Goal:** Complete the 4-level SYS → BANK → LOGO → BLOCK parameter chain in the admin UI.  
**Route:** `/visionplus/admin/block`

A BLOCK record inherits everything from its parent LOGO and selectively overrides  
specific fields (e.g. a Gold card block within a Visa Credit LOGO may have a  
higher cash limit % or different APR than the standard block).

### Deliverables

| # | Item | Status | Notes |
|---|------|--------|-------|
| 2.1 | BlockComponent LiveComponent | ✅ | `lib/vmu_core_web/live/admin/block_component.ex` |
| 2.2 | List blocks filtered by LOGO | ✅ | Table: block_id, logo_id, overridden fields summary |
| 2.3 | Create block — select LOGO parent, then override only changed fields | ✅ | Shows LOGO default inline |
| 2.4 | Edit block — toggle which fields are overridden vs inherited | ✅ | Checkbox "Override?" per field with live parent lookup |
| 2.5 | BlockParameter schema review — extended with 25+ override fields | ✅ | `lib/vmu_core/shared/block_parameter.ex` |
| 2.6 | Add BLOCK nav item to AdminLive sidebar | ✅ | |
| 2.7 | ParameterWriter: expose `create_block` / `update_block` via UI | ✅ | Wired through BlockComponent |
| 2.8 | Migration: extend block_parameters, make columns nullable | ✅ | `priv/repo/migrations/20260617000002_extend_block_parameters.exs` |

---

## PHASE 2.5 — Layout & UX Improvements ✅ COMPLETE

**Goal:** Fix horizontal whitespace on wide screens; improve form layout.

| # | Item | Status | Notes |
|---|------|--------|-------|
| 2.9 | Fix `.admin-main` flex fill (`flex:1; min-width:0`) | ✅ | `admin.css` |
| 2.10 | Add `.form-pane` 2-pane layout (left nav + right fields) | ✅ | `admin.css` |
| 2.11 | Redesign Organisation form to 4-section pane layout | ✅ | `organization_component.ex` |
| 2.12 | Add stat tiles to Organisation list | ✅ | `organization_component.ex` |
| 2.13 | Add `<colgroup>` column sizing to org table | ✅ | `organization_component.ex` |
| 2.14 | Add Prev/Next navigation to form footer | ✅ | `organization_component.ex` |

---

## PHASE 3 — Customer Management (CIF) ✅ COMPLETE

**Goal:** Full Customer Information File CRUD in admin UI.  
**Route:** `/visionplus/admin/customer`

### Deliverables

| # | Item | Status | Notes |
|---|------|--------|-------|
| 3.1 | CustomerComponent LiveComponent | ✅ | `lib/vmu_core_web/live/admin/customer_component.ex` |
| 3.2 | Customer list with real-time search (name, email, mobile, ID) | ✅ | Debounced 300ms, limit 100 |
| 3.3 | KYC filter + tier filter + bank filter | ✅ | Dropdown filters above table |
| 3.4 | KYC summary stat tiles (Total / Verified / Pending / Rejected) | ✅ | |
| 3.5 | Customer detail view | ✅ | Personal, contact, identity, linked accounts, corporate |
| 3.6 | Create customer form (5-section 2-pane) | ✅ | Personal / Contact / Address / Identity / Corporate |
| 3.7 | Edit customer form | ✅ | Same form, pre-filled |
| 3.8 | KYC workflow (PENDING → VERIFIED / REJECTED / reset) | ✅ | Dedicated buttons in detail view |
| 3.9 | Corporate fields for BUSINESS / CORPORATE tier | ✅ | Section 5 unlocked when tier set |
| 3.10 | Linked accounts in detail view | ✅ | Calls `Customer.list_accounts_for/1` |
| 3.11 | Customer nav item in sidebar (Operations section) | ✅ | |

---

## PHASE 4A — Account Management Core ✅ COMPLETE

**Goal:** Account list, detail view, block operations, non-monetary events, and creation wizard.  
**Route:** `/visionplus/admin/account`  
**Detailed plan:** `docs/PHASE4_CMS_UI_IMPLEMENTATION.md`

### Deliverables

| # | Item | Status | Notes |
|---|------|--------|-------|
| 4A.1 | `account_component.ex` LiveComponent | ✅ | `lib/vmu_core_web/live/admin/account_component.ex` |
| 4A.2 | Account list with 4 stat tiles + filters (status, bank, DPD) | ✅ | Real-time search by cardholder name or last 4 |
| 4A.3 | 6-tab detail view | ✅ | Overview / Balances / Cards / Statements / History / Plans |
| 4A.4 | Credit utilization bar | ✅ | Visual indicator with green/yellow/red thresholds |
| 4A.5 | Block code apply form | ✅ | `BlockCodeHistory.record_block` with operator role |
| 4A.6 | Block remove form | ✅ | `BlockCodeHistory.record_unblock` |
| 4A.7 | Non-monetary events | ✅ | Address / phone / email / cycle / emboss name change |
| 4A.8 | Event history timeline | ✅ | Block + non-monetary events merged, newest first |
| 4A.9 | Supplementary card list | ✅ | Read-only via `SupplementaryCard.list_for_primary` |
| 4A.10 | PLAN segments view | ✅ | Read-only, shows effective APR, grace, priority |
| 4A.11 | 5-step account creation wizard | ✅ | Select customer → LOGO → card details → config → review |
| 4A.12 | CSS additions | ✅ | `.detail-tabs`, `.util-bar`, `.timeline`, `.action-panel`, `.kv-*`, `.balance-*` |
| 4A.13 | AdminLive wiring | ✅ | "account" in @modules, sidebar, render dispatch |

## PHASE 4B — Account Financial Operations ✅ COMPLETE

**Goal:** Balance limits, fee waiver, financial adjustments (4-eyes principle).  
**Route:** `/visionplus/admin/account` (additional action panels in detail view)

### Deliverables

| # | Item | Status | Notes |
|---|------|--------|-------|
| 4B.1 | Permanent limit change | ✅ | Updates Account + calls `AccountStateCoordinator.refresh_limit` + logs `NonMonetaryEvent limit_change` |
| 4B.2 | Temporary limit (4-eyes) | ✅ | `TempLimit.grant` — 4-eyes operator_id ≠ supervisor_id enforced by schema; displays active temp limit in Balances tab |
| 4B.3 | Fee waiver (4-eyes) | ✅ | `FeeWaiver.waive_by_entry_id` — lists all FEE ledger entries for selection; operator ≠ supervisor enforced |
| 4B.4 | Financial adjustment (4-eyes) | ✅ | `FinancialAdjustment.post_credit/post_debit` — CREDIT/DEBIT direction; reference_id required; shown in Balances tab |
| 4B.5 | Supplementary card link | ✅ | Search existing accounts by name/last4; `SupplementaryCard.create` — SupplementaryCard schema fixed (was missing emboss_name/last_four) |
| 4B.6 | Balances tab enhancements | ✅ | Shows active temp limit banner + recent adjustments table |

## PHASE 4C — Statements & PLAN Management ⏳

| # | Item | Status | Notes |
|---|------|--------|-------|
| 4C.1 | Statement history list | ⏳ | Download PDF placeholder |
| 4C.2 | PLAN segment create/edit | ⏳ | Admin create RETAIL/CASH/EMI/BT plans per logo |
| 4C.3 | EMI schedule view | ⏳ | Outstanding EMI installments per account |

---

## PHASE 5 — Card Management (CTA) 📋

**Goal:** Card issuance and lifecycle admin.  
**Route:** `/visionplus/admin/card`

### Deliverables

| # | Item | Status | Notes |
|---|------|--------|-------|
| 5.1 | CardComponent LiveComponent | 📋 | `lib/vmu_core_web/live/admin/card_component.ex` |
| 5.2 | Card list per account | 📋 | Status, expiry, masked PAN |
| 5.3 | Card activation / deactivation | 📋 | Action buttons with confirmation |
| 5.4 | PIN management (set / unlock / reset) | 📋 | |
| 5.5 | Card replacement / reissue | 📋 | |
| 5.6 | Card stock inventory view | 📋 | `cta/stock_inventory.ex` — available BIN ranges |
| 5.7 | Embossing file trigger | 📋 | Manual trigger for batch embossing |
| 5.8 | Supplementary card view (linked from account) | 📋 | |

---

## PHASE 6 — Operational Screens 📋

**Goal:** Admin-facing views for the operational modules — search, inspect, trigger.  
Each gets a read-heavy view with targeted action buttons.

### FAS — Authorization Monitor

| # | Item | Status |
|---|------|--------|
| 6.1 | Recent authorization log (last 200 auths, live refresh) | 📋 |
| 6.2 | Auth detail view (request/response ISO fields) | 📋 |
| 6.3 | STIP threshold configuration per LOGO | 📋 |
| 6.4 | Velocity rule viewer | 📋 |

### TRAMS — Transaction Management

| # | Item | Status |
|---|------|--------|
| 6.5 | Transaction search (account, date range, amount, MCC) | 📋 |
| 6.6 | Clearing record status (pending, cleared, rejected) | 📋 |
| 6.7 | Scheme submission status (Visa Base II / MC IPM) | 📋 |
| 6.8 | FX rate management (view current rates, manual override) | 📋 |

### DPS — Dispute Processing

| # | Item | Status |
|---|------|--------|
| 6.9 | Dispute case list (open, in-progress, closed) | 📋 |
| 6.10 | Case detail view — timeline, documents, amounts | 📋 |
| 6.11 | Case status actions (open, investigate, resolve, chargeback) | 📋 |
| 6.12 | Deadline monitor (regulatory SLA tracking) | 📋 |

### COL — Collections

| # | Item | Status |
|---|------|--------|
| 6.13 | Collection queue (by DPD bucket, outstanding amount) | 📋 |
| 6.14 | Case assignment and notes | 📋 |
| 6.15 | Dunning letter trigger | 📋 |
| 6.16 | Write-off processing UI | 📋 |

### CDM — Credit Decision

| # | Item | Status |
|---|------|--------|
| 6.17 | Application scoring log (bureau scores, decision) | 📋 |
| 6.18 | Limit review queue (behavioral rescoring results) | 📋 |
| 6.19 | Manual override — approve/reject with reason | 📋 |

---

## PHASE 7 — EOD & Batch Operations 📋

**Goal:** Visibility and manual controls for nightly batch jobs.

| # | Item | Status | Notes |
|---|------|--------|-------|
| 7.1 | EOD job status dashboard | 📋 | Which jobs ran, duration, errors |
| 7.2 | Manual EOD trigger (admin override) | 📋 | With confirmation modal |
| 7.3 | Interest accrual log viewer | 📋 | Per-account accrual this cycle |
| 7.4 | Statement generation status | 📋 | Statements generated vs pending |
| 7.5 | GL flush status | 📋 | Entries posted to core banking |
| 7.6 | Oban job monitor | 📋 | View Oban queue, retry failed jobs |

---

## PHASE 8 — Reporting & Analytics Dashboard 📋

**Goal:** Executive-level portfolio metrics and operational KPIs.

| # | Item | Status | Notes |
|---|------|--------|-------|
| 8.1 | Portfolio overview (total accounts, active, blocked, closed) | 📋 | Stat cards on admin home |
| 8.2 | Balance summary (total outstanding by bucket type) | 📋 | |
| 8.3 | Delinquency aging buckets (current, 30, 60, 90, 120+ DPD) | 📋 | |
| 8.4 | Authorization performance (approval rate, decline reasons) | 📋 | |
| 8.5 | Revenue summary (fees collected, interest billed this cycle) | 📋 | |
| 8.6 | New account bookings (this month vs prior month) | 📋 | |
| 8.7 | Loyalty points liability report (LMS) | 📋 | |
| 8.8 | Corporate card summary per company (HCS) | 📋 | |
| 8.9 | FX exposure report | 📋 | Outstanding balances by currency |

---

## PHASE 9 — Legacy Screen Migration 📋

**Goal:** Migrate all screens from `VisionPlusLiveLegacy` to proper LiveComponents.  
Gradually decommission `/visionplus/legacy`.

### Screens to extract from `visionplus_live.ex`

| # | Screen Code | Module | Status |
|---|-------------|--------|--------|
| 9.1 | ASM01–03 | Account Statement Management | 📋 |
| 9.2 | ASM04–08 | Product Config (recently added) | 📋 |
| 9.3 | PCM01–03 | Parameter Config | 📋 |
| 9.4 | FAS screens | Authorization admin | 📋 |
| 9.5 | CMS screens | Card management console | 📋 |
| 9.6 | CIF screens | Customer lookup | 📋 |
| 9.7 | CTA screens | Card transaction admin | 📋 |
| 9.8 | IVR screens | IVR integration config | 📋 |
| 9.9 | DPS screens | Dispute processing | 📋 |
| 9.10 | TRAMS screens | Transaction management | 📋 |
| 9.11 | COL screens | Collections | 📋 |
| 9.12 | CDM screens | Credit decisions | 📋 |
| 9.13 | MBS screens | Merchant services | 📋 |
| 9.14 | LMS screens | Loyalty | 📋 |
| 9.15 | HCS screens | Corporate/head card | 📋 |
| 9.16 | ITS screens | Interface/integration config | 📋 |
| 9.17 | Decommission `/visionplus/legacy` route | 📋 | After all screens migrated |

---

## Current File Structure

```
lib/vmu_core_web/
├── components/
│   └── admin_ui.ex                   ← Shared function components
├── live/
│   ├── admin/                        ← Hierarchy-based admin
│   │   ├── admin_live.ex             ← Root shell (sidebar + nav)
│   │   ├── system_component.ex       ← SYS param CRUD       [Phase 1 ✅]
│   │   ├── organization_component.ex ← BANK CRUD (2-pane)   [Phase 1+2.5 ✅]
│   │   ├── logo_component.ex         ← LOGO CRUD (5-step)   [Phase 1 ✅]
│   │   ├── block_component.ex        ← BLOCK CRUD (4-step)  [Phase 2 ✅]
│   │   └── customer_component.ex     ← CIF CRUD (5-section) [Phase 3 ✅]
│   └── visionplus_live.ex            ← Legacy terminal UI (renamed to Legacy)
└── pages/
    ├── accounts_page.ex          ← LiveDashboard accounts view
    ├── parameter_engine_page.ex  ← LiveDashboard ETS cache view
    └── operator_console_page.ex  ← LiveDashboard console

priv/static/assets/
├── admin.css                     ← Admin design system
├── phoenix.min.js
└── phoenix_live_view.js

Routes:
  /visionplus/admin              → AdminLive (system default)
  /visionplus/admin/system       → System Parameters
  /visionplus/admin/organization → Organisations (BANK)
  /visionplus/admin/logo         → Products / Logos
  /visionplus/admin/block        → Sub-Product Blocks
  /visionplus/admin/customer     → Customers (CIF)   ← Phase 3
  /visionplus                    → VisionPlusLiveLegacy (terminal UI)
  /visionplus/legacy             → VisionPlusLiveLegacy (alias)
  /dashboard                     → Phoenix LiveDashboard
```

---

## Tech Decisions & Constraints

| Decision | Rationale |
|----------|-----------|
| No asset pipeline (no esbuild) | CSS goes directly to `priv/static/assets/` |
| `layout: false` on AdminLive | Admin renders its own full HTML with CSRF meta tag |
| LiveComponent per module | Each module (system/org/logo) is isolated — own state, own events |
| ParameterWriter always used for writes | Ensures ETS cache stays in sync after every save |
| Composite PKs on LOGO and BLOCK | Matches VisionPlus schema convention (`logo_id + sys_id + bank_id`) |
| `phx-target={@myself}` on all form events | Events stay in the LiveComponent, not bubble to parent LiveView |
| Multi-step form via `current_step` assign | No JS required — Phoenix hides/shows `div` with `display:none` |

---

## How to Pick Up Any Phase

1. Read this file to find the next unchecked deliverable
2. Check the relevant schema in `lib/vmu_core/shared/` or the module directory
3. Create the LiveComponent at `lib/vmu_core_web/live/admin/<name>_component.ex`
4. Add the nav item in `admin_live.ex` sidebar section and module map
5. Add the route in `router.ex` if a new `:module` value is needed
6. Update this file — change ⏳/📋 to ✅ when done

---

*Generated: 2026-06-17 | vmu_core VisionPlus Admin Roadmap*
