# CMS — Feature Status (Consolidated)

**Status:** ✅ Current as of 2026-07-11. Supersedes `CMS_Module_Requirements.md`
§5's gap-analysis table, which was never updated after `CMS_Gap_Implementation_Tracker.md`
(CMS-G1–G5, 2026-07-04/05) closed nearly everything it listed as missing — see
[[reference-vmu-core-docs-layout]]'s general warning that trackers run ahead of
the requirements doc's gap table until someone reconciles them. This document is
that reconciliation.

## Methodology

Each FR below is cross-referenced against three sources: the native build
(`../CMS_Implementation_Tracker.md`, Sprints 1–4, 37/37 closed 2026-06-15), the
review-cycle gap closure (`CMS_Gap_Implementation_Tracker.md`, CMS-G1–G5,
2026-07-04/05), and — for every item marked ⬜ or 🔄 below — a direct `grep`
against `lib/vmu_core/cms/` performed today (2026-07-11), not just prose in a
tracker. Items marked ✅ without a fresh grep are taken on the trackers' verified
completion claims (each of those phases has its own live-data verification
section in its tracker) — see each tracker for the exact test performed.

## 1. Account Master (FR-CMS-001…015)

| FR | Feature | Status | Closed by |
|---|---|---|---|
| 001 | Account creation under CIF, LOGO/BLOCK assignment | ✅ | Native build + Phase 4A wizard |
| 002 | Account statuses (ACTIVE/INACTIVE/BLOCKED/SUSPENDED/CLOSED/CHARGED_OFF) | ✅ | Native build (`cms/account.ex`) |
| 003 | Block codes + history + operator audit | ✅ | Sprint 2A (`block_code_history.ex`) |
| 004 | Non-monetary maintenance (address/phone/email/cycle/emboss) | ✅ | Sprint 2F (`non_monetary_event.ex`) |
| 005 | Supplementary cards with sub-limits | ✅ | Sprint 2C (`supplementary_card.ex`) |
| 006 | Account transfer (LOGO-to-LOGO) | ✅ | CMS-G3.2 (`account_transfer.ex`) |
| 007 | Account closure workflow (block → zero → close; reopen) | ✅ | CMS-G3.1 (`account_closure.ex`) |
| 008 | Cycle code assignment | ✅ | Native build (`cycle_code` field) |
| 009 | Multi-currency billing | ✅ | Sprint 4B/4C |
| 010 | Memo/notes per account, operator-attributed | ⬜ | **Not found.** `NonMonetaryEvent` gives an audit trail of *structured* maintenance events, not a free-text memo field/screen. |
| 011 | Account-level flags: paperless, do-not-solicit, deceased, hardship | ⬜ | **Not found** — confirmed via grep, no such fields on `cms_accounts`. (Hardship is handled at the *case* level by `COL.WorkoutPlan`, not as an account flag.) |
| 012 | Emboss name + card ordering linkage | ✅ | Sprint 2B + CTA |
| 013 | Account short name / statement descriptor | ⬜ | **Not found** — confirmed via grep. |
| 014 | Charge-off + post-charge-off recovery accounting | ✅ | CMS-G4.3 (`charge_off_recovery.ex`) |
| 015 | Dormancy detection | ✅ | CMS-G3.3 |

## 2. Balances & Credit Limits (FR-CMS-016…030)

| FR | Feature | Status | Closed by |
|---|---|---|---|
| 016 | Balance buckets (retail/cash/fee/interest/BT) | ✅ | Native build |
| 017 | Open-to-buy (in-memory ASC) | ✅ | Native build |
| 018 | Cash advance sub-limit | ✅ | Sprint 1C |
| 019 | Permanent limit change with authority levels | ✅ | Native build + `FinancialAdjustment` 4-eyes pattern |
| 020 | Temporary limit (time-boxed, 4-eyes) | ✅ | Sprint 4G (`temp_limit.ex`) |
| 021 | Overlimit tolerance % | ✅ | Native build (ASC) |
| 022 | Daily balance snapshots for ADB | ✅ | Native phase-tracker G10 |
| 023 | Balance transfer intake + promo pricing | ✅ | Sprint 3C + `PlanSegment.effective_apr/1` |
| 024 | Credit balance (overpayment) refund workflow | ✅ | CMS-G4.1 (`credit_balance_refund.ex`) |
| 025 | Statement balance / min payment / due date | ✅ | Native build |
| 026 | Past-due amount tracking per cycle | ✅ | Native build (delinquency bucket + ledger) |
| 027 | Multi-plan PLAN segments (RETAIL/CASH/EMI/BT) | ✅ | Sprint 1B |
| 028 | EMI conversion (transaction → instalment schedule) | 🔄 | Sprint 3B built the schedule *engine* (`EmiSchedule.create_schedule/1`); no confirmed UI/API trigger converts a specific purchase to EMI at point of use — worth a direct check before assuming it's reachable end-to-end. |
| 029 | EMI foreclosure / pre-payment with fee | ⬜ | **Not found** — confirmed via grep. |
| 030 | Customer-level exposure roll-up | ✅ | CMS-G5.1 (`customer_exposure.ex`) |

