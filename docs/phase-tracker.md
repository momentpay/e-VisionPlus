# vMu VisionPlus - Phase Implementation Tracker

Repository: https://github.com/momentpay/e-VisionPlus
Project: `vmu_core` - Elixir/Phoenix reimplementation of Visa VisionPlus credit card management

---

## Phase 1 - Foundation + FAS Authorization
**Commit:** `33fc964`  **Status:** COMPLETE

| Task | Module | Status |
|------|--------|--------|
| Horde + libcluster + Oban setup | `mix.exs`, `application.ex` | Done |
| CIF Customer schema | `shared/customer.ex` | Done |
| CMS Account + BalanceBucket schemas | `cms/account.ex`, `cms/balance_bucket.ex` | Done |
| ParameterEngine ETS cache (SYS->BANK->LOGO->BLOCK) | `shared/parameter_engine.ex` | Done |
| AccountStateCoordinator GenServer | `cms/account_state_coordinator.ex` | Done |
| FAS Authorization chain | `fas/authorization.ex` | Done |
| STIP fallback (ETS-backed) | `fas/stip.ex` | Done |
| Migrations: parameter + customer + accounts | `20260612205855_*`, `_171913_*`, `_171914_*` | Done |
| Integration tests (auth happy path + declines + STIP) | `test/vmu_core/fas/` | Done |

---

## Phase 2 - CMS Credit Core + CTA Card Issuance
**Commit:** `b35225a`  **Status:** COMPLETE

| Task | Module | Status |
|------|--------|--------|
| Double-entry GL ledger + idempotent GL poster | `cms/ledger_entry.ex`, `cms/internal_gl_poster.ex` | Done |
| Interest engine (ADB x daily_rate x days, Decimal only) | `cms/interest_engine.ex` | Done |
| Repayment distributor (fee->interest->cash->retail) | `cms/repayment_distributor.ex` | Done |
| EOD 5-job Oban pipeline (Lock->Accrue->Age->Statement->Flush) | `cms/eod/*.ex` | Done |
| DPD ageing: 0->30->60->90->120 | `cms/eod/age_buckets_job.ex` | Done |
| CTA: Card stock, embossing, PIN issuance, activation | `cta/*.ex` | Done |
| Migrations: Oban + GL + CTA | `_172001_*` through `_172003_*` | Done |

---

## Phase 3 - IVR Telephony + DPS Dispute Processing
**Commit:** `58c8042`  **Status:** COMPLETE

| Task | Module | Status |
|------|--------|--------|
| IVR session GenServer (5-min idle, 3 PIN tries) | `ivr/ivr_session.ex` | Done |
| HOTP (RFC 4226) + TOTP (RFC 6238) OTP engine | `ivr/otp_engine.ex` | Done |
| Dispute state machine (FILED->CHARGEBACK->PRE_ARB->CLOSED) | `dps/dispute.ex` | Done |
| Dispute deadline scheduler (Visa 120-day / MC 30-day) | `dps/deadline_job.ex` | Done |
| Migration: dps_disputes | `_172004_*` | Done |

---

## Phase 4 - TRAMS Clearing + COL Collections
**Commit:** `c928d63`  **Status:** COMPLETE

| Task | Module | Status |
|------|--------|--------|
| Mastercard IPM binary parser (1644-byte, MTI 1240) | `trams/mastercard_ipm.ex` | Done |
| Visa Base II EBCDIC parser (80-byte, IBM CP500) | `trams/visa_base_ii.ex` | Done |
| Collection queue routing, dunning, write-off, recovery | `col/*.ex` | Done |
| Migrations: TRAMS + COL | `_172005_*` | Done |

---

## Phase 5 - CDM Underwriting + ASM Portal + MBS Merchant
**Commit:** `63c5cfd`  **Status:** COMPLETE

| Task | Module | Status |
|------|--------|--------|
| BureauAdapter + MockBureauAdapter | `cdm/bureau_adapter.ex` | Done |
| ApplicationScorer (PRIME/NEAR_PRIME/SUBPRIME/DECLINE) | `cdm/application_scorer.ex` | Done |
| LimitAllocator (income x tier, ParameterEngine bounds) | `cdm/limit_allocator.ex` | Done |
| BehavioralRescorer (Oban monthly upgrade/downgrade/suspend) | `cdm/behavioral_rescorer.ex` | Done |
| OperatorPortal (role-gated, audit log) | `asm/operator_portal.ex` | Done |
| Merchant + Terminal schemas | `mbs/merchant.ex`, `mbs/terminal.ex` | Done |
| MdrEngine (rate + scheme fee from ParameterEngine) | `mbs/mdr_engine.ex` | Done |
| Metro2Generator (CDIA Metro 2, 426-char fixed-width) | `cms/metro2_generator.ex` | Done |
| ASC: refresh_limit, credit_open_to_buy, notify_status_change | `cms/account_state_coordinator.ex` | Done |
| Migration: CDM + MBS tables | `_172006_*` | Done |

---

## Phase 6 - LMS Loyalty Management System + Gap Fixes
**Commit:** `859b34a`  **Status:** COMPLETE

### Gap Fixes (from implementation-verification-report.md)

