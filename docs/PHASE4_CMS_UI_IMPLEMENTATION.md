# Phase 4 — CMS Account Management UI/UX Implementation Plan

> Document created: 2026-06-17  
> Based on: `visionplus_cms_document.txt` + codebase schema analysis  
> Status: **APPROVED FOR IMPLEMENTATION**

---

## 1. Alignment Gap Analysis

### What the roadmap planned vs. what CMS actually requires

The original Phase 4 plan captured the **outer shell** of account management but missed
several concepts that the CMS document defines as core operations. The table below shows
every original item, its alignment, and the gaps.

| # | Original Roadmap Item | Alignment | Gap / Issue |
|---|---|:---:|---|
| 4.1 | AccountComponent LiveComponent | ✓ | — |
| 4.2 | Account list with filters | ✓ | — |
| 4.3 | Account detail view | ⚠️ Partial | Missing: statement history tab, plan segments tab, non-monetary event log |
| 4.4 | Account creation wizard | ⚠️ Partial | Missing: `block_id` selection, emboss name, card details (PAN last-4, expiry), `open_date` |
| 4.5 | Credit limit management | ⚠️ Partial | Perm limit + temp limit both require 4-eyes: `operator_id ≠ supervisor_id`. `TempLimit` module enforces this. |
| 4.6 | Account status / block actions | ⚠️ Partial | Block codes need structured `reason_code` (REPORTED_LOST, FRAUD_ALERT…) + `operator_id` + `operator_role`. `BlockCodeHistory.record_block/6` enforces this. |
| 4.7 | Block code history view | ✓ | — |
| 4.8 | Balance buckets view | ⚠️ Partial | `BalanceBucket` has 9 fields (retail, cash, BT, EMI, accrued interest, unpaid fees, disputed, statement balance, minimum payment). Plan was just "purchase/cash/fees". |
| 4.9 | Supplementary card management | ✓ | — |
| 4.10 | Fee waiver UI | ⚠️ Partial | `FeeWaiver` requires `supervisor_id ≠ operator_id` (4-eyes). Also needs original idempotency key or entry_id. |
| 4.11 | Financial adjustment | ✓ | `VmuCore.CMS.FinancialAdjustment` exists |
| ❌ | **PLAN Segment management** | **MISSING** | CMS doc §5, §3-7. `plan_segments` table exists. PLAN is child of LOGO: Retail, Cash, EMI, Balance Transfer. APR, grace, payment priority. Minimum one RETAIL + CASH plan required per LOGO. |
| ❌ | **Non-monetary events** | **MISSING** | CMS doc §10. `NonMonetaryEvent` module. Most common call-centre operations: address change, phone change, email change, billing cycle change, card reissue. Each creates an immutable audit record. |
| ❌ | **Interest adjustment** | **MISSING** | CMS doc §16 lists "Interest Adjustment" as one of top-10 operations. Not the same as fee waiver or financial adjustment. |
| ❌ | **Statement history** | **MISSING** | CMS doc §13. After billing, a statement segment is generated. Operators need to see: statement date, statement balance, min due, due date, payment status, opening/closing balance. |
| ❌ | **EMI schedule view** | **MISSING** | `VmuCore.CMS.EmiSchedule` exists. Operations teams need to view active EMI plans per account and their instalment schedule. |

---

## 2. Revised Phase 4 Scope

Phase 4 is split into **three sub-phases** to manage complexity.  
Each sub-phase produces independently testable, shippable screens.

```
Phase 4A — Core Account CRUD & Status Operations
Phase 4B — Financial Operations (Limit / Fees / Adjustments)
Phase 4C — Billing, Statements & Plan Segments
```

---

## 3. Phase 4A — Core Account CRUD & Status Operations

**Goal:** Account list, detail view, creation wizard, block code operations, non-monetary events.

### Screens / Components

#### A1. Account List  
Route: `/visionplus/admin/account`  

- Stat tiles: Total Accounts · Active · Blocked/Suspended · Delinquent
- Search: account_id (partial UUID), last_four (card digits), customer name lookup (join to `cms_customers`)
- Filters: `account_status` · `bank_id` · `logo_id` · `delinquency_bucket` (0/30/60/90/120+)
- Table columns:
  ```
  Account ID (short) | Customer | Bank | Logo | Status | Block | DPD | Credit Limit | OTB | Actions
  ```
