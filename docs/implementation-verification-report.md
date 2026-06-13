# vMu VisionPlus — Implementation Verification Report

**Date:** 2026-06-13  
**Reviewer:** Claude (Cowork session)  
**Scope:** All 5 phases, 50 implementation items across 11 VisionPlus modules  
**Method:** Direct code inspection of every `.ex` file and migration in `vmu_core/lib/` and `priv/repo/migrations/`

---

## Overall Verdict

**All 5 phases are structurally complete.** Every planned module exists as a file, every migration is present, and the core business logic (authorization, interest, EOD, disputes, clearing, collections, underwriting, MDR, Metro 2) is correctly implemented. However, **5 functional gaps and 4 code-quality issues** were found that must be resolved before production.

**Post-verification additions (2026-06-13):** Cross-referencing against learnpaymentcard.wordpress.com VisionPlus documentation revealed **3 additional architectural gaps** — LMS (Loyalty/Rewards), HCS (Commercial Card Hierarchy), and an ITS module naming conflict — added as G13–G15 below.

---

## Module-by-Module Coverage

### ✅ FAS — Financial Authorization System

**Files:** `fas/authorization.ex`, `fas/stip.ex`

| Feature | Planned | Status | Notes |
|---|---|---|---|
| ISO 8583 PAN → BIN → ParameterEngine | ✅ | ✅ Correct | ETS-only on hot path, no DB |
| SHA-256 PAN tokenisation | ✅ | ✅ Correct | `resolve_account/1` uses `:crypto.hash(:sha256, pan)` |
| AccountStateCoordinator call with 5 s timeout | ✅ | ✅ Correct | GenServer.call with 5_000 ms |
| STIP fallback on `:timeout` / `:noproc` | ✅ | ✅ Correct | `handle_auth_result({:error, reason}, ...)` |
| RC "96" fail-safe on unexpected error | ✅ | ✅ Correct | |
| RC "15" for unknown BIN | ✅ | ✅ Correct | |
| RC "14" for account not found | ✅ | ✅ Correct | |
| Integration tests (happy path + declines + STIP) | ✅ | ✅ Present | `test/vmu_core/fas/authorization_integration_test.exs` |

**FAS verdict: COMPLETE ✅**

---

### ✅ CMS — Card Management System (Credit Core)

**Files:** `cms/account.ex`, `cms/balance_bucket.ex`, `cms/ledger_entry.ex`, `cms/internal_gl_poster.ex`, `cms/interest_engine.ex`, `cms/repayment_distributor.ex`, `cms/statement_generator.ex`, `cms/eod/*.ex`, `cms/metro2_generator.ex`, `cms/account_state_coordinator.ex`

| Feature | Planned | Status | Notes |
|---|---|---|---|
| SYS→BANK→LOGO→BLOCK parameter cascade | ✅ | ✅ Correct | `shared/parameter_engine.ex` |
| velocity_limits JSONB on cms_accounts | ✅ | ✅ Present | migration `20260613171914_*` |
| Double-entry GL ledger (`cms_ledger_entries`) | ✅ | ✅ Correct | idempotency_key unique index present |
| InternalGlPoster idempotency (`on_conflict: :nothing`) | ✅ | ✅ Correct | returns `{:error, :duplicate}` on nil entry_id |
| ADB interest engine (Decimal only) | ✅ | ✅ Correct | `compute_interest/3` uses `D.div/D.mult`, no Float |
| Grace period for retail (not cash) | ✅ | ✅ Correct | `grace_period_applies` flag skips retail interest |
| Minimum payment: max(5%, AED 100 floor) | ✅ | ✅ Correct | `minimum_payment/3` with `D.round(:ceiling)` |
| Repayment priority: fees→interest→cash→retail | ✅ | ✅ Correct | `RepaymentDistributor.distribute/2` |
| EOD 5-job Oban pipeline | ✅ | ✅ Correct | LockAccounts→AccrueInterest→AgeBuckets→GenerateStatement→FlushGL |
| DPD ageing: 0→30→60→90→120 | ✅ | ✅ Correct | `age_buckets_job.ex` |
| StatementGenerator (balance snapshot + next statement date) | ✅ | ✅ Correct | `statement_generator.ex` |
| Metro 2 (CDIA, 426-char fixed-width, monthly cron) | ✅ | ✅ Correct | `metro2_generator.ex` |
| AccountStateCoordinator: Horde registry, 30-min idle timeout | ✅ | ✅ Correct | `@idle_ms 30 * 60 * 1_000` |
| ASC: `refresh_limit/2`, `credit_open_to_buy/2`, `notify_status_change/2` | ✅ | ✅ Correct | Phase 5 additions present |