| Gap | Fix | Status |
|-----|-----|--------|
| G2 - cms_operator_audit table missing | Migration `20260614000000_create_operator_audit.exs` | Done |
| G3 - IVR.SessionRegistry not supervised | Added Registry child to `application.ex` | Done |
| G4 - Wrong alias in OperatorPortal | Fixed VmuCore.Shared -> VmuCore.CMS.AccountStateCoordinator | Done |
| G8 - Metro 2 missing WRITTEN_OFF -> "97" | Added metro2_account_status/2 | Done |
| G15 - ITS naming conflict | Renamed VmuCore.ITS -> VmuCore.IVR; deleted its/ directory | Done |

### LMS - Loyalty Management System

| Task | Module | Status |
|------|--------|--------|
| Scheme, Group, Plan, RateTier schemas | `lms/scheme.ex`, `group.ex`, `plan.ex`, `rate_tier.ex` | Done |
| LMS Account, PointsLedger, Redemption, MerchantSettlement schemas | `lms/*.ex` | Done |
| RateEngine (OVERRIDE > BASE+SUPPLEMENTARY; tier lookup) | `lms/rate_engine.ex` | Done |
| PointsEngine (BASIC_EARNED + BONUS_EARNED; idempotent posting; GL) | `lms/points_engine.ex` | Done |
| GlProvisioner (7001/7002 earn GL; 7003/7004 merchant settlement GL) | `lms/gl_provisioner.ex` | Done |
| Enrollment (auto on CDM approval; on_conflict idempotency) | `lms/enrollment.ex` | Done |
| RedemptionProcessor (oldest-first FIFO; BLOCKED guard; HISTORY state) | `lms/redemption_processor.ex` | Done |
| MerchantSettlementService (bonus group settlement; GL; settled_at) | `lms/merchant_settlement_service.ex` | Done |
| CmsInterface (trigger_points_calculation; auto_enroll) | `lms/cms_interface.ex` | Done |
| PointsCalculationJob (Oban daily after FlushGL) | `lms/oban/points_calculation_job.ex` | Done |
| PointsExpiryJob (monthly; ACTIVE->HISTORY; negative EXPIRED entry) | `lms/oban/points_expiry_job.ex` | Done |
| AutoDisbursementJob (per-scheme; open_to_redeem >= packet threshold) | `lms/oban/auto_disbursement_job.ex` | Done |
| FlushGLJob -> CmsInterface integration hook | `cms/eod/flush_gl_job.ex` | Done |
| Oban lms: 5 + cdm: 3 queues | `config/config.exs` | Done |
| Migration: 8 LMS tables (UUID FK refs to cms_accounts/mbs_merchants) | `20260614000001_create_lms_tables.exs` | Done |

---

## VisionPlus Compatibility Summary

| VisionPlus Subsystem | vMu Module | Coverage |
|---------------------|-----------|----------|
| FAS (Financial Authorization System) | `VmuCore.FAS` | Full ISO 8583 auth chain + STIP |
| CMS (Card Management System) | `VmuCore.CMS` | Accounts, GL, EOD, statements, interest, payments |
| CIF (Customer Information File) | `VmuCore.Shared.Customer` | KYC fields, tier, id_number |
| CTA (Card and Account Administration) | `VmuCore.CTA` | Stock, embossing, PIN, activation |
| IVR (Interactive Voice Response) | `VmuCore.IVR` | OTP (RFC 4226/6238), session state machine |
| DPS (Dispute Processing System) | `VmuCore.DPS` | Full dispute lifecycle + deadline Oban |
| TRAMS (Transaction Management System) | `VmuCore.TRAMS` | Mastercard IPM + Visa Base II |
| COL (Collections) | `VmuCore.COL` | Queue routing, dunning, write-off, recovery |
| CDM (Credit Decision Management) | `VmuCore.CDM` | Underwriting, bureau, behavioral rescoring |
| ASM (Account/System Management) | `VmuCore.ASM` | Operator portal, RBAC, audit log |
| MBS (Merchant Banking Services) | `VmuCore.MBS` | Merchant hierarchy, terminals, MDR engine |
| LMS (Loyalty Management System) | `VmuCore.LMS` | Schemes, plans, rates, points, redemption, settlement |
| Metro 2 Bureau Reporting | `VmuCore.CMS.Metro2Generator` | CDIA fixed-width monthly file |
| Parameter Engine (SYS->BANK->LOGO->BLOCK) | `VmuCore.Shared.ParameterEngine` | ETS 4-level cascade |

## Remaining Known Gaps (Post-Phase 6)

| # | Gap | Priority |
|---|-----|----------|
| G1 | FAPI 2.0 plug (mTLS + RS256 JWT) for OperatorPortal | Security-critical (before deploy) |
| G5 | Velocity matrix enforcement in ASC.do_authorize/4 | Before UAT |
| G6 | IPM field extraction (BCD bitmap parser) | Before UAT |
| G7 | Broadway IpmPipeline (bulk clearing throughput) | Before UAT |
| G9 | DSR cap in LimitAllocator (UAE Central Bank requirement) | Before go-live |
| G10 | ADB daily balance snapshots (cms_daily_balance_snapshots table) | Before go-live |
| G11 | Provisional credit GL direction review (dps/dispute.ex) | Finance sign-off |
| G12 | Integration tests for CMS, DPS, COL, CDM, LMS | Before go-live |
| G14 | HCS - commercial card hierarchy | Phase 7 (future) |
