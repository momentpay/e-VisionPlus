# vMu VisionPlus — Phase Implementation Tracker

Repository: https://github.com/momentpay/e-VisionPlus
Project: `vmu_core` — Elixir/Phoenix reimplementation of Visa VisionPlus credit card management

---

## Phase 1 — Foundation + FAS Authorization  
**Commit:** `33fc964`  
**Status:** COMPLETE

| Task | Module | Status |
|------|--------|--------|
| Horde + libcluster + Oban setup | `mix.exs`, `application.ex` | ✅ |
| CIF Customer schema | `shared/customer.ex` | ✅ |
| CMS Account + BalanceBucket schemas | `cms/account.ex`, `cms/balance_bucket.ex` | ✅ |
| STIP threshold schema | `cms/account.ex` (stip_thresholds table) | ✅ |
| ParameterEngine ETS cache (SYS→BANK→LOGO→BLOCK) | `shared/parameter_engine.ex` | ✅ |
| Horde Registry wrapper | `shared/registry.ex` | ✅ |
| AccountStateCoordinator GenServer | `cms/account_state_coordinator.ex` | ✅ |
| FAS Authorization chain | `fas/authorization.ex` | ✅ |
| STIP fallback (ETS-backed) | `fas/stip.ex` | ✅ |
| Migration: parameter tables | `20260612205855_*` | ✅ |
| Migration: cms_customers | `20260613171913_*` | ✅ |
| Migration: cms_accounts + balance_buckets + stip_thresholds | `20260613171914_*` | ✅ |
| Integration tests (auth happy path + all decline codes + STIP) | `test/vmu_core/fas/authorization_integration_test.exs` | ✅ |

---

## Phase 2 — CMS Credit Core + CTA Card Issuance  
**Commit:** `b35225a`  
**Status:** COMPLETE

| Task | Module | Status |
|------|--------|--------|
| Oban job tables migration | `20260613172001_*` | ✅ |
| Double-entry GL ledger schema | `cms/ledger_entry.ex` | ✅ |
| Idempotent GL poster (on_conflict: :nothing) | `cms/internal_gl_poster.ex` | ✅ |
| Interest engine (ADB × daily_rate × days, Decimal only) | `cms/interest_engine.ex` | ✅ |
| Repayment distributor (fee→interest→cash→retail) | `cms/repayment_distributor.ex` | ✅ |
| EOD: LockAccountsJob | `cms/eod/lock_accounts_job.ex` | ✅ |
| EOD: AccrueInterestJob | `cms/eod/accrue_interest_job.ex` | ✅ |
| EOD: AgeBucketsJob (DPD 0→30→60→90→120) | `cms/eod/age_buckets_job.ex` | ✅ |
| EOD: GenerateStatementJob | `cms/eod/generate_statement_job.ex` | ✅ |
| EOD: FlushGLJob | `cms/eod/flush_gl_job.ex` | ✅ |
| CTA: Card stock inventory (SELECT FOR UPDATE) | `cta/stock_inventory.ex` | ✅ |
| CTA: Bureau adapter behaviour + SFTP default | `cta/bureau_adapter.ex` | ✅ |
| CTA: Embossing file generator (G+D/Thales 128-char fixed-width) | `cta/embossing_file_generator.ex` | ✅ |
| CTA: PIN issuance (delegates to DaProductApp.SoftHSM) | `cta/pin_issuance.ex` | ✅ |
| CTA: Card activation (IVR + first-use) | `cta/card_activation.ex` | ✅ |
| Migration: cms_ledger_entries + velocity extension | `20260613172002_*` | ✅ |
| Migration: cta_card_stock + cta_embossing_orders | `20260613172003_*` | ✅ |

---

## Phase 3 — ITS Telephony + DPS Dispute Processing  
**Commit:** `58c8042`  
**Status:** COMPLETE

| Task | Module | Status |
|------|--------|--------|
| OTP engine (RFC 4226 HOTP + RFC 6238 TOTP, ±1 drift) | `its/otp_engine.ex` | ✅ |
| IVR session GenServer (state machine, 5-min timeout, 3 PIN tries) | `its/ivr_session.ex` | ✅ |
| Dispute schema + state machine (FILED→CHARGEBACK→PRE_ARB→CLOSED) | `dps/dispute.ex` | ✅ |
| Dispute deadline scheduler (Visa 120-day / MC 30-day) | `dps/deadline_job.ex` | ✅ |
| Migration: dps_disputes | `20260613172004_*` | ✅ |

---