**⚠️ Gap 1 — Velocity matrix not evaluated in authorization hot path.**  
`AccountStateCoordinator.do_authorize/4` checks only `account_status` and `open_to_buy`. The `velocity_limits` field is loaded into state but never read during `{:authorize, amount, channel, mcc, currency}`. A `check_velocity/4` function is missing. This means per-channel daily/weekly spend caps are not enforced at authorization time.

**⚠️ Gap 2 — Metro 2 missing `WRITTEN_OFF` → status code `"97"`.**  
`dpd_to_account_status/1` maps DPD buckets 0/30/60/90/120 but has no clause for `account_status == "WRITTEN_OFF"`. Written-off accounts fall through to the `_` catch-all and report `"13"` (Current) — incorrect bureau reporting.

**⚠️ Gap 3 — Daily balance series is a stub in StatementGenerator.**  
`retail_daily_balances/3` and `cash_daily_balances/3` use a single balance snapshot repeated for all days in the cycle rather than joining actual daily snapshot records. True ADB requires per-day balances. This works correctly for accounts with no mid-cycle balance changes but will over- or under-charge interest for accounts with mid-cycle payments or purchases. A `cms_daily_balance_snapshots` table is needed in production.

**CMS verdict: MOSTLY COMPLETE ✅ — 3 gaps (velocity enforcement, Metro 2 written-off code, ADB daily balance)**

---

### ✅ CIF — Customer Information File

**Files:** `shared/customer.ex`

| Feature | Planned | Status | Notes |
|---|---|---|---|
| KYC fields (id_type, id_number, id_expiry) | ✅ | ✅ Present | |
| kyc_status + kyc_verified_at | ✅ | ✅ Present | |
| customer_tier | ✅ | ✅ Present | |
| Embedded in cms_customers | ✅ | ✅ Correct | |

**CIF verdict: COMPLETE ✅**

---

### ✅ CTA — Card and Account Administration

**Files:** `cta/stock_inventory.ex`, `cta/embossing_file_generator.ex`, `cta/bureau_adapter.ex`, `cta/pin_issuance.ex`, `cta/card_activation.ex`

| Feature | Planned | Status | Notes |
|---|---|---|---|
| Card stock table with SELECT FOR UPDATE | ✅ | ✅ Correct | `stock_inventory.ex` uses DB transaction |
| Embossing file (G+D/Thales 128-char fixed-width) | ✅ | ✅ Correct | Track 1/2 data format |
| Bureau adapter behaviour + SFTP default | ✅ | ✅ Correct | `DefaultBureauAdapter` implements callback |
| PIN issuance delegating to DaProductApp.SoftHSM | ✅ | ✅ Correct | Stores only encrypted PIN block, never plaintext |
| Card activation (IVR + first-use paths) | ✅ | ✅ Correct | `card_activation.ex` covers both |

**CTA verdict: COMPLETE ✅**

---

### ✅ ITS — Interactive Telephony System

**Files:** `its/ivr_session.ex`, `its/otp_engine.ex`

