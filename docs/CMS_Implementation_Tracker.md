# E-VisionPlus CMS — Implementation Phase Tracker

> **How to use:** Update the `Status` column as each gap is closed.
> Statuses: `✅ Done` · `🔄 In Progress` · `⬜ Pending` · `➖ Not Applicable`
>
> Source of truth for this tracker: `vmu_core/docs/CMS_Gap_Analysis.docx`
> Last updated: 2026-06-15 (All sprints complete — 37/37 gaps closed)

---

## Sprint 1 — P1-Critical: Unblock Live Issuing

| # | Gap | File(s) Changed | Status | Completed |
|---|-----|----------------|--------|-----------|
| 1A | Extend LOGO parameters (purchase_apr, cash_apr, penalty_apr, promo_apr, fees, billing flags) | `shared/logo_parameter.ex` · `migrations/20260616000002_extend_logo_parameters.exs` · `shared/parameter_engine.ex` | ✅ Done | 2026-06-15 |
| 1B | Create PLAN segment (RETAIL / CASH / EMI / BALANCE_TRANSFER) | `cms/plan_segment.ex` · `migrations/20260616000003_create_plan_segments.exs` | ✅ Done | 2026-06-15 |
| 1C | Add cash_limit + cash_open_to_buy to accounts; enforce in AccountStateCoordinator | `cms/account.ex` · `migrations/20260616000004_add_cash_limit_to_accounts.exs` · `cms/account_state_coordinator.ex` | ✅ Done | 2026-06-15 |
| 1D | FeeEngine: assess_late_fee, assess_overlimit_fee, assess_annual_fee, assess_returned_payment_fee | `cms/fee_engine.ex` · `cms/eod/age_buckets_job.ex` · `cms/eod/flush_gl_job.ex` | ✅ Done | 2026-06-15 |
| 1E | Fix AgeBucketsJob paid_this_cyc stub → real SUM query on cms_ledger_entries | `cms/eod/age_buckets_job.ex` | ✅ Done | 2026-06-15 |

**Sprint 1 Progress: 5 / 5 complete ✅**

---

## Sprint 2 — P2-High: Complete Billing Cycle

| # | Gap | File(s) to Change | Status | Completed |
|---|-----|------------------|--------|-----------|
| 2A | Block codes as distinct field (`block_code` VARCHAR 2) + `block_code_history` table with operator audit | `cms/account.ex` · `cms/block_code_history.ex` · migrations/20260616000005+006 | ✅ Done | 2026-06-15 |
| 2B | Card `emboss_name` field on cms_accounts | `cms/account.ex` · migration/20260616000005 · `cta/card_activation.ex` | ✅ Done | 2026-06-15 |
| 2C | Supplementary cards (`supplementary_cards` table; primary ↔ supplementary relationship) | `cms/supplementary_card.ex` · migration/20260616000007 | ✅ Done | 2026-06-15 |
| 2D | Separate cash APR in ParameterEngine (currently single `apr_percentage`; needs `cash_apr` routed from logo) | `shared/block_parameter.ex` · `shared/parameter_engine.ex` · `cms/interest_engine.ex` · `migrations/20260616000009` | ✅ Done | 2026-06-15 |
| 2E | Compound minimum payment formula: `interest_due + fees_due + past_due + max(1% principal, floor)` | `cms/interest_engine.ex` (rewritten `minimum_payment/5`) | ✅ Done | 2026-06-15 |
| 2F | Non-monetary event model (address_change, phone_change, cycle_change, card_reissue) | New `cms/non_monetary_event.ex` · `migrations/20260616000010` | ✅ Done | 2026-06-15 |
| 2G | EOD billing cycle scheduler (enqueue LockAccountsJob for each active cycle_code each day) | New `cms/eod/eod_scheduler_job.ex` · Oban cron config in `config.exs` | ✅ Done | 2026-06-15 |
| 2H | Date of first delinquency in Metro 2 (field positions 111–118 currently always blank) | `cms/metro2_generator.ex` (`build_dofd/2`, `fetch_dofd/2`) | ✅ Done | 2026-06-15 |
| 2I | Financial adjustment operator function (manual credit/debit with supervisor approval) | New `cms/financial_adjustment.ex` | ✅ Done | 2026-06-15 |
| 2J | Fee waiver operator function (supervisor action, posts REVERSAL against unpaid_fee entry) | New `cms/fee_waiver.ex` | ✅ Done | 2026-06-15 |
| 2K | SYS parameters: add batch_controls, cycle_controls, global_status_codes, posting_rules | `shared/sys_parameter.ex` · `shared/parameter_engine.ex` · migration/20260616000008 | ✅ Done | 2026-06-15 |
| 2L | BANK parameters: add tax_rule, gl_mapping_profile, delinquency_rules, settlement_calendar, swift_bic | `shared/bank_parameter.ex` · `shared/parameter_engine.ex` · migration/20260616000008 | ✅ Done | 2026-06-15 |