## Phase 4 — TRAMS Clearing + COL Collections  
**Commit:** `c928d63`  
**Status:** COMPLETE

| Task | Module | Status |
|------|--------|--------|
| Mastercard IPM binary parser (1644-byte records, MTI 1240) | `trams/mastercard_ipm.ex` | ✅ |
| ClearingRecord schema (separate file to fix compile order) | `trams/clearing_record.ex` | ✅ |
| Visa Base II EBCDIC parser (80-byte, IBM CP500) | `trams/visa_base_ii.ex` | ✅ |
| Collection case schema (DPD, promise, workout, write-off) | `col/collection_case.ex` | ✅ |
| Collection queue Oban job (DPD-based routing) | `col/collection_queue_job.ex` | ✅ |
| Dunning job (SMS/email→letter→courier→registered mail) | `col/dunning_job.ex` | ✅ |
| Write-off processor (GL Dr:5001 Cr:1001, recovery posting) | `col/write_off_processor.ex` | ✅ |
| Migration: trams_clearing_records + col_collection_cases | `20260613172005_*` | ✅ |

---

## Phase 5 — CDM Underwriting + ASM Portal + MBS Merchant  
**Commit:** `63c5cfd`  
**Status:** COMPLETE

| Task | Module | Status |
|------|--------|--------|
| BureauAdapter behaviour + MockBureauAdapter | `cdm/bureau_adapter.ex` | ✅ |
| ApplicationScorer (PRIME/NEAR_PRIME/SUBPRIME/DECLINE engine) | `cdm/application_scorer.ex` | ✅ |
| LimitAllocator (income × tier multiplier, ParameterEngine bounds) | `cdm/limit_allocator.ex` | ✅ |
| BehavioralRescorer (Oban monthly: upgrade/downgrade/suspend) | `cdm/behavioral_rescorer.ex` | ✅ |
| OperatorPortal (role-gated: agent/supervisor/manager/sysadmin) | `asm/operator_portal.ex` | ✅ |
| Merchant schema (CHAIN/STANDALONE/VIRTUAL, IBAN validation) | `mbs/merchant.ex` | ✅ |
| Terminal schema (DE 41 terminal codes, type/status) | `mbs/terminal.ex` | ✅ |
| MdrEngine (rate + scheme fee from ParameterEngine, net settlement) | `mbs/mdr_engine.ex` | ✅ |
| Metro2Generator (CDIA Metro 2, 426-char fixed-width, monthly) | `cms/metro2_generator.ex` | ✅ |
| ASC: refresh_limit/2, credit_open_to_buy/2, notify_status_change/2 | `cms/account_state_coordinator.ex` | ✅ |
| Migration: cdm_credit_applications + mbs_merchants + mbs_terminals | `20260613172006_*` | ✅ |

---

## VisionPlus Compatibility Summary

| VisionPlus Subsystem | vMu Module | Coverage |
|---------------------|-----------|----------|
| FAS (Financial Authorization System) | `VmuCore.FAS` | ✅ Full ISO 8583 auth chain + STIP |
| CMS (Card Management System) | `VmuCore.CMS` | ✅ Accounts, GL, EOD, statements, interest, payments |
| CIF (Customer Information File) | `VmuCore.Shared.Customer` | ✅ KYC fields, tier, id_number |
| CTA (Card and Account Administration) | `VmuCore.CTA` | ✅ Stock, embossing, PIN, activation |
| ITS (Interactive Telephone System) | `VmuCore.ITS` | ✅ OTP, IVR state machine |
| DPS (Dispute Processing System) | `VmuCore.DPS` | ✅ Full dispute lifecycle + deadline Oban |
| TRAMS (Transaction Management System) | `VmuCore.TRAMS` | ✅ Mastercard IPM + Visa Base II |
| COL (Collections) | `VmuCore.COL` | ✅ Queue routing, dunning, write-off, recovery |
| CDM (Credit Decision Management) | `VmuCore.CDM` | ✅ Underwriting, bureau, behavioral rescoring |
| ASM (Account/System Management) | `VmuCore.ASM` | ✅ Operator portal, RBAC, audit log |
| MBS (Merchant Banking Services) | `VmuCore.MBS` | ✅ Merchant hierarchy, terminals, MDR engine |
| Metro 2 Bureau Reporting | `VmuCore.CMS.Metro2Generator` | ✅ CDIA fixed-width monthly file |
| Parameter Engine (SYS→BANK→LOGO→BLOCK) | `VmuCore.Shared.ParameterEngine` | ✅ ETS 4-level cascade |