- Row actions: View | Edit | Block | Unblock

#### A2. Account Detail View (6 tabs)

Tab structure within a single detail card:

| Tab | Content |
|---|---|
| **Overview** | Status badge, credit limit, open_to_buy, block code, DPD bucket, cycle_code, open_date |
| **Balances** | All 9 `BalanceBucket` fields in a visual breakdown (see §4 below) |
| **Cards** | Primary card (last_four, expiry, emboss_name, status) + supplementary cards list |
| **Statements** | Last 6 statement records (date, balance, min_due, due_date, paid/unpaid) |
| **History** | Block code history + non-monetary event log merged timeline |
| **Plans** | Plan segments active for this account's LOGO (read-only view) |

#### A3. Account Creation Wizard (5 steps)

```
Step 1: Select Customer
  - Search/select from cms_customers (same bank_id)
  - Shows: name, KYC status, existing account count

Step 2: Select Product
  - bank_id → LOGO dropdown (LogoParameter)
  - BLOCK parameter dropdown (optional, for sub-product tier)
  - Confirms APR, annual fee, credit limit range inherited from LOGO

Step 3: Credit & Card Details
  - credit_limit (within LOGO's min/max range)
  - cash_limit (auto = 30% of credit_limit, or override)
  - cycle_code (1-28, day of month for billing)
  - emboss_name (≤ 26 chars, auto-populated from customer name)
  - last_four + expiry_date (card details — will be replaced by CTA in Phase 5)
  - pan_token (SHA-256 of a dummy PAN for now; CTA Phase 5 generates real PAN)

Step 4: Campaign & Velocity
  - campaign_code (optional)
  - velocity_limits JSON (optional, defaults to LOGO limits)

Step 5: Review & Confirm
  - Summary of all settings
  - Confirm creates account via Repo.insert + AccountStateCoordinator
```

#### A4. Block Code Operations

**Apply Block:**
```
Form fields:
  Block Code:    [L — Lost | S — Stolen | F — Fraud | C — Collections | O — Overlimit]
  Reason Code:   [REPORTED_LOST | REPORTED_STOLEN | FRAUD_ALERT | COLLECTIONS_HOLD | OVERLIMIT | CUSTOMER_REQUEST]
  Free Text:     (optional, max 100 chars)
  Operator ID:   (text input — the agent applying the block)
  Operator Role: [AGENT | SUPERVISOR | SYSTEM]
Calls: BlockCodeHistory.record_block/6
```

**Remove Block:**
```
Form fields:
  Reason Code:   [INVESTIGATION_CLOSED | PAYMENT_RECEIVED | SUPERVISOR_OVERRIDE | CUSTOMER_REQUEST]
  Free Text:     (optional)
  Operator ID:   (text input)
  Operator Role: [AGENT | SUPERVISOR]
Calls: BlockCodeHistory.record_unblock/6
Then: Account.changeset(%{block_code: nil, block_reason: nil})
```

#### A5. Non-Monetary Events

Panel in Account Detail → History tab, plus a dedicated "Change" button group:

| Operation | Event Type | Fields Captured |
|---|---|---|
| Address Change | `address_change` | line1, line2, city, postal_code, country — old + new |
| Phone Change | `phone_change` | mobile_country + mobile_number — old + new |
| Email Change | `email_change` | email — old + new |
| Billing Cycle Change | `cycle_change` | cycle_code — old + new (requires supervisor) |
| Card Reissue | `card_reissue` | reason (DAMAGED/EXPIRED/LOST), new expiry |
| Emboss Name Change | `name_change` | emboss_name — old + new |

Each calls: `NonMonetaryEvent.record(%{account_id, event_type, old_value, new_value, reason, operator_id})`

All events appear in the History tab as a timeline.

---

## 4. Phase 4B — Financial Operations

**Goal:** Credit limit changes, temp limits (4-eyes), fee waivers (4-eyes), interest adjustments, financial adjustments, supplementary card management.

### Balance Breakdown Display (used in A2 Balances tab)

