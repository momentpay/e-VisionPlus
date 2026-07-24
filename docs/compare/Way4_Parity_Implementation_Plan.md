# Way4/VisionPLUS/Prime/PowerCARD Parity — Implementation Plan (vmu_core only)

> Companion to [`Way4_VisionPlus_Prime_PowerCARD_momentPay_Comparison.md`](Way4_VisionPlus_Prime_PowerCARD_momentPay_Comparison.md).
> Scope: **standalone `vmu_core`** (`d:\momentPay\Products\E-VisionPlus\vmu_core`)
> only — no dependency on, or code from, the sibling `Avenza` / `wallet-app`
> project. This follows the 2026-07-23 platform-of-record correction: after
> three rounds of the same "wallet-app merge silently duplicated/broke
> something vmu_core already had correctly" pattern (LOGO/BLOCK, ASC/Horde,
> ledger-of-record), the decision was reversed from "reconcile inside the
> merged Avenza umbrella" to **standalone `vmu_core` is the base; other
> repos' functionality gets ported in, not reconciled against in place.**
> This document is the first artifact built entirely against that decision.

## 0. Why this document exists, and a ground-truth correction first

The source comparison doc's **% Match** column was written as a general
"momentPay" estimate — in several rows it is clearly scoring capability that
was actually built in the sibling `Avenza`/`wallet-app` project (Digital
Wallet, QR Payments, Instant Payments, A2A, multi-currency sub-wallets,
Virtual Cards' credential-reveal flow, Corporate/Fleet card UI). **None of
that code exists in standalone `vmu_core`.** A repo audit performed for this
plan (reading `vmu_core`'s own phase-tracker and all per-module gap trackers,
plus a real directory listing of `lib/vmu_core/`) found:

- `lib/vmu_core/` has exactly these modules, all real, compiled code:
  `asm, cdm, cms, col, cta, dps, fas, hcs, its, ivr, lms, mbs, shared, trams`.
- **No** `debit/`, `fleet/`, `bnpl/`, `prepaid/`, `wallet/`, `wps/`, `kyc/`,
  or `party/` directory exists. The requirement docs under
  `docs/{debit,fleet,bnpl,prepaid,wallet,wps,kyc}/` are planning documents
  only — zero corresponding implementation in this repo.
- `mix.exs` has a real `{:horde, "~> 0.9"}` dependency and `application.ex`
  really starts `Horde.Registry`/`Horde.DynamicSupervisor` — so, unlike the
  Avenza copy (which was found to have `:horde` silently missing, causing
  every Credit authorization to decline RC 96), **`AccountStateCoordinator`
  in standalone `vmu_core` is not broken.** This repo's Credit auth engine
  is healthy.
- Phases 1–8 of `docs/phase-tracker.md` are genuinely complete: FAS, CMS,
  TRAMS, CDM, ASM, MBS (schemas), ITS/IVR, CTA, COL, DPS, LMS, HCS all have
  real, compiled code and (for most) passing test suites.

So the plan below **re-scores every comparison row against this repo's own
reality**, not the source doc's number. Where the two disagree materially,
both are shown.

---

## 1. Corrected status by comparison row

Legend: 🟢 built & strong (small gaps only) · 🟡 built but with named,
concrete gaps · 🟠 partial data model only, no real flow · 🔴 zero code in
this repo · 🔵 scope decision needed before any estimate is meaningful.

### Group A — Core issuing/switching spine (already vmu_core's strength)

| Row | Doc % | vmu_core reality | Owning module(s) | Real named gap |
|---|---|---|---|---|
| Credit Card Issuing | 95% | 🟢 matches | CTA, CMS, CDM | none major |
| Card Authorization Engine | 95% | 🟢 matches | FAS (46/46 FRs) | ProductionHSM is a stub; sanctions/velocity untested (no Redis in dev) |
| Clearing | 85% | 🟢 matches | TRAMS (25/25 FRs) | ADR-T4 (no normalized merchant master) deferred by design |
| Settlement | 85% | 🟢 matches | TRAMS | same as above |
| POS Switching | 85% | 🟢 matches | FAS/TRAMS | — |
| Fee Management | 85% | 🟢 matches | MBS MdrEngine, CMS | — |
| Billing Engine | 90% | 🟢 matches | CMS EOD pipeline | — |
| Interest Calculation | 90% | 🟢 matches | CMS InterestEngine | — |
| Cloud Native | 90% | 🟢 matches | platform (Elixir/BEAM) | — |
| Microservices | 85% | 🟢 matches | 14 real `lib/vmu_core/*` domains | still single umbrella app, not yet separate OTP releases |
| Event Driven | 80% | 🟢 matches | GenServer/Horde/Oban patterns throughout | — |
| Real-Time Processing | 90% | 🟢 matches | FAS hot path | — |
| ISO8583 Support | 70% | 🟡 close | FAS | dialect/network-specific field coverage beyond the built MTIs unverified |
| Merchant Acquiring | 80% | 🟢 complete — separate system | `MerchantManagementSystem` (`D:\momentPay\Products\E-VisionPlus\MerchantManagementSystem`) | Real, substantial Laravel/PHP system: merchant onboarding, KYB, LSEG ongoing sanctions/PEP screening, credit scoring, virtual IBAN, MDR, channel-partner/sales-person hierarchy, dispute handling. **Deliberately kept separate from vmu_core — not a gap, a scope decision.** |
| Merchant Management | 80% | 🟢 complete — separate system | `MerchantManagementSystem` | same system as above |
| Terminal Management (TMS) | 85% | 🟢 complete — separate system | `tmsuat_apps-main` (`D:\momentPay\Products\E-VisionPlus\tmsuat_apps-main`) | Real Elixir umbrella (`da_product_app`) with terminal fleet dashboards, live location maps, remote control, online-rate monitoring, settlement/risk/batch processing. Same repo vmu_core's own TRAMS/FAS already source `settlement_core`/`da_switch_core`/`da_issuer` from (see CLAUDE.md) — **kept as its own system, not absorbed into vmu_core's MBS.** |
| Chargeback Management | 75% | 🟡 close | DPS (P1–4 done) | reason-code reference data pending |
| Dispute Management | 85% | 🟢 matches, verified 2026-07-23 | DPS | P5 ops UI built + 11/11 tests passing (this repo's first LiveView test). Found/fixed 3 real pre-existing bugs in `Dispute.file/1`/`transition/2`/`DeadlineJob` along the way (stale-struct returns, unguarded UUID casts, a deadline job that never checked whether its own deadline had arrived — see `DPS_Gap_Implementation_Tracker.md` DPS-P5). Real evidence backend (S3/Azure) remains a stub (unchanged scope) |
| AML Integration | 85% | 🟢 fixed 2026-07-23, verified against real data | CDM | was unwired (documented, never called); now closed — `ApplicationScorer.score/1` screens every applicant via `MwRisk.SanctionsChecker.check_payload/2` (fail-closed), re-verified against the real 76k-row `mw_core_dev.risk_sanctions_list` (not synthetic data) after fixing two real infra bugs found along the way: `InfraRepo.Repo` was a MySQL client misconfigured with Postgres connection params (never connected, silently degraded to an empty cache — affected FAS's own `RuleCache`/`SuppressionsCache` too, not just CDM), and the 500ms timeout budget (copied from FAS's card-present SLA) was too tight for a real 76k-entry fuzzy scan (~1.3-1.6s), raised to 5s. Residual: tenant scoping still unresolved, no REFER-queue UI yet (see `CDM_Gap_Implementation_Tracker.md` CDM-P2) |
| Fee Management / Billing / Interest | 85–90% | 🟢 | CMS | — |

### Group B — Real, built, with concrete finishable gaps

| Row | Doc % | vmu_core reality | Owning module(s) | Real named gap |
|---|---|---|---|---|
| KYC | 65% | 🟡 | Shared/CIF | dedupe, merge, sanctions hook, exposure roll-up, consent/retention all missing (per CIF requirements doc) |
| Risk Engine | 65% | 🟡 | CDM | AML unwired (see above); no policy knockout rules beyond bureau score; no REFER/manual-override queue |
| Fraud Detection | 50% | 🟡 | CDM, FAS | rules-based only; velocity rules real but untested without Redis; no ML models anywhere |
| Loyalty Engine | 45% | 🟡 | LMS (P1 done) | no warehouse-release job (points sit un-redeemable if `warehouse_days > 0`); no reversal/chargeback clawback; no MCC exclusions; no time-based accelerators |
| Campaign Management | 35% | 🟠 | LMS | not built beyond scheme/plan/rate-tier primitives |
| Pricing Engine | 55% | 🟡 | MBS MdrEngine | Interchange++ pending |
| Collections | 40% (doc understates) | 🟢 P1–P9 done | COL | XML agency-file parsing unimplemented; RESTRUCTURE doesn't auto-generate an EMI schedule (deliberate, per prior review); no MI dashboard; no auto-close on cure |
| Business Rules Engine | 55% | 🟡 | Shared ParameterEngine (SYS→BANK→LOGO→BLOCK) | real but narrower than a general rules engine — it's a parameter cascade, not an arbitrary condition/action engine |
| No-Code Configuration | 30% | 🟡 | Shared ParameterEngine + Module Config Framework | strong for *parameters*, weak for *behavior* — workflow/state-machine logic is still code-defined |
| Workflow Engine | 45% | 🟡 | ASM maker-checker | real but not generalized beyond the specific flows it was built for (limit changes, waivers) |
| Analytics Dashboard | 45% | 🟠 | none dedicated | no BI warehouse; the closest things are the ops-UI gaps above (COL MI dashboard, DPS case dashboard, CMS EOD status screen) |
| High Availability | 65% | 🟡 | Horde/libcluster | distribution is real; Active-Active DR posture has not been tested/certified |
| Scalability | 50% | 🟡 | platform | claimed benchmarks not proven against this repo's own production load |
| Multi-Language | 25% | 🔴/unclear | — | no i18n framework usage confirmed anywhere in `vmu_core` — needs an actual audit, not just a doc note |
| Multi-Entity | 45% | 🟡 | Shared ParameterEngine SYS→BANK levels | merchant hierarchy now explicitly out of vmu_core (`MerchantManagementSystem`, see §1 Group A); no broader multi-issuer/bank-group concept beyond SYS/BANK levels either |
| Multi-Tenant | 35% | 🟡 | Shared ParameterEngine SYS→BANK levels | multiple banks *can* share one deployment via the parameter cascade — never proven with 2+ real banks in one DB; no tenant data isolation guarantees documented |
| SaaS Deployment | 35% | 🟠 | — | no packaging/deployment story for a third party to self-host this as SaaS |
| AI Ready | 25% | 🟠 | — | aspirational; no live ML model anywhere in the repo |
| Digital Banking / Statement / etc. | — | 🟡 | CMS | covered under CMS's own 70-FR backlog (17% remaining, see §2 Phase 0) |

### Group C — Genuinely absent in this repo (net-new build)

| Row | Doc % | vmu_core reality | Notes |
|---|---|---|---|
| Debit Card Issuing | 10% | 🔴 0% here | zero `lib/vmu_core/debit` code; requirements doc only |
| Prepaid Cards | 40% | 🔴 0% here | zero `lib/vmu_core/prepaid` code; the "40%" reflects Avenza's CU-2 work, not this repo |
| Virtual Cards | 45% | 🟠 partial | `cta_cards.card_type` already has a `VIRTUAL` enum value (data model ready) — but the dedicated issuance + one-time credential-reveal flow (PAN/CVV generation, ephemeral vault) was only ever built in Avenza; no equivalent exists here |
| Corporate Cards | 10% | 🟡 closer than doc suggests | HCS (Phase 7, complete) already gives company/employee-card/spending-control primitives — Corporate Cards is much more "extend HCS + add a card product config" than a from-zero build |
| Fleet Cards | 0% | 🟡 closer than doc suggests | same HCS foundation; the Avenza-only piece was vehicle/driver-assignment (`HCS.Vehicle`, `HCS.DriverAssignment`) layered on top — a real but bounded addition, not a new module |
| Tokenization (network tokens) | 10% | 🔴 | no vendor token-service integration anywhere |
| Apple Pay / Google Pay | 5% | 🔴 | depends on tokenization above |
| BNPL (merchant) | 30% | 🟡 partial | CMS/COL already do account-level EMI; true merchant-initiated BNPL (installment offered at POS, separate merchant settlement terms) is unbuilt |
| Digital Wallet | 60% | 🔴 0% here | this is entirely Avenza/`wallet-app` territory; **no wallet ledger, account, or card concept exists in `vmu_core`** |
| QR Payments | 55% | 🔴 0% here | same — merchant-presented QR is a wallet-app/channel capability |
| Instant Payments | 45% | 🔴 0% here | same |
| Account-to-Account (A2A) | 40% | 🔴 0% here | same |
| ATM Switching | 5% | 🔴 | FAS is an issuer switch for card-present/CNP auth; no ATM-acquiring path modeled |
| ISO20022 | 25% | 🔴 | no pain/pacs message support |
| Multi-Currency | 60% | 🔵 architecture conflict, not just a gap | **CMS's own ADR-C4 deliberately chose single billing currency per account** — Way4's "Unlimited" multi-currency claim (sub-wallet style) directly conflicts with a decision already made here. Needs a product decision, not a code fix, before scoring or building against it. |

---

## 2. Phased roadmap

### Phase 0 — Close real gaps in modules that already work (highest ROI, lowest risk)
No new architecture; every item below is finishing a module already proven
end-to-end in this repo. This is what actually moves the % Match column for
Group A/B rows, and it's the only phase with zero open scope decisions.

1. ~~**CDM — wire AML/sanctions into `score/1`.**~~ ✅ Done 2026-07-23. See
   `CDM_Gap_Implementation_Tracker.md` CDM-P2 for the full build + live
   verification (real + fuzzy sanctions hits, fail-closed timeout proof).
   Along the way, found the module's own CDM-P1 tracker entry had documented
   two persistence-bug fixes (raw table-name string, decline short-circuit)
   that were not actually present in the code — re-applied both, since
   sanctions screening needed a single always-persists decision path anyway.
2. ~~**DPS — build the P5 ops UI.**~~ ✅ Done 2026-07-23. See
   `DPS_Gap_Implementation_Tracker.md` DPS-P5 — case list/detail/deadline
   monitor/evidence/notes/assignment/reason-codes, 11/11 tests passing
   (this repo's first-ever LiveView test). Found and fixed 3 real
   pre-existing bugs in `Dispute.file/1`/`transition/2`/`DeadlineJob` along
   the way, plus 2 test-infra gaps (`config/test.exs` had no
   `secret_key_base`; the test DB has no seeded parameter hierarchy) that
   likely explain why no admin LiveView anywhere in this repo had browser
   test coverage before now. Real evidence-store backend (S3/Azure) stays
   a stub, unchanged scope.
3. **CMS — close the highest-value FR-057/058/067/070 gaps.**
   ~~FR-057 (EOD job status/rerun admin screen)~~ ✅ Done 2026-07-24 — see
   `CMS_Feature_Status.md` FR-057 row.
   ~~FR-058 (cycle resegmentation batch)~~ ✅ Done 2026-07-24 —
   `VmuCore.CMS.CycleResegmentation` + admin screen, every policy lever
   (notice period, min interval, allowed billing days, rebalance
   threshold, manual/auto mode) bank-configurable via a new `cms` Module
   Configuration catalog rather than hardcoded — the region/regulatory
   configurability this item's own scoping asked for. Found and fixed a
   real pre-existing bug in `EodSchedulerJob` along the way:
   `ReinstateLimitJob` was nested inside the "cycle_codes due today"
   branch despite its own comment saying it should always run daily — on
   any day with zero due cycle_codes it silently never ran at all. See
   `CMS_Feature_Status.md` FR-058 row for full detail, including the one
   explicit scope limit (interest-engine proration not wired — flagged,
   not silently missing).
   ~~FR-067 (transaction-level payment allocation)~~ ✅ Done 2026-07-24 —
   new `cms_transaction_allocations` table + `VmuCore.CMS.PurchasePosting`/
   `PaymentAllocation`, allocation method (fifo/lifo/highest_amount_first/
   proportional) and disputed-transaction exclusion both bank-configurable
   via the `cms` Module Configuration catalog, same pattern as FR-058.
   Found and fixed a foundational gap along the way: purchases never
   populated any transaction-level record at all (only the aggregate
   `BalanceBucket` moved) — traced the real settlement-confirmation path to
   `FAS.SettlementPostingAdapter.confirm_one/1` (reached from both the
   auth-consumer and the TRAMS posting-cycle job) and hooked purchase
   posting there, atomic with the existing GL post. Deliberately not
   backfilled — only purchases posted from now on get transaction-level
   detail. See `CMS_Feature_Status.md` FR-067 row for full detail.
   ~~FR-070 (payment-receipt notifications)~~ ✅ Done 2026-07-24 — new
   `VmuCore.CMS.NotificationDispatcher` (behaviour + email/sms/whatsapp/
   webhook adapters, an adapter abstraction same shape as DPS's
   evidence-store stubs) + `VmuCore.CMS.Notification` context, new
   `cms_notification_log` table. Unlike DPS's S3/Azure stubs, all 4
   channels are real working code, not stubs — each is just a
   bank-configured HTTP POST (via `Req`, newly added as an explicit dep;
   it was already resolved transitively) carrying content/content_format/
   channel/priority, so there's no specific vendor SDK this codebase is
   missing. Which channels fire and where they POST is bank-configurable
   (`cms.notification_channels_enabled`/`notification_gateway_config`),
   same Module Configuration pattern as FR-058/067. Wired into
   `PaymentIntake.apply_payment/5` best-effort, outside the DB transaction.
   6/6 tests, HTTP faked via `Req.Test` (a real Plug pipeline) rather than
   Bypass — Bypass's `ranch ~> 1.3` requirement conflicted with
   muNSwitch/wallet-app's `ranch ~> 2.1`.

   Item 3 (CMS backlog) is now fully closed — all four FR-057/058/067/070
   gaps done.
4. **COL — MI dashboard + agency-file parsing.**
   **Major re-scope, 2026-07-24**: found the entire P1-P9 COL build (agency
   placement, write-off/workout/settlement, contact history, CSV/JSON
   agency file exchange, admin UI) had been verified once already
   (2026-07-10) but never committed — extracted into `Avenza/apps/vmu_col`
   by an old commit and never carried back after the platform-of-record
   reversal to standalone vmu_core. Re-ported it in full (see
   `COL_Gap_Implementation_Tracker.md`'s "Re-port note") before doing any
   new work — this item is NOT a from-scratch build.
   With the foundation restored:
   ~~(a) configurable field-mapper for agency file ingestion/generation~~
   ✅ Done 2026-07-24 — `col.agency_config` per-agency now optionally
   carries `import_mapping` (their header → our field), `activity_type_map`
   (their activity-type vocabulary → ours), `date_format` (strptime-style
   `%Y`/`%m`/`%d`), and `export_mapping` (our field → their desired
   header/tag, applied symmetrically to CSV/JSON/XML assignment-file
   generation, column/tag ORDER always stays canonical). All four keys are
   optional and default to identity — an agency that already sends our own
   shape needs zero config, so this subsumes "one fixed format for all"
   as the trivial case rather than being a separate mode. 6/6 new
   `agency_desk_field_mapper_test.exs` tests (import remap + value
   translation + custom date format on a real PAYMENT posting through the
   full `PaymentIntake` pipeline, a rejected-unmapped-value case, CSV/JSON
   export renaming, and the identity no-mapping case still working
   unchanged). Full CMS/FAS/COL/admin regression before/after: same 10
   pre-existing failures, zero regressions.
   ~~(b) the MI dashboard (FR-025)~~ ✅ Done 2026-07-24 — new
   `col_dpd_bucket_history` table + `AgeBucketsJob` hook (found the same
   kind of foundational gap FR-067 did: `delinquency_bucket` gets
   overwritten in place every EOD run, no transition trail existed
   anywhere — confirmed with user before building the full pipeline
   rather than shipping only the two metrics that didn't need one) +
   `VmuCore.COL.CollectionsMi` (promise-kept %/recovery % real from
   existing data; roll rate/cure rate per DPD bucket, newly real) +
   `CollectionsMiComponent` admin screen. Roll/cure rate honestly has no
   data before 2026-07-24 — nothing to backfill from, stated in the UI.
   7/7 tests. See `COL_Gap_Implementation_Tracker.md`'s COL-P10 for full
   detail.
   Still open: (c) XML agency-file *parsing* — still blocked on a real
   vendor sample (XML *generation* already existed and now honors
   export_mapping too).

   **Item 4 (COL) is now fully closed** modulo the XML-parsing item,
   which stays blocked on a real vendor sample rather than being guessed
   at, per this repo's own established discipline.
5. **LMS — warehouse-release job + reversal/chargeback clawback.**
   **Re-port done 2026-07-24, before any new work** (same discovery
   pattern as item 4): LMS-P1's real `open_to_redeem` bug fix (2026-07-11
   — a live bug, not just a missing feature; any account that redeemed
   once was permanently locked out of redeeming again) was verified once
   but never committed, lost to the same M2 extraction that took COL's
   P1-P9 build. Re-ported the 10 diverged files from `Avenza/apps/vmu_lms`
   (4 with real logic: `points_engine.ex`/`points_ledger.ex`/
   `redemption_processor.ex`/`oban/points_expiry_job.ex`). 5/5 new tests
   (`points_redemption_bugfix_test.exs`), zero regressions. See
   `LMS_Gap_Implementation_Tracker.md`'s re-port note for full detail.
   ~~Warehouse-release job + reversal/chargeback clawback~~ ✅ Done
   2026-07-24 — genuinely new work, not built in either copy. Found and
   fixed one more real bug along the way: `lms_points_ledger.
   source_clearing_id` was `bigint` while `trams_clearing_records.
   clearing_id` (what it's supposed to reference) is `uuid` — created
   before that table's real PK was finalized, never reconciled, meaning
   the real earn pipeline (`PointsCalculationJob` → `PointsEngine`) has
   never actually succeeded against real clearing data. Also found
   `PointsExpiryJob` was never scheduled anywhere despite its own
   moduledoc's claim — fixed alongside the new `WarehouseReleaseJob`
   (both now in the Oban crontab). `VmuCore.LMS.Clawback` hooks into
   `DPS.Dispute.transition/2`'s `CLOSED_WIN` transition specifically —
   the point at which a chargeback means the cardholder never actually
   paid for the purchase. 7/7 tests, zero regressions. See
   `LMS_Gap_Implementation_Tracker.md`'s LMS-P2 for full detail.

   **Item 5 (LMS) is now fully closed.**
6. **ASM — MFA (TOTP) + real SSO/LDAP wiring.** `authn_source` config
   already exists and is unwired — same "config exists, no consumer"
   pattern found repeatedly elsewhere in this codebase.
7. **FAS — ProductionHSM real vendor integration.** Vendor/approach
   decided 2026-07-24 (not yet implemented, stubs updated to match):
   **Veriscent-hosted Thales payShield 10K via the real 10XPay REST API**
   — mTLS, one endpoint per host command (`CY` → `verify_cvv/4` and the
   ARQC/ARPC endpoints both confirmed directly against a real Postman
   collection; PIN/issuer-script command selection still needs picking
   from the real Host Commands manual before implementation). Reference
   material + real mTLS credentials: `D:\momentPay\Products\E-VisionPlus\
   Veriscent-HSM-cloud\` (a sibling folder, not part of this repo — never
   copy `slot_1/`'s contents in). A parallel **direct TCP host-command
   socket** option is kept as an equally real, equally unbuilt stub
   (`VmuCore.FAS.HSM.SocketHSM`, config-swappable via the same
   `:hsm_adapter` key as `ProductionHSM`) rather than committing to
   REST-only before real deployment topology is known. Full detail:
   `docs/fas/FAS_Implementation_Tracker.md` 7C. Sanctions/velocity also
   still need verification against a real Redis instance (currently
   untestable in dev) — unrelated to the HSM decision, same item.

~~MBS scope decision~~ — **resolved 2026-07-23, no vmu_core build needed.**
Merchant onboarding/KYB/acquiring already lives in `MerchantManagementSystem`
and terminal fleet management already lives in `tmsuat_apps-main` — both
real, substantial, separate systems, kept deliberately separate rather than
absorbed into vmu_core's `mbs/`. vmu_core's own `mbs/` schemas (Phase 5,
`mbs_merchants`/`mbs_terminals`/`MdrEngine`) stay as-is: a minimal
issuer-side merchant reference feeding TRAM inquiry + LMS offers (per
`MBS_Module_Requirements.md`'s own recommendation), not a platform to
extend. No further MBS work is in this plan.

### Phase 1 — Card portfolio expansion (net-new, built natively on the vmu_core spine)
Every product below follows the same proven pattern already used for
Credit: a `cms_accounts`/`cta_cards` row with an `account_class`/product
flag, parameters resolved through the SYS→BANK→LOGO→BLOCK cascade, auth
through FAS, clearing through TRAMS. This is deliberately **not** a repeat
of Avenza's `DebitAccountConfig`/`PrepaidProgram` pattern — those were
identified as unnecessary duplication of LOGO/BLOCK and are not being
reintroduced here.

1. **Debit Card Issuing** — new `account_class: DEBIT` on `cms_accounts`
   (balance-funded, no OTB/credit_limit), FAS available-funds check reused
   with a debit-specific "available" computation. Highest-value single
   addition — currently the platform's single biggest score gap (10%→0%
   corrected) against every competitor in the table.
2. **Prepaid Cards** — same pattern, closed-loop clearing through TRAMS
   (issuer is also acquirer for on-us transactions — same pipeline, just a
   different clearing source, consistent with this repo's own "no product
   bypasses FAS→TRAMS→GL" principle).
3. **Virtual Cards — finish the issuance flow.** Data model is ready
   (`card_type: VIRTUAL` already exists); build the missing piece: instant
   issue-to-active, CVV generation (extend `SoftHSM`'s existing `verify_cvv`
   with a `generate_cvv` counterpart), and a one-time credential-reveal
   mechanism (ephemeral, never persisted — same non-negotiable posture as
   any real PAN handling in this codebase).
4. **Corporate Cards** — extend the already-complete HCS company/employee-
   card model with a Corporate-specific product config (LOGO/BLOCK) and
   admin surface. Smallest lift in this phase; foundation is done.
5. **Fleet Cards** — extend HCS with vehicle identity + driver-assignment
   (VIN/plate + current-assignment-only model, matching the pattern
   already designed once for this exact problem) and fuel-specific
   spending controls (daily cap, cash-access block — `LimitController`
   already supports both generically).
6. **BNPL (merchant)** — a genuinely new capability: installment terms
   originated at POS by a participating merchant, not just an
   account-level EMI plan. Now that merchant onboarding/hierarchy lives in
   `MerchantManagementSystem` rather than vmu_core's `mbs/`, this item's
   real dependency is an integration contract with that system (merchant
   eligibility/participation data), not a vmu_core-side MBS build —
   scoping that integration is the first step, not blocked on anything
   inside this repo.
7. **Tokenization / Apple Pay / Google Pay** — vendor token-service
   integration (network token requestor). Needs a vendor/network decision
   (§3 Decision 2) before scoping.

### Phase 2 — Digital channel absorption (the wallet-app "port in" work)
This is the concrete first slice of the still-unwritten wallet→vmu_core
porting plan flagged in the platform-of-record decision. **Not started —
this phase needs its own detailed design doc before any code**, the same
discipline used for every other module in this repo (`docs/<module>/
<Module>_Requirements.md` before implementation). Covers: Digital Wallet,
QR Payments, Instant Payments, Account-to-Account, and (pending Decision 3
below) Multi-Currency.

- Recommended first step: a `docs/wallet/WALLET_Module_Requirements.md`-
  style requirements pass (the doc stub already exists under
  `docs/wallet/` — currently a planning stub, not yet a real gap-analysis
  against `wallet-app`'s actual `WalletLedger`/`WalletAccounts` code) that
  decides what ports in as-is vs. what gets rebuilt on the `cms_accounts`
  spine, per the "best implementation wins, one model of record" principle
  already agreed for the ledger/account convergence question.
- ATM Switching and ISO20022 are grouped here provisionally — both are
  genuinely new acquiring/rail capabilities with no natural home yet;
  confirm during the requirements pass rather than assuming they belong
  with the wallet channel work.

### Phase 3 — Platform maturity
Lower urgency; these are cross-cutting improvements to what Phases 0–2
build, not new business capability.

1. Multi-tenant / SaaS packaging — prove 2+ real banks coexisting in one
   deployment via the existing SYS→BANK levels; define the deployment/
   provisioning story.
2. No-code configuration generalization — extend the parameter cascade
   (already strong) toward configurable *behavior*, not just values.
3. Analytics/BI warehouse — a real reporting layer instead of the
   scattered per-module dashboards being built in Phase 0.
4. AI-assisted fraud — a real ML model behind CDM's scoring, once there's
   enough real transaction volume/labels to train against.
5. HA/DR certification and a real scalability/load-test proof point.

---

## 3. Decisions needed before Phase 1/2 scoping (can't be made unilaterally)

~~MBS scope~~ — **resolved 2026-07-23**: merchant acquiring/management and
terminal management stay in `MerchantManagementSystem`/`tmsuat_apps-main`
respectively, permanently separate from vmu_core. See §1 Group A and §2
Phase 0 above.

1. **Tokenization vendor** — which network token service(s) to integrate
   (Visa Token Service, Mastercard MDES) and whether Apple Pay/Google Pay
   are in scope for this phase or a later one. Blocks Phase 1 item 7.
2. **Multi-currency** — does the platform need real multi-currency-per-
   account support (reversing ADR-C4), or does that belong entirely in a
   future wallet/channel layer (Phase 2) while `cms_accounts` stays
   single-currency by design? This is an architecture decision, not a
   feature toggle.
3. **KYC provider market** — config-driven recognition rules are cheap;
   external provider adapters (e.g., India CKYC) are market-gated and were
   already parked once pending a launch-market answer — still open. (Note:
   `MerchantManagementSystem` already has a real LSEG screening integration
   for merchant KYB — worth checking whether that vendor relationship
   extends to cardholder/applicant KYC too before evaluating others.)
4. **Wallet channel ownership** — confirms whether Phase 2's "port wallet
   functionality into vmu_core" happens as literally described in the
   platform-of-record decision, and on what timeline relative to Phase 1's
   card-portfolio work (which has no dependency on it and could run
   first/in parallel).

---

## 4. Suggested sequencing

Phase 0 has no open decisions and the highest ratio of score-improvement to
effort — recommend starting there regardless of which Phase 1/2 item comes
next. CDM (item 1) and DPS (item 2) are both done. Items 3–7 (CMS, COL,
LMS, ASM, FAS) can follow in any order — none block each other. Given the
pattern found closing out both CDM and DPS (real bugs and real
infrastructure gaps hiding behind code that had never actually been
exercised against live data or a real test run), it's worth budgeting for
similar discoveries in whichever item comes next rather than assuming a
clean, additive build.

Within Phase 1, Debit and Corporate/Fleet (extends HCS, already done) are
the lowest-risk, highest-comparison-impact items and don't depend on any
of the four open decisions in §3; Prepaid and Tokenization each depend on
one specific decision and can be scoped in parallel once that decision
lands; BNPL's dependency is now an integration contract with
`MerchantManagementSystem` (merchant eligibility data), not anything
inside this repo. Phase 2 should not start until its own requirements pass
(see Phase 2 above) is written — this is the single largest undertaking in
the plan and deserves the same design discipline as every other module in
this repo, not an improvised port.
