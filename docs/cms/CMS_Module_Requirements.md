# CMS — Credit Management System: Module Requirements

**Status:** 📝 Draft for review — drafted from VisionPlus CMS domain knowledge, cross-checked against the current `lib/vmu_core/cms/` implementation. Validate feature inventory and priorities with SME/product before implementation planning.
**Related trackers:** `../CMS_Implementation_Tracker.md` · `../phase-tracker.md` (native build) · `../PHASE4_CMS_UI_IMPLEMENTATION.md` (admin UI)

---

## 1. Purpose & Scope

CMS is the **account-centric heart of VisionPlus**: it owns the credit card account master, all balances, credit limits, interest, fees, billing cycles, payments, and delinquency state. Every other module orbits it — FAS asks it "is there open-to-buy?", TRAMS posts receivables into it, COL reads its delinquency buckets, LMS reads its spend.

**Boundary test:** if data describes *the current standing of an account*, it belongs in CMS. Transaction history belongs to TRAMS; the authorization decision belongs to FAS.

## 2. Where CMS Sits

| Direction | Module | Contract |
|---|---|---|
| ← FAS | Authorization | `AccountStateCoordinator.authorize/3` — in-memory OTB check, no DB on hot path |
| ← TRAMS | Posting | `cms_ledger_entries` via `InternalGlPoster` (idempotency-keyed) |
| ← DPS | Provisional credit | `InternalGlPoster` DISPUTE_CREDIT entries |
| → COL | Delinquency | `delinquency_bucket` / DPD drives collection case creation |
| → CDM | Limit reviews | Behavioral data feeds rescoring; CDM writes new limits back |
| → Bureau | Reporting | Metro2 file generation |
| → Core banking / GL | Extract | `CoreBankingAdapter` ledger extract (`extracted_at` marker) |

## 3. VisionPlus Feature Inventory

### 3.1 Account Master (FR-CMS-001 … 015)

| FR | Feature | Notes |
|---|---|---|
| 001 | Account creation under CIF customer, LOGO/BLOCK product assignment | Wizard exists in admin UI (Phase 4A) |
| 002 | Account statuses: ACTIVE / INACTIVE / BLOCKED / SUSPENDED / CLOSED / CHARGED_OFF | |
| 003 | Block codes (L/S/F/C/O …) with history, reason codes, operator audit | |
| 004 | Non-monetary maintenance: address, phone, email, cycle change, emboss name | Event-logged |
| 005 | Supplementary/add-on cards with sub-limits under primary account | |
| 006 | Account transfer (LOGO-to-LOGO product migration) | Balance + parameter migration rules |
| 007 | Account closure workflow: block → zero balance → close; reopen rules | |
| 008 | Cycle code assignment + resegmentation (statement date spread) | |
| 009 | Multi-currency account support (billing currency per account) | |
| 010 | Memo/notes per account with operator attribution | |
| 011 | Account-level flags: paperless, do-not-solicit, deceased, hardship | |
| 012 | Emboss name management + card ordering linkage (→ CTA) | |
| 013 | Account short name / statement descriptor | |
| 014 | Charge-off marking + post-charge-off recovery accounting | ties to COL write-off |
| 015 | Dormancy detection + inactivity fees eligibility | |

### 3.2 Balances & Credit Limits (FR-CMS-016 … 030)

| FR | Feature | Notes |
|---|---|---|
| 016 | Balance buckets: retail, cash, fee, interest, BT (balance transfer) | Per-bucket APR |
| 017 | Open-to-buy (OTB) = credit limit − outstanding − pending holds | In-memory in ASC |
| 018 | Cash advance sub-limit (% of credit limit) | |
| 019 | Permanent limit change with authority levels | |
| 020 | Temporary limit (time-boxed, 4-eyes approval) | |
| 021 | Overlimit tolerance % (approve up to limit × (1+tol)) | |
| 022 | Daily balance snapshots for average-daily-balance interest | |
| 023 | Balance transfer intake + promo pricing | |
| 024 | Credit balance (overpayment) handling + refund workflow | |
| 025 | Statement balance / minimum payment / due date computation | |
| 026 | Past-due amount tracking per cycle | |
| 027 | Multi-plan balances: PLAN segments (RETAIL/CASH/EMI/BT) with own APR, grace, priority | |
| 028 | EMI conversion: transaction → installment schedule (tenor, rate, fees) | |
| 029 | EMI foreclosure / pre-payment with fee | |
| 030 | Account-level exposure roll-up to customer (CIF) level | |