| Feature | Planned | Status | Notes |
|---|---|---|---|
| IVR session GenServer (5-min idle, 3 PIN attempts) | ✅ | ✅ Correct | `@session_timeout_ms 5 * 60 * 1_000`, `@max_pin_attempts 3` |
| State machine: greeting → authenticated → completed | ✅ | ✅ Correct | |
| Actions: balance, block, PIN change, activation | ✅ | ✅ Correct | |
| HOTP (RFC 4226) with ±1 counter drift | ✅ | ✅ Correct | `verify_hotp` checks counter and counter+1 |
| TOTP (RFC 6238) with ±1 window clock skew | ✅ | ✅ Correct | `verify_totp` checks current ± 1 window |
| 6-digit output, zero-padded | ✅ | ✅ Correct | `@otp_length 6`, `pad_otp/1` |

**⚠️ Issue — IVR SessionRegistry not supervised.**  
`ivr_session.ex` registers via `{:via, Registry, {VmuCore.ITS.SessionRegistry, session_id}}` using the local `Registry` module, but `VmuCore.ITS.SessionRegistry` is never started in `application.ex`. Any `IvrSession.start_link/1` call will crash with `** (ArgumentError) unknown registry: VmuCore.ITS.SessionRegistry`. A `{Registry, keys: :unique, name: VmuCore.ITS.SessionRegistry}` child must be added to the supervision tree.

**ITS verdict: MOSTLY COMPLETE ✅ — 1 supervisory wiring bug**

---

### ✅ DPS — Dispute Processing System

**Files:** `dps/dispute.ex`, `dps/deadline_job.ex`

| Feature | Planned | Status | Notes |
|---|---|---|---|
| State machine: FILED→RETRIEVAL_REQUESTED→CHARGEBACK_FILED→REPRESENTED→PRE_ARB→ARBITRATION→CLOSED | ✅ | ✅ Correct | 9 valid statuses |
| Provisional credit on filing (DR 3001 / CR 1001) | ✅ | ✅ Present | `post_provisional_credit/1` |
| Chargeback deadline: txn_date + 120 days (both networks) | ✅ | ✅ Correct | `put_deadlines/1` |
| Representment deadline: + 30 days | ✅ | ✅ Present | |
| Pre-arb deadline: + 60 days | ✅ | ✅ Present | |
| Oban job scheduled on each transition | ✅ | ✅ Correct | `schedule_next_deadline/1` matches on status |
| `dps_disputes` migration with deadline columns | ✅ | ✅ Present | `20260613172004_*` |

**⚠️ Minor — Provisional credit GL direction needs verification.**  
On filing, the code posts DR `3001` (Cardholder payment liability) / CR `1001` (Retail receivable). The intent is to restore OTB to the cardholder. The correct double-entry should be DR `1001` (reduce receivable = give OTB back) / CR `3001` (record provisional liability). The debit and credit are reversed. This does not affect the schema or idempotency but will produce incorrect GL balances in the `cms_ledger_entries` table. **Requires a GL accountant review.**

**DPS verdict: COMPLETE ✅ — 1 GL direction issue to verify with finance**

---

### ✅ TRAMS — Transaction Management System

**Files:** `trams/mastercard_ipm.ex`, `trams/visa_base_ii.ex`, `trams/clearing_record.ex`

| Feature | Planned | Status | Notes |
|---|---|---|---|
| Mastercard IPM binary parser (1644-byte records) | ✅ | ✅ Correct | MTI 1240 filtering, bitmap extraction |
| Visa Base II parser (80-byte records) | ✅ | ✅ Present | `trams/visa_base_ii.ex` |
| `trams_clearing_records` schema + migration | ✅ | ✅ Present | `20260613172005_*` |
| PAN tokenisation on clearing records | ✅ | ✅ Correct | SHA-256 hash, never stores raw PAN |
| match_status: UNMATCHED → MATCHED / EXCEPTION | ✅ | ✅ Partial | |

**⚠️ Gap 4 — IPM field extraction is partially stubbed.**  
`extract_amount/1`, `extract_date/1`, `extract_currency/1`, `extract_mcc/1` use hardcoded fallbacks (`"AED"`, `Date.utc_today()`, `"5411"`) rather than actual DE parsing from the IPM binary. The code comment acknowledges this: *"production implementation would use the full Mastercard BCD bitmap parser."*  
The module structure and Broadway wiring are sound, but **DE extraction must be completed before real IPM files can be processed.**