**Sprint 2 Progress: 12 / 12 complete ✅**

---

## Sprint 3 — P2-High / P3-Medium: Operational Completeness

| # | Gap | File(s) to Change | Status | Completed |
|---|-----|------------------|--------|-----------|
| 3A | Statement reversal / rebilling function | New `cms/statement_reversal.ex` · `cms/statement_generator.ex` | ✅ Done | 2026-06-15 |
| 3B | EMI instalment balance bucket + EMI schedule table | `migrations/20260616000011` · `cms/balance_bucket.ex` · new `cms/emi_schedule.ex` | ✅ Done | 2026-06-15 |
| 3C | Balance transfer plan billing logic | `cms/interest_engine.ex` (`calculate/8`) · `cms/repayment_distributor.ex` · `cms/balance_bucket.ex` (`bt_balance`) · `migrations/20260616000012` | ✅ Done | 2026-06-15 |
| 3D | Enhance CMS01: bucket breakdown (retail / cash / interest / fees), block code detail, supplementary cards | `visionplus_live.ex` (CMS01 render) | ✅ Done | 2026-06-15 |
| 3E | Enhance CMS02: fee waiver, interest adjustment, temporary limit with expiry, block/unblock with reason | `visionplus_live.ex` (CMS02 render) | ✅ Done | 2026-06-15 |
| 3F | Company customer support (company_name, registration_number in cms_customers) | `shared/customer.ex` · `migrations/20260616000013` | ✅ Done | 2026-06-15 |
| 3G | Customer-to-account reverse query helper + duplicate detection | `shared/customer.ex` (`list_accounts_for/1`, `find_duplicates/1`) | ✅ Done | 2026-06-15 |
| 3H | Configurable payment hierarchy at PLAN level in ParameterEngine | `cms/repayment_distributor.ex` (`distribute_with_plan_priority/3`, `build_plan_hierarchy/1`) | ✅ Done | 2026-06-15 |
| 3I | Card inquiry operational screen (card status, expiry, emboss name, supplementary list) | `visionplus_live.ex` (new CMS05 screen) | ✅ Done | 2026-06-15 |
| 3J | GL extract to core banking adapter (FlushGlJob currently logs only) | New `cms/core_banking_adapter.ex` · `cms/eod/flush_gl_job.ex` · `cms/ledger_entry.ex` · `migrations/20260616000015` | ✅ Done | 2026-06-15 |
| 3K | Penalty APR escalation on delinquency | `shared/logo_parameter.ex` (`penalty_apr_dpd_trigger`) · `shared/parameter_engine.ex` · `cms/eod/accrue_interest_job.ex` · `migrations/20260616000014` | ✅ Done | 2026-06-15 |
| 3L | ParameterEngine auto-refresh on parameter update | New `shared/parameter_writer.ex` (wraps all parameter Repo writes, calls `ParameterEngine.refresh_all/0` on commit) | ✅ Done | 2026-06-15 |

**Sprint 3 Progress: 12 / 12 complete ✅**

---

## Sprint 4 — P3-Medium / P4-Low: Multi-Currency & Bureau