```
┌─────────────────────────────────────────────────────────────────┐
│  BALANCE BREAKDOWN                         As of: 2026-06-17   │
├───────────────────────────┬─────────────────────────────────────┤
│  Credit Limit             │   AED 20,000.00                     │
│  Open to Buy              │   AED  7,500.00                     │
│  Credit Utilization       │   62.5% ████████████░░░░░           │
├───────────────────────────┼─────────────────────────────────────┤
│  Retail Balance           │   AED  5,800.00                     │
│  Cash Balance             │   AED  1,200.00                     │
│  Balance Transfer         │   AED      0.00                     │
│  EMI Balance              │   AED  2,500.00                     │
│  Accrued Interest         │   AED    125.00                     │
│  Unpaid Fees              │   AED    100.00                     │
│  Disputed Amount          │   AED    275.00                     │
├───────────────────────────┼─────────────────────────────────────┤
│  Statement Balance        │   AED  9,750.00  (at last billing)  │
│  Minimum Payment Due      │   AED    487.50                     │
│  Due Date                 │   2026-07-15                        │
└───────────────────────────┴─────────────────────────────────────┘
```

### B1. Permanent Credit Limit Change

```
Form fields:
  New Credit Limit:  [number, must be within LOGO's credit_limit_min..max]
  New Cash Limit:    [number, auto = 30% of new limit or manual]
  Reason:            [text]
  Operator ID:       [text]
Uses: Account.changeset + AccountStateCoordinator.refresh_limit/2
Records: NonMonetaryEvent (event_type: "limit_change")
```

### B2. Temporary Credit Limit (4-eyes)

```
Form fields:
  Temporary Limit:    [number]
  Expiry Date:        [date, must be future]
  Reason:             [text]
  Operator ID:        [text — agent requesting]
  Supervisor ID:      [text — must differ from operator_id]
Uses: TempLimit.grant/1
Note: Only ONE active temp limit per account. If one exists, shows current and confirms replacement.
EOD: ReinstateLimitJob auto-restores original limit on expiry.
```

### B3. Fee Waiver (4-eyes)

```
Shows: Recent fee ledger entries (unpaid_fees amount, date, type)
Form fields:
  Fee Entry:          [select from recent fee postings — entry_id]
  Waiver Reason:      [text]
  Operator ID:        [text — agent requesting]
  Supervisor ID:      [text — must differ from operator_id]
Uses: FeeWaiver.waive_by_entry_id/1
Shows: Before/after unpaid_fees balance
```

### B4. Interest Adjustment (Waiver or Reduction)

```
Note: Not same as FeeWaiver — interest adjustments credit the accrued_interest bucket.
Form fields:
  Adjustment Type:   [WAIVE_FULL | PARTIAL_REDUCTION | PROMOTIONAL_RATE]
  Amount:            [decimal — for PARTIAL_REDUCTION]
  New Rate (months): [integer — for PROMOTIONAL_RATE]
  Reason:            [text]
  Operator ID:       [text]
  Supervisor ID:     [text — 4-eyes]
Uses: FinancialAdjustment (type: "INTEREST_ADJUSTMENT")
      Then updates BalanceBucket.accrued_interest
```

### B5. Financial Adjustment (Manual GL Posting)

```
Form fields:
  Type:              [CREDIT | DEBIT]
  Amount:            [decimal]
  Description:       [text]
  GL Code:           [text — must match core banking chart of accounts]
  Operator ID:       [text]
Uses: VmuCore.CMS.FinancialAdjustment module
```

### B6. Supplementary Cards

```
List View (within Account detail → Cards tab):
  primary_account_id, supplementary_account_id, sub_limit, status, activated_at

Add Supplementary Card:
  Form fields:
    Supplementary Account ID: [text — must be an existing account, same bank]
    Sub Limit:                [decimal, optional]
  Uses: SupplementaryCard.create/3

Cancel Supplementary Card:
  Sets status = CLOSED
  Uses: SupplementaryCard.update status
```

---

## 5. Phase 4C — Billing, Statements & Plan Segments

**Goal:** Statement history, billing cycle view, Plan segment management (view + edit).

### C1. Statement History (Account Detail → Statements tab)

```
Table:
  Statement Date | Opening Balance | Closing Balance | Min Due | Due Date | Paid (Y/N)

Detail row expands to show:
  Purchases | Cash Advances | Payments | Fees | Interest | Adjustments

Note: Reads from cms_balance_buckets + StatementGenerator output.
     StatementGenerator uses VmuCore.CMS.StatementGenerator module.
```