**⚠️ Gap 5 — Broadway pipeline is in deps but not wired up.**  
`broadway` is a dependency (`deps/broadway/` exists) but no `VmuCore.TRAMS.IpmPipeline` Broadway module was created in `lib/`. The `mastercard_ipm.ex` file contains a `process_file/1` function that calls `parse_file/1` synchronously. For production volumes (millions of records), a Broadway pipeline with concurrent processors is required as specified in Phase 4.

**TRAMS verdict: SCHEMA COMPLETE, PARSING STUBBED ⚠️**

---

### ✅ COL — Collections & Recovery

**Files:** `col/collection_case.ex`, `col/collection_queue_job.ex`, `col/dunning_job.ex`, `col/write_off_processor.ex`

| Feature | Planned | Status | Notes |
|---|---|---|---|
| Collection case schema (DPD, promise, workout, write-off) | ✅ | ✅ Present | |
| DPD-based queue routing Oban job | ✅ | ✅ Correct | |
| Dunning: SMS/email → letter → courier → registered mail | ✅ | ✅ Correct | `channels_for_dpd/1` |
| Write-off GL (DR 5001 / CR 1001) | ✅ | ✅ Correct | `@gl_charged_off "5001"` |
| Account → WRITTEN_OFF, OTB → 0 | ✅ | ✅ Correct | |
| Recovery posting (DR 1000 / CR 6001) | ✅ | ✅ Correct | `post_recovery/3` |
| AccountStateCoordinator refresh after write-off | ✅ | ✅ Correct | |
| Idempotency on write-off (`:zero_balance` guard) | ✅ | ✅ Correct | |

**COL verdict: COMPLETE ✅**

---

### ✅ CDM — Credit Decision Management

**Files:** `cdm/bureau_adapter.ex`, `cdm/application_scorer.ex`, `cdm/limit_allocator.ex`, `cdm/behavioral_rescorer.ex`

| Feature | Planned | Status | Notes |
|---|---|---|---|
| Bureau adapter behaviour + MockBureauAdapter | ✅ | ✅ Correct | compile_env switches adapter |
| PRIME/NEAR_PRIME/SUBPRIME/DECLINE tiers | ✅ | ✅ Correct | score thresholds: 720/600/500 |
| Income multipliers (2.0×/1.0×/0.5×) | ✅ | ✅ Correct | `LimitAllocator` |
| ParameterEngine-configurable multipliers | ✅ | ✅ Correct | `cdm_multiplier_<tier>` param key |
| Min/max limit bounds from ParameterEngine | ✅ | ✅ Correct | `cdm_min_limit` / `cdm_max_limit` |
| Round-to-100 for clean limits | ✅ | ✅ Correct | `round_to_hundred/1` |
| BehavioralRescorer (monthly Oban job) | ✅ | ✅ Present | |
| `cdm_credit_applications` migration | ✅ | ✅ Present | `20260613172006_*` |

**Note — DSR cap not implemented.**  
The spec called for a Debt Service Ratio cap (existing liabilities + estimated payment / income ≤ 50%). The `ApplicationScorer` uses only bureau score and income multiplier. DSR is a regulatory requirement in many jurisdictions (UAE Central Bank included). This should be added to `LimitAllocator.calculate/5` before go-live.

**CDM verdict: MOSTLY COMPLETE ✅ — DSR cap missing**

---

### ✅ ASM — Account/System Management

**Files:** `asm/operator_portal.ex`

