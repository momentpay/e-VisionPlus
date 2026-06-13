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

## Remaining Known Gaps — Post-Phase 6 (all resolved in Phase 7/8 commit)

| # | Gap | Resolution |
|---|-----|------------|
| G1 | FAPI 2.0 plug (mTLS + RS256 JWT + cnf.x5t#S256) | `lib/vmu_core_web/plugs/fapi_validation_plug.ex` |
| G5 | Velocity matrix enforcement in ASC.do_authorize/4 | `check_velocity/3` + `query_today_velocity/2` in ASC |
| G6 | IPM BCD bitmap parser + full DE extraction | Full 128-bit bitmap + DE decoder in `trams/mastercard_ipm.ex` |
| G7 | Broadway IpmPipeline (1 producer, 10 processors, GL batcher) | `trams/ipm_pipeline.ex` + Broadway dep in mix.exs |
| G9 | DSR cap in LimitAllocator (UAE Central Bank 50% cap) | `calculate/6` DSR check; updated `application_scorer.ex` |
| G10 | ADB daily balance snapshots | Migration `20260615000000_*`; `StatementGenerator.snapshot_daily_balance/2`; true ADB in `daily_balances_for/4` |
| G11 | Provisional credit GL direction | Confirmed correct (DR 3001 / CR 1001); finance sign-off comment added to `dps/dispute.ex` |
| G12 | Integration tests for CMS, DPS, COL, CDM, LMS | `test/vmu_core/{cms,dps,col,cdm,lms}/*_test.exs` |

---

## Phase 7 — HCS Hierarchy Company System
**Commit:** `5366da2`  **Status:** COMPLETE

| Task | Module | Status |
|------|--------|--------|
| Company master record (credit pool, liability model, KYC) | `hcs/company.ex` | Done |
| Employee card schema (sub-limits, card type, cash flag, cost centre) | `hcs/employee_card.ex` | Done |
| Spending controls (MCC block/allow, channel block, per-txn/daily cap) | `hcs/spending_control.ex` | Done |
| Consolidated statement schema | `hcs/consolidated_statement.ex` | Done |
| Payment sweep + sweep line schemas | `hcs/payment_sweep.ex` | Done |
| Company onboarding + employee card provisioning with pool validation | `hcs/company_onboarding.ex` | Done |
| Dual-layer limit controller (individual sub-limit + company pool) | `hcs/limit_controller.ex` | Done |
| Wire LimitController into AccountStateCoordinator.do_authorize/4 | `cms/account_state_coordinator.ex` | Done |
| Wire credit_limits/2 into RepaymentDistributor on payment | `cms/repayment_distributor.ex` | Done |
| Consolidated statement generator | `hcs/consolidated_statement_generator.ex` | Done |
| Payment sweep Oban job — Central Liability (nightly 22:00) | `hcs/oban/payment_sweep_job.ex` | Done |
| Consolidated statement Oban job (runs on billing_cycle_day) | `hcs/oban/consolidated_statement_job.ex` | Done |
| Migration: 6 HCS tables | `20260615000001_create_hcs_tables.exs` | Done |
| Broadway PipelineSupervisor added to application.ex | `lib/vmu_core/application.ex` | Done |
| hcs: 3 + its: 4 Oban queues | `config/config.exs` | Done |

---

## Phase 8 — ITS Interchange Tracking System
**Commit:** `5366da2`  **Status:** COMPLETE

**Note:** IVR rename (G15) was completed in Phase 6. `VmuCore.ITS` namespace is now the canonical Interchange Tracking System.

| Task | Module | Status |
|------|--------|--------|
| Copy request schema (PENDING→SENT→FULFILLED/DECLINED/EXPIRED) | `its/copy_request.ex` | Done |
| Fee claim schema (interchange income/expense + scheme fee per clearing) | `its/fee_claim.ex` | Done |
| Financial adjustment schema (FARs from Mastercard/Visa) | `its/financial_adjustment.ex` | Done |
| CopyRequestManager (raise/fulfill/expire; DPS state advance) | `its/copy_request_manager.ex` | Done |
| FeeClaimProcessor (create per clearing; ParameterEngine rates; GL) | `its/fee_claim_processor.ex` | Done |
| FinancialAdjustmentProcessor (ingest FAR; auto-accept < AED 1000) | `its/financial_adjustment_processor.ex` | Done |
| ITS1 batch extractor (extract PENDING requests + CHARGEBACK_FILED) | `its/batch/its1_extractor.ex` | Done |
| ITS2 batch receiver (process scheme responses + FARs; advance DPS) | `its/batch/its2_receiver.ex` | Done |
| Its1BatchJob (Oban, 21:00) | `its/oban/its1_batch_job.ex` | Done |
| Its2BatchJob (Oban, 02:00) | `its/oban/its2_batch_job.ex` | Done |
| FeeSettlementJob (Oban, 1st of month) | `its/oban/fee_settlement_job.ex` | Done |
| CopyRequestExpiryJob (Oban, daily 06:30) | `its/oban/copy_request_expiry_job.ex` | Done |
| SchemeSubmissionJob (TRAMS stub for scheme network delivery) | `trams/oban/scheme_submission_job.ex` | Done |
| Wire FeeClaimProcessor into TRAMS after clearing record insert | `trams/mastercard_ipm.ex`, `trams/visa_base_ii.ex` | Done |
| Alter dps_disputes: submitted_at, arn, card_number_token columns | `20260616000001_create_its_tables.exs` | Done |
| Migration: its_copy_requests, its_fee_claims, its_financial_adjustments | `20260616000001_create_its_tables.exs` | Done |

---

## Updated VisionPlus Compatibility Summary (Post-Phase 8)

| VisionPlus Subsystem | vMu Module | Coverage |
|---------------------|-----------|----------|
| FAS (Financial Authorization System) | `VmuCore.FAS` | ✅ Full ISO 8583 auth chain + STIP + velocity checks (G5) |
| CMS (Card Management System) | `VmuCore.CMS` | ✅ Accounts, GL, EOD, statements, interest, payments + daily snapshots (G10) |
| CIF (Customer Information File) | `VmuCore.Shared.Customer` | ✅ KYC fields, tier, id_number |
| CTA (Card and Account Administration) | `VmuCore.CTA` | ✅ Stock, embossing, PIN, activation |
| IVR (Interactive Voice Response / Telephony) | `VmuCore.IVR` | ✅ OTP RFC 4226/6238, IVR session state machine |
| ITS (Interchange Tracking System) | `VmuCore.ITS` | ✅ Copy requests, fee claims, FARs, ITS1/ITS2 batch |
| DPS (Dispute Processing System) | `VmuCore.DPS` | ✅ Full dispute lifecycle + deadline Oban + GL direction confirmed (G11) |
| TRAMS (Transaction Management System) | `VmuCore.TRAMS` | ✅ Full BCD bitmap parser (G6), Broadway pipeline (G7), fee claim wiring |
| COL (Collections) | `VmuCore.COL` | ✅ Queue routing, dunning, write-off, recovery |
| CDM (Credit Decision Management) | `VmuCore.CDM` | ✅ Underwriting, bureau, behavioral rescoring + DSR cap (G9) |
| ASM (Account/System Management) | `VmuCore.ASM` | ✅ RBAC + FAPI 2.0 plug (G1) |
| MBS (Merchant Banking Services) | `VmuCore.MBS` | ✅ Merchant hierarchy, terminals, MDR engine |
| LMS (Loyalty Management System) | `VmuCore.LMS` | ✅ Schemes, plans, rates, points, redemption, settlement |
| HCS (Hierarchy Company System) | `VmuCore.HCS` | ✅ Corporate card hierarchy, dual-layer limits, sweep, consolidated statements |
| Metro 2 Bureau Reporting | `VmuCore.CMS.Metro2Generator` | ✅ CDIA fixed-width monthly file + WRITTEN_OFF "97" |
| Parameter Engine (SYS→BANK→LOGO→BLOCK) | `VmuCore.Shared.ParameterEngine` | ✅ ETS 4-level cascade |
| FAPI 2.0 Security | `VmuCoreWeb.Plugs.FapiValidationPlug` | ✅ mTLS + RS256 JWT + cnf.x5t#S256 binding |

## Integration Tests (G12)

| Area | Test File | Status |
|------|-----------|--------|
| CMS interest + EOD + GL idempotency | `test/vmu_core/cms/interest_integration_test.exs` | Done |
| DPS dispute lifecycle (file→transition→close) | `test/vmu_core/dps/dispute_lifecycle_test.exs` | Done |
| COL write-off + recovery interface | `test/vmu_core/col/write_off_recovery_test.exs` | Done |
| CDM underwriting + DSR cap | `test/vmu_core/cdm/underwriting_test.exs` | Done |
| LMS enrollment + earning + redemption | `test/vmu_core/lms/points_lifecycle_test.exs` | Done |