### C2. Plan Segment List (per LOGO)

Route: Accessible from LOGO admin as a sub-view, and read-only reference from Account detail.

**PLAN is a LOGO-level configuration.** Operators don't assign plans to accounts directly —
accounts inherit all plans from their LOGO. Transactions are routed to the correct plan
automatically by plan_type.

```
Table (filtered by logo_id):
  Plan ID | Plan Type | APR | Promo APR | Promo Expiry | Grace | Min Pay % | Priority | Status

Plan Types:
  RETAIL          — Standard purchase. APR = purchase rate. Grace period eligible.
  CASH            — Cash advance. Higher APR. No grace. Accrues from day 1.
  EMI             — Equal monthly instalments. Defined tenor (3/6/12/18/24 months).
  BALANCE_TRANSFER— Typically promotional rate for a defined period.
```

**Plan Create/Edit (accessible from LOGO admin in Phase 4C):**

```
Form fields:
  Plan ID:           [4-char code, e.g. RET1]
  Logo ID:           [linked to parent LOGO — dropdown]
  Plan Type:         [RETAIL | CASH | EMI | BALANCE_TRANSFER]
  APR (%):           [decimal]
  Promo APR (%):     [decimal, optional]
  Promo Expiry:      [date, optional — if set, promo rate applies until this date]
  Grace Eligible:    [boolean — true = interest-free period applies if full payment made]
  Min Payment %:     [decimal, optional — overrides LOGO default]
  Payment Priority:  [integer 1-5 — see priority table below]
  EMI Tenor (months):[integer, only for EMI type]
  Statement Order:   [integer — display order on statement]
  Active:            [boolean]

Payment Priority Standard (VisionPlus):
  1 = Fees (always paid first)
  2 = Interest
  3 = Cash Advance (CASH plan)
  4 = Retail Purchase (RETAIL plan)
  5 = EMI Balance
```

**Validation rules:**
- Every LOGO must have at least one RETAIL plan and one CASH plan before accounts can be created under it
- EMI plan requires `emi_tenor_months` to be set
- Promo APR requires promo_expiry_date

### C3. EMI Schedule View

Accessible from Account detail → Plans tab for accounts with EMI balance:

```
Table:
  Instalment # | Due Date | Principal | Interest | Total Due | Status (PENDING/PAID/OVERDUE)

Source: VmuCore.CMS.EmiSchedule
```

---

## 6. Screen Map — Complete Phase 4 Navigation

```
/visionplus/admin/account
│
├── LIST VIEW
│   ├── Stat tiles: Total | Active | Blocked | Delinquent
│   ├── Search + Filters
│   └── Table → [View] [Block] [Unblock]
│
└── DETAIL VIEW  (tabs)
    ├── Overview
    │   ├── Account info (status, balances summary, cycle, dates)
    │   └── Quick actions: [Change Limit] [Temp Limit] [Apply Block] [Remove Block]
    │
    ├── Balances
    │   ├── Balance breakdown card (all 9 fields + utilization bar)
    │   └── Fee Waiver button | Interest Adjustment button | Financial Adjustment button
    │
    ├── Cards
    │   ├── Primary card (last_four, expiry, emboss_name, status)
    │   ├── Supplementary cards list
    │   └── [Add Supplementary] button
    │
    ├── Statements  (last 12)
    │   ├── Statement list (date, balance, min_due, due_date)
    │   └── Expand each → transaction breakdown
    │
    ├── History  (merged timeline)
    │   ├── Block code events (from BlockCodeHistory)
    │   ├── Non-monetary events (from NonMonetaryEvent)
    │   └── Temp limit events (from TempLimit)
    │
    └── Plans  (read-only, from LOGO)
        ├── Plan segments list for this LOGO
        └── Active EMI schedules for this account

PLAN MANAGEMENT (linked from LOGO admin):
  /visionplus/admin/logo → [Manage Plans] button → plan list/create/edit
```

---

## 7. Key Backend Modules Used in Phase 4