| # | Gap | File(s) to Change | Status | Completed |
|---|-----|------------------|--------|-----------|
| 4A | FX rates table + conversion engine | New `cms/fx_rate.ex` · `cms/fx_engine.ex` · `migrations/20260616000016` | ✅ Done | 2026-06-15 |
| 4B | Multi-currency balance buckets (currency column on cms_balance_buckets) | `cms/balance_bucket.ex` · `migrations/20260616000017` | ✅ Done | 2026-06-15 |
| 4C | Multi-org isolation (base_currency, billing_timezone, regulatory_regime per bank) | `shared/bank_parameter.ex` · `shared/parameter_engine.ex` · `migrations/20260616000018` | ✅ Done | 2026-06-15 |
| 4D | Metro 2 J1 segment (consumer name block) | `cms/metro2_generator.ex` (`build_j1_segment/1`, `parse_consumer_name/1`) | ✅ Done | 2026-06-15 |
| 4E | Production BureauAdapter.submit_metro2_file/1 | New `cms/bureau_adapter.ex` (stub/sftp/http) · `migrations/20260616000019` | ✅ Done | 2026-06-15 |
| 4F | Card replacement fee posting on reissue event | `cms/fee_engine.ex` (`assess_card_replacement_fee/4`) · `cms/non_monetary_event.ex` (`record_card_reissue/2`) · `migrations/20260616000021` | ✅ Done | 2026-06-15 |
| 4G | Temporary credit limit with expiry_date + auto-reinstatement | New `cms/temp_limit.ex` · `cms/eod/reinstate_limit_job.ex` · CMS02 LiveView (temp limit section) · `migrations/20260616000020` | ✅ Done | 2026-06-15 |
| 4H | STIP processing engine (stand-in authorization thresholds) | New `cms/stip_engine.ex` · `shared/logo_parameter.ex` (stip fields) · `shared/parameter_engine.ex` · `migrations/20260616000021` | ✅ Done | 2026-06-15 |

**Sprint 4 Progress: 8 / 8 complete ✅**

---

## Overall Progress

| Sprint | Priority | Total | Done | In Progress | Pending |
|--------|----------|-------|------|-------------|---------|
| Sprint 1 | P1-Critical | 5 | 5 | 0 | 0 |
| Sprint 2 | P2-High | 12 | 12 | 0 | 0 |
| Sprint 3 | P2-High / P3-Medium | 12 | 12 | 0 | 0 |
| Sprint 4 | P3-Medium / P4-Low | 8 | 8 | 0 | 0 |
| **TOTAL** | | **37** | **37** | **0** | **0** |

**Overall: 37 / 37 gaps closed (100%) 🎉**

---

## Key Files Reference

| Area | Schema | Migration |
|------|--------|-----------|
| Control Records | `shared/{sys,bank,logo,block}_parameter.ex` | `20260612205855_create_parameter_tables.exs` · `20260616000002_extend_logo_parameters.exs` · `20260616000009_add_cash_apr_to_block_parameters.exs` · `20260616000014_add_penalty_apr_dpd_trigger.exs` |
| Parameter Write Path | `shared/parameter_writer.ex` | — (wraps Repo + auto-refresh) |
| Plan Segment | `cms/plan_segment.ex` | `20260616000003_create_plan_segments.exs` |
| Account | `cms/account.ex` | `20260613171914_create_cms_accounts.exs` · `20260616000004_add_cash_limit_to_accounts.exs` |
| Customer | `shared/customer.ex` | `20260616000013_add_company_fields_to_customers.exs` |
| Balance Buckets | `cms/balance_bucket.ex` | `20260613171914_create_cms_accounts.exs` · `20260616000011_create_cms_emi_schedules.exs` (emi_balance) · `20260616000012_add_bt_balance.exs` |
| GL Ledger | `cms/ledger_entry.ex` | `20260613172002_create_cms_ledger_and_velocity.exs` · `20260616000015_add_extracted_at.exs` |
| EMI Schedule | `cms/emi_schedule.ex` | `20260616000011_create_cms_emi_schedules.exs` |
| Non-Monetary Events | `cms/non_monetary_event.ex` | `20260616000010_create_cms_non_monetary_events.exs` |
| Fee Engine | `cms/fee_engine.ex` · `cms/fee_waiver.ex` | — |
| Financial Adjustment | `cms/financial_adjustment.ex` | — |
| Statement Reversal | `cms/statement_reversal.ex` | — |
| Interest Engine | `cms/interest_engine.ex` | — (calculate/6 and calculate/8) |
| Repayment Distributor | `cms/repayment_distributor.ex` | — (plan-priority + BT support) |
| Core Banking Adapter | `cms/core_banking_adapter.ex` | — (3J GL extract) |
| EOD Jobs | `cms/eod/*.ex` | — |
| AccountStateCoordinator | `cms/account_state_coordinator.ex` | — |
| ParameterEngine | `shared/parameter_engine.ex` | — |
| Metro 2 | `cms/metro2_generator.ex` | — |

---

*This tracker is maintained manually. Update the Status column and Completed date after each merge.*