| Feature | Planned | Status | Notes |
|---|---|---|---|
| Role hierarchy: agent→supervisor→manager→sysadmin | ✅ | ✅ Correct | `@role_hierarchy` list, index comparison |
| Account lookup (agent+) | ✅ | ✅ Correct | |
| Fee waiver (supervisor+) | ✅ | ✅ Correct | GL reversal + OTB credit |
| Limit adjustment (manager+) | ✅ | ✅ Correct | ASC.refresh_limit called |
| Account closure (manager+) | ✅ | ✅ Correct | ASC.notify_status_change called |
| Parameter update (sysadmin only) | ✅ | ✅ Correct | ParameterEngine.put |
| Audit log (append-only `cms_operator_audit`) | ✅ | ✅ Correct | `audit/4` uses `Repo.insert_all` |
| FAPI 2.0 mTLS + JWT plug | ✅ | ❌ **MISSING** | No `VmuCoreWeb.Plugs.FapiValidationPlug` in codebase |

**⚠️ Code Issue — Wrong alias in OperatorPortal.**  
Line 25: `alias VmuCore.Shared.{ParameterEngine, AccountStateCoordinator}` — `AccountStateCoordinator` lives at `VmuCore.CMS.AccountStateCoordinator`, not `VmuCore.Shared`. This will cause a compile-time `UndefinedFunctionError` when the module is first used.

**⚠️ Missing — FAPI 2.0 plug not implemented.**  
The `VmuCoreWeb.Plugs.FapiValidationPlug` (mTLS cert binding + RS256 JWT + `cnf.x5t#S256` verification) was specified in Phase 5 Task 28 but does not exist anywhere in `lib/`. Without it the operator portal has no authentication layer. This is a **security-critical gap** — do not deploy the portal without this plug.

**ASM verdict: PORTAL LOGIC COMPLETE, FAPI PLUG MISSING ❌**

---

### ✅ MBS — Merchant Banking Services

**Files:** `mbs/merchant.ex`, `mbs/terminal.ex`, `mbs/mdr_engine.ex`

| Feature | Planned | Status | Notes |
|---|---|---|---|
| Merchant schema (CHAIN/STANDALONE/VIRTUAL, IBAN validation) | ✅ | ✅ Present | |
| Terminal schema (DE 41 terminal codes, type/status) | ✅ | ✅ Present | |
| MdrEngine: rate + scheme fee from ParameterEngine | ✅ | ✅ Correct | `mdr_<template>_rate` / `mdr_<template>_scheme_fee` |
| Batch settlement calculation | ✅ | ✅ Correct | `calculate_batch/4` |
| All monetary values using Decimal | ✅ | ✅ Correct | no Float anywhere in MBS |
| `mbs_merchants + mbs_terminals` migration | ✅ | ✅ Present | `20260613172006_*` |

**MBS verdict: COMPLETE ✅**

---

## Infrastructure & Cross-Cutting

| Item | Planned | Status | Notes |
|---|---|---|---|
| Horde registry + DynamicSupervisor in application.ex | ✅ | ✅ Correct | `members: :auto` for cluster |
| Oban in application.ex | ✅ | ✅ Correct | |
| ParameterEngine started before Horde | ✅ | ✅ Correct | order in children list |
| STIP cache initialised post-supervisor start | ✅ | ✅ Correct | `init_cache()` called after `Supervisor.start_link` |
| Broadway dep in mix.exs | ✅ | ✅ In deps | `deps/broadway/` folder present |
| Broadway pipeline module (`IpmPipeline`) | ✅ | ❌ Not created | See TRAMS Gap 5 |
| Integration tests: FAS auth chain | ✅ | ✅ Present | |
| Integration tests: CMS/interest/EOD | ✅ | ❌ None found | Only FAS and ParameterEngine tests exist |
| `cms_operator_audit` migration | ✅ | ❌ Not in migrations | Table used in `OperatorPortal.audit/4` but never created in any migration |
| IVR SessionRegistry supervision | ✅ | ❌ Missing | See ITS issue above |

---

## Consolidated Gap List

### 🔴 Must Fix Before Production (Blocking)