### 3.3 Interest & Fees (FR-CMS-031 … 045)

| FR | Feature | Notes |
|---|---|---|
| 031 | Average daily balance interest per bucket, per plan APR | |
| 032 | Grace period logic (pay-in-full ⇒ no retail interest) | |
| 033 | Cash advance interest from transaction date (no grace) | |
| 034 | Penalty APR trigger on DPD threshold + cure rules | |
| 035 | Interest accrual daily, billed at cycle | |
| 036 | Fee engine: annual, late, overlimit, cash advance, FX markup, card replacement, statement copy | |
| 037 | Fee waiver with 4-eyes approval + waiver history | |
| 038 | Fee caps and regulatory maxima per jurisdiction | |
| 039 | Interest/fee reversal (statement reversal) with recompute | |
| 040 | Promotional pricing windows (0% intro APR, BT promo) | |
| 041 | Trial balance of interest accrued vs billed | |
| 042 | FX conversion on foreign-currency transactions + markup fee | |
| 043 | Interest rate change orchestration (re-price on parameter change) | |
| 044 | Financial adjustments (credit/debit) with 4-eyes + reference | |
| 045 | Repayment hierarchy: payments allocate to buckets in configured order (e.g. interest → fees → cash → retail) | |

### 3.4 Billing Cycle / EOD (FR-CMS-046 … 060)

| FR | Feature | Notes |
|---|---|---|
| 046 | EOD scheduler: per-cycle-code nightly batch orchestration | |
| 047 | Account lock during EOD processing | |
| 048 | Interest accrual job | |
| 049 | Fee assessment job (late fee on due date miss, annual fee on anniversary) | |
| 050 | Statement generation: balance snapshot, min payment, due date | |
| 051 | Statement line feed from TRAMS (`trams_statement_lines`) | Wired TRAM-P5 |
| 052 | Delinquency aging: bucket roll (current → 30 → 60 → 90 → 120+) | |
| 053 | Payment due processing + past-due marking | |
| 054 | GL flush to core banking / external GL | |
| 055 | Daily balance snapshot job | |
| 056 | Bureau reporting extract (Metro2) monthly | |
| 057 | EOD job status visibility + rerun controls | Roadmap Phase 7 |
| 058 | Cycle resegmentation batch | |
| 059 | Dormancy/inactivity sweep | |
| 060 | Statement reversal + regeneration | |

### 3.5 Payments (FR-CMS-061 … 070)

| FR | Feature | Notes |
|---|---|---|
| 061 | Payment intake channels: branch, transfer, direct debit, gateway | |
| 062 | Repayment distribution per hierarchy across plans/buckets | |
| 063 | Partial / full / overpayment handling | |
| 064 | Payment reversal (bounce/return) + fee + delinquency recompute | |
| 065 | Autopay mandates (min due / full / fixed amount) | |
| 066 | Payment holidays / hardship plans | ties to COL workout |
| 067 | Transaction-level payment allocation (dispute/EMI/BNPL precision) | TRAM spec §7.2 state 8 |
| 068 | OTB restore on payment | |
| 069 | Unapplied/suspense payment handling | |
| 070 | Payment receipt notification triggers | |

## 4. Current Implementation Map (`lib/vmu_core/cms/`)