## 3. Interest & Fees (FR-CMS-031…045)

| FR | Feature | Status | Closed by |
|---|---|---|---|
| 031 | ADB interest per bucket, per plan APR | ✅ | Native build |
| 032 | Grace period logic | ✅ | Native build |
| 033 | Cash advance interest, no grace | ✅ | Native build |
| 034 | Penalty APR trigger + persistence + cure | ✅ | Sprint 3K + CMS-G1.4 (ADR-C2) |
| 035 | Daily accrual, billed at cycle | ✅ | Native build |
| 036 | Fee engine (annual/late/overlimit/cash/FX/replacement) | 🔄 | Annual/late/overlimit/cash/FX/replacement all confirmed in `fee_engine.ex`/`fx_engine.ex`; **"statement copy fee" specifically not confirmed**. |
| 037 | Fee waiver with 4-eyes + history | ✅ | Sprint 2J (`fee_waiver.ex`) |
| 038 | Fee caps / regulatory maxima per jurisdiction | ⬜ | **Not found** — confirmed via grep; parameters carry fee *values* but no dedicated regulatory-ceiling enforcement layer. |
| 039 | Interest/fee reversal (statement reversal + recompute) | ✅ | Sprint 3A (`statement_reversal.ex`) |
| 040 | Promotional pricing windows | ✅ | `PlanSegment` promo fields + CMS-G4.2 expiry cleanup |
| 041 | Trial balance: interest accrued vs. billed | 🔄 | **Not the specific reconciliation asked for.** `FAS.GL.TrialBalance` exists but is a general GL trial-balance-by-account-code report (FAS-P8), not an accrued-vs-billed interest variance report. |
| 042 | FX conversion + markup fee | ✅ | Sprint 4A |
| 043 | Interest rate change orchestration (re-price on parameter change) | ✅ | Structural — `ParameterWriter` refreshes ETS (3L); next accrual naturally reads the new rate. No separate "re-price existing balances" batch exists, but none is needed since accrual is recomputed fresh every cycle. |
| 044 | Financial adjustments (4-eyes) | ✅ | Sprint 2I (`financial_adjustment.ex`) |
| 045 | Configurable repayment hierarchy | ✅ | CMS-G1.3 |

## 4. Billing Cycle / EOD (FR-CMS-046…060)

| FR | Feature | Status | Closed by |
|---|---|---|---|
| 046 | EOD scheduler (per-cycle-code nightly orchestration) | ✅ | Sprint 2G |
| 047 | Account lock during EOD | ✅ | Native build |
| 048 | Interest accrual job | ✅ | Native build |
| 049 | Fee assessment job | ✅ | Sprint 1D |
| 050 | Statement generation | ✅ | Native build |
| 051 | Statement line feed from TRAMS | ✅ | TRAM-P5 |
| 052 | Delinquency aging (bucket roll) | ✅ | Native build, extended to 150/180 in COL-P2/P3 |
| 053 | Payment due processing + past-due marking | ✅ | Native build |
| 054 | GL flush to core banking / external GL | ✅ | Sprint 3J |
| 055 | Daily balance snapshot job | ✅ | Native phase-tracker G10 |
| 056 | Bureau reporting extract (Metro2 + local formats) | ✅ | Sprint 4E + CMS-G5.2 (CIBIL TUDF, AECB) |
| 057 | **EOD job status visibility + rerun controls** | ✅ | **Done 2026-07-24** — `VmuCore.CMS.EodMonitor` (reads `Oban.Job` directly — `eod_date` in job args is the natural run-grouping key, no new table) + `CmsEodComponent` admin screen: per-run/per-stage state-count overview, a "needs attention" list (retryable/discarded, plus jobs stuck `executing` past 30 min — Oban has no automatic recovery for those without `Lifeline`, and this dev DB genuinely had 2 such stuck rows found live), and a retry action gated to real failures only (never a stuck-executing row, to avoid a possible duplicate GL post). 3/3 tests passing. See `Way4_Parity_Implementation_Plan.md` Phase 0 item 3. |
| 058 | Cycle resegmentation batch | ✅ | **Done 2026-07-24** — `VmuCore.CMS.CycleResegmentation` + `CmsResegmentationComponent` admin screen. Every policy lever bank-configurable per `VmuCore.CMS.ConfigCatalog` (mode manual/auto, notice-period days, min-interval-between-changes months, rebalance-imbalance threshold, allowed billing days, proration method captured for audit) — no hardcoded regional rules. A resegmentation is never instant: `schedule_resegmentation/3` sets pending fields only, a real daily EOD job (`ApplyCycleResegmentationJob`, found+fixed a pre-existing bug where its sibling `ReinstateLimitJob` silently never ran on days with zero due cycle_codes) applies it once the configured notice period elapses. 18/18 tests passing. Explicit scope limit, flagged not silently missing: the interest engine doesn't yet consume the captured proration_method to adjust its day-count math across a resegmentation boundary. |
| 059 | Dormancy / inactivity sweep | ✅ | CMS-G3.3 |
| 060 | Statement reversal + regeneration | ✅ | Sprint 3A |