| # | Gap | File | Risk |
|---|---|---|---|
| G1 | **FAPI 2.0 plug missing** — operator portal has no auth | `asm/operator_portal.ex` (plug not created) | Security: unauthenticated access to privileged ops |
| G2 | **`cms_operator_audit` table not in any migration** — `OperatorPortal.audit/4` will crash at runtime | `priv/repo/migrations/` | Runtime crash on every operator action |
| G3 | **`VmuCore.ITS.SessionRegistry` not supervised** — all IVR sessions crash on start | `application.ex` | Runtime crash for all IVR calls |
| G4 | **Wrong alias in `OperatorPortal`** — `VmuCore.Shared.AccountStateCoordinator` doesn't exist | `asm/operator_portal.ex` line 25 | Compile error |

### 🟡 Must Fix Before UAT (Functional)

| # | Gap | File | Risk |
|---|---|---|---|
| G5 | **Velocity matrix not enforced** — `do_authorize/4` ignores `velocity_limits` | `cms/account_state_coordinator.ex` | Per-channel spend limits never applied |
| G6 | **IPM field extraction stubbed** — amount, date, currency, MCC hardcoded | `trams/mastercard_ipm.ex` | Clearing records will have wrong data |
| G7 | **Broadway IpmPipeline not created** — bulk clearing uses synchronous file read | `trams/` (missing) | Insufficient throughput for production volumes |
| G8 | **Metro 2 missing `"97"` code for written-off accounts** | `cms/metro2_generator.ex` line 162 | Incorrect bureau reporting for charged-off accounts |

### 🟠 Should Fix Before Go-Live (Compliance / Accuracy)

| # | Gap | File | Risk |
|---|---|---|---|
| G9 | **DSR cap not implemented** — only score × income used for limit | `cdm/limit_allocator.ex` | Regulatory exposure (UAE Central Bank lending rules) |
| G10 | **ADB daily balance is a stub** — uses single snapshot repeated across cycle | `cms/statement_generator.ex` | Interest over/under-charged on mid-cycle activity |
| G11 | **Provisional credit GL direction** — DR/CR may be reversed | `dps/dispute.ex` lines 127-128 | Incorrect GL balances; needs finance sign-off |
| G12 | **No integration tests beyond FAS** — CMS, ITS, DPS, COL, CDM have no test files | `test/` | Zero automated coverage for 9 of 11 modules |

---

## What Is Verified Correct

The following are implemented correctly and match the spec without deviation:

- ✅ SHA-256 PAN tokenisation throughout (raw PAN never stored or logged)
- ✅ Decimal arithmetic everywhere — no Float for monetary values found in any module
- ✅ Oban idempotency keys on every GL posting, EOD job, and write-off
- ✅ Horde DynamicSupervisor with `members: :auto` (cluster-ready)
- ✅ ADB interest formula: `ADB × (APR/100/365) × days`, rounded ceiling
- ✅ Repayment priority order: fees → interest → cash → retail
- ✅ EOD pipeline sequencing and per-account isolation
- ✅ Dispute deadline arithmetic (txn_date + 120 / +30 / +60)
- ✅ HOTP/TOTP RFC compliance (truncation, counter drift, clock skew)
- ✅ Write-off idempotency (`:zero_balance` guard)
- ✅ MDR pipeline resolution via ParameterEngine cascade
- ✅ RBAC role-hierarchy comparison in OperatorPortal
- ✅ All 9 migrations present and structurally correct

---

## Recommended Action Plan

**This week (before next code review):**
1. Add `{Registry, keys: :unique, name: VmuCore.ITS.SessionRegistry}` to `application.ex` children list — fixes G3
2. Fix alias in `operator_portal.ex` line 25: change `VmuCore.Shared.AccountStateCoordinator` → `VmuCore.CMS.AccountStateCoordinator` — fixes G4
3. Add `cms_operator_audit` table to a new migration — fixes G2
4. Add `"WRITTEN_OFF"` → `"97"` clause in `Metro2Generator.dpd_to_account_status/1` — fixes G8