| File | Covers |
|---|---|
| `account.ex` | Account master schema (status, block_code, cycle_code, limits, DPD) |
| `account_state_coordinator.ex` | Horde GenServer per account: OTB, daily limits, overlimit tolerance, sub-limits, `authorize/reverse/credit_open_to_buy` |
| `balance_bucket.ex` | Retail/cash/fee/interest/BT buckets + statement fields |
| `plan_segment.ex` · `emi_schedule.ex` | PLAN segments + EMI schedules |
| `interest_engine.ex` | ADB interest, grace, min payment |
| `fee_engine.ex` · `fee_waiver.ex` | Fee assessment + 4-eyes waiver |
| `statement_generator.ex` · `statement_reversal.ex` | Balance-level statement + reversal |
| `repayment_distributor.ex` | Payment hierarchy distribution |
| `ledger_entry.ex` · `internal_gl_poster.ex` | Idempotent double-entry ledger |
| `financial_adjustment.ex` · `temp_limit.ex` | 4-eyes adjustments + temp limits |
| `block_code_history.ex` · `non_monetary_event.ex` | Maintenance audit trails |
| `supplementary_card.ex` | Add-on cards + sub-limits |
| `fx_engine.ex` · `fx_rate.ex` | FX conversion + rates |
| `stip_engine.ex` · `stip_threshold.ex` | Stand-in processing thresholds |
| `metro2_generator.ex` · `bureau_adapter.ex` | Bureau reporting |
| `core_banking_adapter.ex` | GL extract (`extracted_at`) |
| `card_pin.ex` | PIN hash/try-counter store (FAS-P7) |
| `eod/` | EOD job chain (scheduler → lock → interest → statement → GL flush) |

## 5. Gap Analysis (initial — verify during planning)

| Area | Assessment |
|---|---|
| Account master, balances, buckets, PLAN/EMI | ✅ Largely built (phase-tracker claims complete; verified schemas exist) |
| Interest, fees, EOD chain, statements | ✅ Built; statement lines wired to TRAMS (TRAM-P5) |
| Payments | 🔄 `repayment_distributor` exists; intake channels, autopay mandates, payment reversal/bounce flow, transaction-level allocation (FR-067) unverified/likely gaps |
| Account transfer (FR-006), closure workflow (FR-007), dormancy (FR-015/059) | ⬜ No dedicated modules found |
| Credit balance refund (FR-024), promo pricing windows (FR-040) | ⬜ Not found |
| Charge-off accounting (FR-014) | 🔄 COL write-off exists; CMS-side recovery accounting unverified |
| Customer-level exposure roll-up (FR-030) | ⬜ Not found |
| EOD visibility/rerun UI (FR-057) | ⬜ Roadmap Phase 7 |

## 6. Open Questions

1. Repayment hierarchy order — confirm the exact bucket/plan allocation sequence per product (regulatory constraints differ by market).
Answer:1. Repayment Hierarchy (Bucket/Plan Allocation)
Configurable Parameter: repayment_hierarchy_order

Definition: Ordered list of buckets (fees, past‑due interest, current interest, principal, etc.) applied per product.

Implementation:

Store hierarchy in a market‑specific config file (JSON/YAML).

Allow overrides at product level (e.g., credit card vs. loan).

Example:

yaml
repayment_hierarchy_order:
  IN: [penalty_fees, past_due_interest, current_interest, principal]
  US: [past_due_interest, current_interest, principal, fees]

2. Penalty APR trigger DPD + cure definition — parameter exists (`penalty_apr_dpd_trigger`); confirm cure rules.
Answer: 2. Penalty APR Trigger & Cure Rules
Configurable Parameters:

penalty_apr_dpd_trigger → integer (days past due)

penalty_apr_cure_rule → string (definition of cure, e.g., “full arrears cleared + 2 cycles current”)

Implementation:

Define triggers and cure rules in config.

Example:

yaml
penalty_apr:
  IN:
    dpd_trigger: 60
    cure_rule: "arrears_cleared_and_2_cycles_current"
  EU:
    dpd_trigger: 90
    cure_rule: "arrears_cleared_immediately"

3. Which payment intake channels are in scope for v1 (gateway? direct debit mandates?).
Answer: Payment Intake Channels (Scope for v1)
Configurable Parameter: payment_channels_enabled

Definition: List of intake channels allowed per environment/version.

Implementation:

Maintain environment‑specific flags.

Example:

yaml
payment_channels_enabled:
  v1: [gateway, direct_debit]
  v2: [gateway, direct_debit, mobile_wallet, branch_cash]

4. Metro2 vs local-bureau format — confirm target bureaus per market.
Answer:Metro2 vs Local Bureau Format
Configurable Parameter: credit_reporting_format

Definition: Target bureau reporting format per market.

Implementation:

Map each market to its required format.

Example:

yaml
credit_reporting_format:
  US: "Metro2"
  IN: "CIBIL_local"
  UAE: "AlEtihad_local"

5. Multi-currency: single billing currency per account assumed — confirm no dual-currency statements needed.
Answer: No Dual Currency 