## 5. Payments (FR-CMS-061…070)

| FR | Feature | Status | Closed by |
|---|---|---|---|
| 061 | Payment intake channels (branch/transfer/direct debit/gateway) | ✅ | CMS-G1.5 (`PaymentIntake`); COL-P8 added `"agency"` as a channel |
| 062 | Repayment distribution per hierarchy | ✅ | Native build + CMS-G1.3 |
| 063 | Partial / full / overpayment handling | ✅ | CMS-G4.1 (credit balance) |
| 064 | Payment reversal (bounce/return) | ✅ | CMS-G2.1 (`payment_reversal.ex`) |
| 065 | Autopay mandates | ✅ | CMS-G2.2 |
| 066 | Payment holidays / hardship plans | ✅ | Cross-module: `COL.WorkoutCommand` `PAYMENT_HOLIDAY` (COL-P9), wired into `AgeBucketsJob` |
| 067 | **Transaction-level payment allocation** (dispute/EMI/BNPL precision) | ✅ | **Done 2026-07-24** — `VmuCore.CMS.TransactionAllocation` (new `cms_transaction_allocations` table) + `VmuCore.CMS.PaymentAllocation`, sub-allocating a bucket-level payment across the account's real outstanding transactions in that bucket (`retail_balance`/`cash_balance`/`bt_balance`). Method (fifo/lifo/highest_amount_first/proportional) and whether disputed transactions are skipped are both bank-configurable via `VmuCore.CMS.ConfigCatalog` (`payment_allocation_method`, `exclude_disputed_from_allocation`), not hardcoded, per region/regulatory requirement. Wired into `PaymentIntake.apply_payment/5` right after the existing bucket-level distribution — never re-decides amounts, only adds transaction-level detail on top. **Foundational gap found and fixed along the way**: purchases were never populating any transaction-level record at all — `VmuCore.CMS.PurchasePosting` (new) closes that by hooking `FAS.SettlementPostingAdapter.confirm_one/1` (the sole real settlement-confirmation path, reached from both the auth-consumer and the TRAMS posting-cycle job) to post each settled purchase into `cms_transaction_allocations` and increment the matching `BalanceBucket` field atomically with the existing GL post, idempotent on the same `"settlement:<approval_code>:<rrn>"` key already used elsewhere. 14/14 tests passing (5 `PurchasePostingTest` + 10 `PaymentAllocationTest`, 1 shared fixture pattern). Deliberately not backfilled: existing pre-feature balances have no transaction-level detail behind them and are left as-is; only purchases posted from now on get FR-067 precision. |
| 068 | OTB restore on payment | ✅ | CMS-G1.5 |
| 069 | Unapplied / suspense payment handling | ✅ | CMS-G2.3 |
| 070 | Payment receipt notification triggers | ⬜ | **Not found** — confirmed via grep; no notification/messaging dispatch on payment receipt anywhere in `cms/`. |

## Summary

| Section | ✅ Done | 🔄 Partial | ⬜ Missing | Total |
|---|---:|---:|---:|---:|
| Account Master | 12 | 0 | 3 | 15 |
| Balances & Limits | 13 | 1 | 1 | 15 |
| Interest & Fees | 12 | 2 | 1 | 15 |
| Billing Cycle / EOD | 15 | 0 | 0 | 15 |
| Payments | 9 | 0 | 1 | 10 |
| **Total** | **61** | **3** | **6** | **70** |

**87% done, 4% partial, 9% genuinely open** (updated 2026-07-24 — FR-067
closed, see its row above). Remaining CMS backlog:
FR-010 (memo), FR-011 (account flags), FR-013 (short name), FR-029 (EMI
foreclosure), FR-038 (fee caps), FR-070 (payment notifications).