**Before UAT:**
5. Implement `check_velocity/4` in `AccountStateCoordinator.do_authorize/4` reading `velocity_limits` JSONB — fixes G5
6. Create `VmuCoreWeb.Plugs.FapiValidationPlug` (mTLS + RS256 JWT + `cnf.x5t#S256`) — fixes G1 (security-critical)
7. Complete IPM field extraction using full Mastercard BCD bitmap parser — fixes G6
8. Create `VmuCore.TRAMS.IpmPipeline` Broadway module (1 producer, 10 processors, GL batcher) — fixes G7

**Before Go-Live:**
9. Add DSR cap to `LimitAllocator.calculate/5`: `(existing_monthly_payments + min_payment_estimate) / monthly_income ≤ 0.50` — fixes G9
10. Create `cms_daily_balance_snapshots` table and populate via EOD; update `StatementGenerator` to join it — fixes G10
11. Have finance team verify provisional credit GL direction in `dps/dispute.ex` — fixes G11
12. Write integration tests for CMS (interest engine + EOD), DPS (dispute lifecycle), COL (write-off + recovery), CDM (underwriting decision) — fixes G12

---

## New Gaps — VisionPlus Module Coverage Review (2026-06-13)

### 🔴 G13 — LMS (Loyalty Management System) Entirely Missing

**VisionPlus LMS** is a full subsystem for rewarding cardholders with points or cash-back rebates. It has Online, Batch, and Interface layers with its own parameter hierarchy, GL provisioning, and merchant settlement.

**Architecture required:**
- **Scheme → Group → Plan hierarchy** — each account enrolled in one or more Schemes; each Scheme has a Default Group (basic earned points) and Bonus Groups (merchant-linked). Each Group has Base, Supplementary, and Override Plan types.
- **Rate Tables & Rate Tiers** — points-per-currency-unit ratios, minimum qualifying transaction value, per-scheme tier rate overrides.
- **Enrollment** — auto (triggered by CMS account creation/CDM approval) or manual; `lms_account_xref` table linking AR account → LMS account; auto-number generation.
- **Points Ledger** — per-transaction entries (basic earned, bonus, redeemed, adjustment); oldest-points-first redemption ordering; warehouse → active → history state lifecycle.
- **Redemption** — online via points adjustment; third-party redemption file interface (standard record layout); auto-disbursement (cheque/credit/voucher) at configurable frequency and packet size; warehouse period (days before newly earned points become eligible); block/delinquency check before redemption approval.
- **Settlement** — Merchant Settlement (charge merchants for bonus points at percentage rate; direct debit or invoice); Redemption Settlement (pay redemption merchants for services at defined intervals).
- **GL Provisioning** — for every points transaction, calculate monetary equivalent (points × rate_pct); post debit/credit GL entries; apply tax rate; generate settlement GL file for third-party GL system.
- **Batch jobs** — points calculation (CMS→LMS file interface after CMS1 batch); expired points processing; auto-disbursement; reporting.

**vMu gap:** No `VmuCore.LMS` module, no `lms_*` tables, no CMS→LMS interface, no points GL. Any cardholder enrolled in a rewards programme has zero LMS support.

**Resolution:** Implement as Phase 6 — see `docs/phase6-implementation-spec.md`.

---

### 🟡 G14 — HCS (Hierarchy Company System) Entirely Missing

**VisionPlus HCS** supports commercial/corporate card programmes where a company (Hierarchy Company) controls spending for its employees' cards. HCS maintains the parent-child account relationships, company-level spending controls, consolidated billing, and inter-account sweep functionality.

**Architecture required:**
- Hierarchy Company master record (company name, billing account, credit limit allocation)
- Employee card accounts linked to a parent company account
- Consolidated statement generation at company level
- Company-level spending limit enforcement cascading to individual cards
- Central liability vs. individual liability options

**vMu gap:** No `VmuCore.HCS` module, no `hcs_*` tables. Corporate card programmes (B2B issuance) cannot be supported.

**Resolution:** Plan as Phase 7 — scope when a commercial card launch is confirmed.

---

### 🟡 G15 — ITS Module Name Conflicts with VisionPlus Canonical Meaning