| UI Action | Module / Function | Notes |
|---|---|---|
| List accounts | `Repo.all(Account)` with filters | Join to Customer for name search |
| Create account | `Account.changeset \|> Repo.insert` | Then `AccountStateCoordinator.refresh/1` |
| Apply block | `BlockCodeHistory.record_block/6` | Then update Account block_code |
| Remove block | `BlockCodeHistory.record_unblock/6` | Then clear Account block_code |
| Temp limit | `TempLimit.grant/1` | 4-eyes: operator_id ≠ supervisor_id |
| Fee waiver | `FeeWaiver.waive_by_entry_id/1` | 4-eyes: operator_id ≠ supervisor_id |
| Interest adj | `FinancialAdjustment` + `BalanceBucket` | Update accrued_interest |
| Financial adj | `VmuCore.CMS.FinancialAdjustment` | — |
| Address change | `NonMonetaryEvent.record/1` | event_type: "address_change" |
| Phone change | `NonMonetaryEvent.record/1` | event_type: "phone_change" |
| Cycle change | `NonMonetaryEvent.record/1` | event_type: "cycle_change" |
| Supp card | `SupplementaryCard.create/3` | — |
| Plan CRUD | `Repo.insert/update(PlanSegment)` | Validate RETAIL+CASH exist per LOGO |
| EMI view | `VmuCore.CMS.EmiSchedule` | Read-only for now |
| Statements | `VmuCore.CMS.StatementGenerator` | Read-only history query |

---

## 8. Implementation Order

### Sub-Phase 4A (implement first)
1. `account_component.ex` — list + detail shell + 6 tabs structure (tabs can be empty placeholders initially)
2. Account list with filters and stat tiles
3. Account detail → Overview tab (status, balances summary, dates)
4. Account creation wizard (5 steps)
5. Block / Unblock operations with full reason codes
6. Non-monetary events (address, phone, cycle change forms in History tab)
7. Block code history view

### Sub-Phase 4B (after 4A works)
8. Balances tab — full BalanceBucket breakdown + utilization bar
9. Supplementary cards (Cards tab)
10. Permanent credit limit change
11. Temporary credit limit (4-eyes form)
12. Fee waiver (4-eyes, by entry_id)
13. Interest adjustment
14. Financial adjustment

### Sub-Phase 4C (after 4B works)
15. PLAN segment UI (add to LOGO component as a sub-view)
16. Statement history tab (read-only from billing output)
17. EMI schedule tab (read-only)

---

## 9. CSS Components Needed

All reuse existing `.form-pane`, `.stat-grid`, `.data-table` patterns from admin.css.

New additions needed:
```css
/* Tab navigation within detail cards */
.detail-tabs          — horizontal tab bar within card
.detail-tab           — individual tab
.detail-tab.active    — active tab

/* Balance breakdown */
.balance-grid         — 2-col grid for balance fields
.utilization-bar      — credit utilization visual bar
.utilization-fill     — fill portion (color = green/yellow/red based on %)

/* Timeline (block history + non-monetary events) */
.timeline             — vertical list with connector line
.timeline-item        — single event
.timeline-dot         — colored circle indicator
.timeline-content     — event description
```

---

## 10. Key Constraints & Business Rules

| Rule | Enforcement |
|---|---|
| Block code change requires `operator_id` + `operator_role` | Form validates both non-empty |
| Temp limit requires `supervisor_id ≠ operator_id` | Form validates at submit |
| Fee waiver requires `supervisor_id ≠ operator_id` | Form validates at submit |
| Interest adjustment requires `supervisor_id ≠ operator_id` | Same 4-eyes pattern |
| Only ONE active temp limit per account | `TempLimit.grant` handles supersession |
| Account creation requires KYC-verified customer | Warn if `kyc_status ≠ VERIFIED` (block is optional policy) |
| LOGO must have RETAIL + CASH plans before account creation | Validate in creation wizard step 2 |
| Cycle change requires supervisor approval | Use `operator_role: SUPERVISOR` in NonMonetaryEvent |
| pan_token must be unique (SHA-256) | Ecto unique constraint handles this |
| `emboss_name` max 26 chars, uppercase only | Client-side + Ecto validate_length |

---

*Phase 4 total estimated screens: 17 distinct views/forms across 4A/4B/4C*  
*Start with 4A — account list + detail tabs + creation wizard + block operations*