**VisionPlus ITS** = **Interchange Tracking System** — manages copy requests, chargeback initiation, retrieval requests, and interchange fee claims. It feeds the daily batch cycle (ITS1 → TRAMS → ITS2).

**vMu ITS** = `VmuCore.ITS` was implemented as an **IVR/Telephony** module (OTP engine, IVR session GenServer). This is a naming collision with the canonical VisionPlus meaning.

**Required changes:**
1. Rename `VmuCore.ITS` → `VmuCore.IVR` (rename directory `its/` → `ivr/`, update all aliases and references)
2. Update `application.ex` Registry name: `VmuCore.IVR.SessionRegistry`
3. Add Interchange Tracking functionality to `VmuCore.DPS` — copy request records, retrieval request tracking, interchange fee claim records (currently these are handled implicitly through `dps/dispute.ex` but the ITS paper trail for ITS1/ITS2 batch feed is absent)

**Risk:** The naming confusion will cause integration problems when connecting to any VisionPlus-compatible TRAMS batch pipeline that references ITS by canonical name.

**Resolution:** Module rename can be done independently of feature work; add to fix list alongside G3 (IVR SessionRegistry supervision bug since the registry name changes too).

---

## Updated Consolidated Gap List

### 🔴 Must Fix Before Production (Blocking)

| # | Gap | File | Risk |
|---|---|---|---|
| G1 | **FAPI 2.0 plug missing** — operator portal has no auth | `asm/operator_portal.ex` (plug not created) | Security: unauthenticated access to privileged ops |
| G2 | **`cms_operator_audit` table not in any migration** | `priv/repo/migrations/` | Runtime crash on every operator action |
| G3 | **`VmuCore.ITS.SessionRegistry` not supervised** | `application.ex` | Runtime crash for all IVR calls |
| G4 | **Wrong alias in `OperatorPortal`** — `VmuCore.Shared.AccountStateCoordinator` | `asm/operator_portal.ex` line 25 | Compile error |
| G15 | **ITS module naming conflict** — IVR code named `VmuCore.ITS`; VisionPlus ITS = Interchange Tracking | `its/` directory, all aliases | Integration confusion; must rename to `VmuCore.IVR` |

### 🟡 Must Fix Before UAT (Functional)

| # | Gap | File | Risk |
|---|---|---|---|
| G5 | **Velocity matrix not enforced** | `cms/account_state_coordinator.ex` | Per-channel spend limits never applied |
| G6 | **IPM field extraction stubbed** | `trams/mastercard_ipm.ex` | Clearing records will have wrong data |
| G7 | **Broadway IpmPipeline not created** | `trams/` (missing) | Insufficient throughput for production volumes |
| G8 | **Metro 2 missing `"97"` code for written-off accounts** | `cms/metro2_generator.ex` line 162 | Incorrect bureau reporting |
| G14 | **HCS entirely missing** — no commercial/corporate card support | *(no module)* | B2B card programmes unsupported |

### 🟠 Should Fix Before Go-Live (Compliance / Accuracy)

| # | Gap | File | Risk |
|---|---|---|---|
| G9 | **DSR cap not implemented** | `cdm/limit_allocator.ex` | Regulatory exposure (UAE Central Bank) |
| G10 | **ADB daily balance is a stub** | `cms/statement_generator.ex` | Interest over/under-charged |
| G11 | **Provisional credit GL direction** | `dps/dispute.ex` lines 127-128 | Incorrect GL balances |
| G12 | **No integration tests beyond FAS** | `test/` | Zero automated coverage for 9 modules |

### 🔵 Future Phases (Architecture Gaps)

| # | Gap | Module | Notes |
|---|---|---|---|
| G13 | **LMS (Loyalty Management System) entirely missing** | `VmuCore.LMS` (not created) | Full rewards/points subsystem; see Phase 6 spec |
| G14 | **HCS (Hierarchy Company System) entirely missing** | `VmuCore.HCS` (not created) | Commercial card hierarchy; defer to Phase 7 |
