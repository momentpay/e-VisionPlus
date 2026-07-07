# E-VisionPlus FAS — Implementation Tracker

> **How to use:** Update the `Status` column as each item is completed.
> Statuses: `✅ Done` · `🔄 In Progress` · `⬜ Pending` · `➖ N/A`
>
> Source of truth: `vmu_core/docs/fas/fas_system_requirements.md` (107 FRs)
> Gap analysis produced: 2026-06-17
> Last updated: 2026-07-02 — FAS-P3 through FAS-P8 complete — ALL PHASES DONE
> Phases in this document use the `FAS-P1`..`FAS-P8` prefix specifically so they
> never collide with `../phase-tracker.md`'s unrelated Phase 1-8 (native vMu
> module build) or `../phase1-8-implementation-spec.md` (original CDM/ASC
> foundation build) — three different workstreams previously shared the same
> "Phase N" label, which is what caused this tracker to look contradictory.

---

## Reconciliation Note (2026-06-24)

`docs/phase-tracker.md` separately claims 100% completion across 8 phases with
commit hashes. That document is accurate but covers a **different scope**: the
native vMu reimplementation of CMS, CTA, IVR, DPS, TRAMS, COL, CDM, ASM, MBS,
LMS, HCS, ITS (confirmed — `lib/vmu_core/{cms,cdm,cta,ivr,dps,trams,col,asm,
mbs,lms,hcs,its}/` are populated with real modules). It does **not** cover the
FAS integration/hardening work tracked in *this* document. The two trackers
are not in conflict — they track non-overlapping workstreams.

Every item below was re-checked against `lib/vmu_core/` source on 2026-06-24
(file existence + actual call sites, not just grep hits in comments). Two
corrections from the 2026-06-17 gap analysis:
- **1A/1B/1C** are done, but not where originally planned — see note in FAS-P1.
- **3D** (STAN duplicate detection) is actually implemented; the 2026-06-17
  analysis missed it. All other FAS-P2–FAS-P8 items remain genuinely unimplemented
  — confirmed zero real call sites for `MwRisk`, `SettlementCore`, or
  `WalletGl` anywhere in `vmu_core/lib/` (only docstring mentions).

---

## Architecture Overview

Five existing applications form the full FAS stack. The implementation plan
wires them together rather than rebuilding what already exists.

| App | Umbrella | Role | State |
|-----|----------|------|-------|
| `vmu_core` | vmu_core | Issuer FAS + CMS + TRAMS | Skeleton FAS; full CMS |
| `mw_risk` | mw-core | Fraud rules engine + ML scoring | Production-ready; **not wired** |
| `settlement_core` | tmsuat | Clearing, reconciliation, payout | Production-ready; **not wired** |
| `wallet_ledger` | wallet-app | Double-entry wallet ledger | Production-ready (wallet scope) |
| `wallet_gl` | wallet-app | GL posting adapter (AFEX) | Production-ready; **not wired** |

**Integration gaps (not missing functionality):**
- vmu_core FAS has no TCP listener and no auth history table — these are the prerequisite for everything else
- mw_risk fraud engine exists but is not called from FAS.Authorization
- settlement_core reconciliation engine exists but cannot link to FAS auth records
- wallet_gl GL adapter exists but is not wired to card settlement flows

---

## FAS-P1 — FAS Foundation

**Goal:** Give vmu_core FAS a real network entry point, durable auth record, and
complete response code set. All subsequent phases depend on this.

**Scope:** vmu_core only · **Estimated effort:** 2–3 weeks

| # | Task | File(s) | Status | Completed |
|---|------|---------|--------|-----------|
| 1A | Issuer TCP listener — Ranch-based socket server accepting ISO 8583 on configurable port; connection pool, keep-alive, graceful shutdown | Relocated to `muNSwitch/apps/da_issuer` (`DaIssuer.ListenerSupervisor` + `DaIssuer.Protocol`, Ranch-based, MIP 7585 / VAP 8600) | ✅ Done (relocated) | 2026-06-24 |
| 1B | ISO 8583 field extractor — parse MTI; extract DE2/3/4/11/14/22/37/41/42/49/55 from 0100/0200/0400 | Relocated — handled by `da_switch_core`'s `DaSwitchCore.Packagers.ISOMsg` before `authorize/1` is called; no separate extractor built in vmu_core | ✅ Done (relocated) | 2026-06-24 |
| 1C | ISO 8583 response builder — construct 0110/0210/0410 MTI; echo DE3/4/11/12/13/37/41/42; set DE39 (RC), DE38 (approval code) | Built inline in `fas/authorization.ex#authorize/1` via `ISOMsg.set_mti/2` + `DaSwitchCore.MTIConverter.to_response/1`, not a separate `response_builder.ex` | ✅ Done (relocated) | 2026-06-24 |
| 1D | `fas_authorizations` table — pan_token, amount, currency, mcc, channel, rc, approval_code, stan, rrn, terminal_id, merchant_id, logo_id, sys_id, stip_used, decision_path (jsonb), inserted_at; indexes on (pan_token, inserted_at), (stan, terminal_id), approval_code, rrn | `fas/authorization_record.ex` · `priv/repo/migrations/20260617000003_create_fas_authorizations.exs` | ✅ Done | 2026-06-17 |
| 1E | `fas_pending_holds` table — fas_authorization_id (FK), hold_amount, hold_type (standard/hotel/fuel/preauth), expires_at, cleared_at, reversal_at; index on (fas_authorization_id), (expires_at) where cleared_at is null | `fas/pending_hold.ex` · `priv/repo/migrations/20260617000004_create_fas_pending_holds.exs` | ✅ Done | 2026-06-17 |
| 1F | Wire FAS.Authorization orchestrator — connect TCP message → field extractor → existing BIN/PAN/ASC logic → persist fas_authorization → return ISO 8583 response; replace in-memory-only OTB reduction with pending hold write | `fas/authorization.ex` (rewrite) | ✅ Done | 2026-06-17 |
| 1G | Response code expansion — add RC 05 (do not honour), 54 (expired card), 57 (txn not permitted), 61 (exceeds limit), 62 (restricted card), 94 (duplicate STAN) to decision output | `fas/authorization.ex` · `fas/response_codes.ex` | ✅ Done | 2026-06-17 |

**FAS-P1 Progress: 7 / 7 complete ✅**

---

## FAS-P2 — mw_risk Integration Bridge

**Goal:** Wire the production fraud/risk engine into FAS.Authorization. No fraud
logic needs to be built — only an adapter call and response mapping.

**Scope:** vmu_core + mw-core umbrella · **Estimated effort:** 1 week

| # | Task | File(s) | Status | Completed |
|---|------|---------|--------|-----------|
| 2A | Decide integration mechanism — same umbrella direct module call vs HTTP API call. **Decision: direct call** — `mw_risk` is already a path dep in `mix.exs`, `MwRisk.Pipeline.run/2` is the public entrypoint, no HTTP hop needed or added. | This row + `risk_adapter.ex` moduledoc | ✅ Done | 2026-06-24 |
| 2B | `VmuCore.FAS.RiskAdapter` — convert FAS auth context into `%MwKernel.Context{request: %MwKernel.Message{}}` and call `MwRisk.Pipeline.run/2`. Payload keys (`amount`, `from_account`, `to_account`, `merchant_id`, `device_id`, `mcc`, `tx_type`) match `MwRisk.FeatureHydrator`'s actual `extract_type_a/1` lookup keys, confirmed against `mw-core/apps/mw_risk/lib/mw_risk/feature_hydrator.ex`. `tenant_id` = `sys_id` (assumption — risk rules are configured per institution, not per logo; flag if wrong). | `fas/risk_adapter.ex` | ✅ Done | 2026-06-24 |
| 2C | Wire RiskAdapter in FAS.Authorization — call after ASC approves (before final approve); map `:decline` → RC "05"; map `:review` → log + approve | `fas/authorization.ex` (`handle_asc_result/2`) | ✅ Done | 2026-06-24 |
| 2D | Record risk signal in fas_authorizations — store mw_risk `score` + `fired_rules` + `model_version` in `decision_path`; also set the dedicated `risk_score` column | `fas/authorization.ex` (`persist_async/5`) | ✅ Done | 2026-06-24 |
| 2E | Graceful fallback — if mw_risk call times out (500ms `Task.yield`) or raises, passthrough-approve rather than hard-declining; log warning. Note: `MwRisk.Pipeline.run/2` is already internally fail-safe (catches its own errors → passthrough `:approve`), so this guards only against the OTP app being unreachable, not scoring failures. | `fas/risk_adapter.ex` | ✅ Done | 2026-06-24 |

**FAS-P2 Progress: 5 / 5 complete ✅**

**Rule seeding (2026-06-24, follow-up to 2A-2E):**
- Seeded 5 starter `risk_activation_rules` threshold rules per tenant (high/very-high value, gambling MCC, card velocity 1h/1d) via `priv/repo/seed_risk_rules.exs`, mapped from vmu_core's alpha `sys_id` (`MMPD`→1, `MMRW`→2) through `config :vmu_core, :mw_risk_tenant_ids` and `RiskAdapter.resolve_tenant_id/1`.
- Found and fixed a genuine multi-tenant bug in `mw_risk/scoring_pipeline.ex` (raw, non-int-coerced `tenant_id` passed to `RuleCache.get_rules/1` — would silently return zero rules for any non-numeric tenant_id).
- Found and fixed two MySQL-flavored migrations in `infra_repo` that don't run on Postgres (`risk_activation_rules` `MODIFY COLUMN`, `risk_sanctions_list` `FULLTEXT INDEX`) and applied the full `risk_*` migration set to `vmu_core_dev`.
- Added `RiskAdapter.warm_cache/0`, called from `VmuCore.Application.start/2`, to pre-populate mw_risk's per-tenant ETS caches at boot. This also has to be done with a placeholder card/merchant in the warm-up payload — `FeatureHydrator` only touches `InfraFeatureStore`'s Redis-backed velocity caches when entity fields (card/merchant/...) are present, and Redis isn't running in this dev environment; an empty warm-up payload would never trip the `:fuse` circuit breaker, leaving every *live* call to re-pay the failed-Redis-connection cost and get killed by the 500ms timeout before the fuse could blow.
- Verified end-to-end via `RiskAdapter.evaluate/1`: $7,500 → `:review` (score 0.7, "High value transaction"), $50 → `:approve` (score 0.05), $25,000 → `:decline` (score 0.95, "Very high value transaction") — all in single-digit ms once warmed.
- Still not done: no automated test yet exercising `RiskAdapter` against the sample payloads in `mw-core/docs/fraud-extension/sample-api-call/`; `risk_sanctions_list`/sanctions screening untested (no data seeded); Redis is not running in this dev environment, so velocity/feature-store features (`card:1h:count_tx` etc.) degrade to passthrough-empty in practice even though the activation rules referencing them are seeded.

---

## FAS-P3 — Card Validation Hardening

**Goal:** Complete the card- and account-level validation checks that are missing
from FAS.Authorization despite CMS data being available.

**Scope:** vmu_core only · **Estimated effort:** 1 week

| # | Task | File(s) | Status | Completed |
|---|------|---------|--------|-----------|
| 3A | Card expiry validation — parse YYMM from DE14; compare to current billing month; RC "54" on expired | `fas/authorization.ex` · `fas/card_validator.ex` | ✅ Done | 2026-06-24 |
| 3B | Hot card ETS cache — `:vmu_hotcard_cache` named table; load pan_tokens of LOST/STOLEN/FRAUD-blocked accounts at startup; refresh every 5 min; RC "43" (pickup) for LOST/STOLEN, "62" for FRAUD block | `fas/hot_card_cache.ex` · `application.ex` | ✅ Done | 2026-06-24 |
| 3C | Supplementary card resolution — look up `SupplementaryCard` by pan_token → primary account_id; enforce supplementary `sub_limit` in ASC separately from primary OTB | `fas/authorization.ex` · `cms/account_state_coordinator.ex` · `cms/supplementary_card.ex` | ✅ Done | 2026-07-02 |
| 3D | STAN duplicate detection — query `fas_authorizations` within 60 s window: same stan + pan_token + terminal_id + amount; RC "94" on match | `fas/authorization.ex` (`check_duplicate/1`) | ✅ Done | 2026-06-24 (found during re-verification, missed in 2026-06-17 analysis) |
| 3E | Product / channel flag enforcement — read logo params: `ecom_allowed`, `international_allowed`, `contactless_allowed`, `atm_allowed`, `recurring_allowed`; check against DE22 POS entry mode and transaction channel; RC "57" on blocked channel | `fas/authorization.ex` · `fas/card_validator.ex` · `shared/parameter_engine.ex` | ✅ Done | 2026-06-24 |
| 3F | Daily and single-transaction limit tracking — extend ASC GenServer state to hold `daily_debit_count` + `daily_debit_amount`; reset at midnight; check single-txn max from logo params; RC "61" on exceed | `cms/account_state_coordinator.ex` · `shared/logo_parameter.ex` · `shared/parameter_engine.ex` | ✅ Done | 2026-06-24 |
| 3G | Overlimit tolerance — read logo param `overlimit_tolerance_pct`; allow approval up to (credit_limit × (1 + tolerance)); RC "51" only beyond tolerance | `cms/account_state_coordinator.ex` | ✅ Done | 2026-06-24 |

**FAS-P3 Progress: 7 / 7 complete ✅**

---

## FAS-P4 — settlement_core ↔ vmu_core Bridge

**Goal:** Connect the production settlement/clearing engine to vmu_core FAS so that
auth records can be matched to clearing records and CMS ledger entries are posted
on settlement.

**Scope:** vmu_core + tmsuat umbrella · **Estimated effort:** 1–2 weeks

| # | Task | File(s) | Status | Completed |
|---|------|---------|--------|-----------|
| 4A | Auth lookup API — `VmuCore.FAS.AuthLookup.verify/2` + `by_approval_code_and_rrn/2`; exposed at `GET /api/fas/auth/lookup` via `FasApiController`; auth via `x-vmu-api-key` header (passthrough when unconfigured in dev) | `fas/auth_lookup.ex` · `vmu_core_web/controllers/fas_api_controller.ex` · `vmu_core_web/router.ex` · `vmu_core_web/plugs/internal_api_auth.ex` | ✅ Done | 2026-07-02 |
| 4B | settlement_core reconciliation enhancement — `collect_matched_auth_pairs` captures RRN+auth_number after match step; `verify_auth_codes_5_5` calls `VmuCoreAdapter.verify_auth/2` outside the DB transaction (HTTP, non-blocking); creates exception type 5.5 on mismatch; "5.5" added to `ReconciliationException.changeset` valid types | `settlement_core/vmu_core_adapter.ex` (NEW) · `settlement_core/reconciliation_engine.ex` · `settlement_core/reconciliation_exception.ex` | ✅ Done | 2026-07-02 |
| 4C | CMS ledger posting from settlement — `SettlementPostingAdapter.confirm_batch/1` posts `PURCHASE` `LedgerEntry` (DR 1001 receivables / CR 2001 liability) per settled auth; idempotency key `"settlement:<approval_code>:<rrn>"`; triggered by `confirm_settlements_to_vmu` in reconciliation engine (HTTP POST `/api/fas/settlement/confirm`) | `fas/settlement_posting_adapter.ex` · `fas_api_controller.ex` | ✅ Done | 2026-07-02 |
| 4D | Hold release on clearing match — `SettlementPostingAdapter` sets `fas_pending_holds.cleared_at` within the same DB transaction as the LedgerEntry insert; OTB not credited (debit is confirmed, not reversed — OTB correctly stays reduced until customer payment) | `fas/settlement_posting_adapter.ex` | ✅ Done | 2026-07-02 |

**FAS-P4 Progress: 4 / 4 complete ✅**

---

## FAS-P5 — GL Posting Bridge

**Goal:** Wire card transaction GL posting using wallet_gl's existing adapter
pattern. No GL engine build required — implement the `GlAdapter` behaviour and
define card-specific chart-of-accounts codes.

**Scope:** vmu_core + wallet-app umbrella + settlement_core · **Estimated effort:** 1 week

| # | Task | File(s) | Status | Completed |
|---|------|---------|--------|-----------|
| 5A | Decide GL integration mechanism — `WalletGl.GlPostingStore` ETS+wallet_database pipeline NOT used (not in vmu_core supervision tree); call `VmuCoreGlAdapter.post_entry/2` directly (ADR-003). `WalletGl.GlAdapter` behaviour is still implemented for contract compliance and future co-deployment | ADR-003 in this file | ✅ Done | 2026-07-02 |
| 5B | Card account code mapping — 5-account card chart: 1001 receivables (DR-normal), 2001 credit liability (CR-normal), 4001 fee revenue, 5001 interchange/MDR expense, 9001 suspense. `journal_pair/1` maps PURCHASE/CASH_ADV/FEE/INTEREST/REVERSAL/DISPUTE_CREDIT to (DR, CR) tuples | `fas/gl/card_account_codes.ex` | ✅ Done | 2026-07-02 |
| 5C | `VmuCoreGlAdapter` — `WalletGl.GlAdapter` implementation writing to `cms_ledger_entries`. Callbacks: `create_batch/3` (synthetic batch_id), `post_entry/2` (idempotent insert via `on_conflict: :nothing`), `commit_batch/1` (noop), `get_posting_status/1`, `cancel_posting/1` (`{:error, :cancellation_not_supported}`), `validate_account_codes/1`, `get_reconciliation_data/3` (date-range aggregate), `health_check/0` (`SELECT 1`). `correlation_id` carries `account_id` | `fas/gl/vmu_core_gl_adapter.ex` | ✅ Done | 2026-07-02 |
| 5D | Wire `SettlementPostingAdapter.post_ledger` through `VmuCoreGlAdapter` — converts `settled_amount` Decimal → `Money.new(minor_units, currency)`, builds DR/CR `GlPostingRecord` entries, calls `VmuCoreGlAdapter.post_entry(record, nil)` inside Repo.transaction; rolls back on GL failure. `account_id` passed as `correlation_id` | `fas/settlement_posting_adapter.ex` (updated) | ✅ Done | 2026-07-02 |
| 5E | GL reconciliation gap detection — `GlReconciliation.find_unposted_settlements/2`: queries approved `fas_authorizations` in date range, subtracts those with `idempotency_key = "settlement:<approval_code>:<rrn>"` in `cms_ledger_entries`, returns gap list. `summary/2` for monitoring. Compiled and verified clean | `fas/gl/gl_reconciliation.ex` | ✅ Done | 2026-07-02 |

**FAS-P5 Progress: 5 / 5 complete ✅**

---

## FAS-P6 — Reversals, Incrementals & Completions

**Goal:** Full reversal lifecycle with auth history matching; incremental
authorizations for hotel/car-rental; completion/advice message handling.

**Scope:** vmu_core only · **Estimated effort:** 1 week

| # | Task | File(s) | Status | Completed |
|---|------|---------|--------|-----------|
| 6A | Full reversal processing — handle 0400 MTI; match by STAN+terminal_id+pan_token (60-min window) then fallback by approval_code; release hold (reversal_at); call `ASC.reverse/3` to restore OTB; persist 0400 auth record | `fas/reversal_handler.ex` · `fas/authorization.ex` | ✅ Done | 2026-07-02 |
| 6B | Unmatched reversal exception — no match → log to `fas_reversal_exceptions` (status: pending; JSONB raw_fields for ops); RC "25"; `ExceptionQueue.insert_reversal_exception/2` | `fas/reversal_handler.ex` · `fas/exception_queue.ex` · migration `20260702000001` | ✅ Done | 2026-07-02 |
| 6C | Incremental authorization — detected via DE90 (Original Data Elements) in 0100 message; finds original by DE38 approval_code; extends hold by delta (new_total − original); debits OTB via ASC; trims hold + credits OTB when new_total < original | `fas/incremental_handler.ex` · `fas/pending_hold.ex` (`set_hold_amount_changeset/2` added) | ✅ Done | 2026-07-02 |
| 6D | Completion / advice (0200) — finalize or trim hold to final settled amount; credits OTB for trim delta via `ASC.credit_open_to_buy/2`; unmatched completion accepted with RC "00" (advice cannot be declined) and logged as "unmatched_completion" | `fas/completion_handler.ex` · `fas/pending_hold.ex` | ✅ Done | 2026-07-02 |

**FAS-P6 Progress: 4 / 4 complete ✅**

---

## FAS-P7 — HSM / PIN / CVV / EMV

**Goal:** Hardware security module integration for cryptographic card security
functions. Required for card scheme network certification (Visa/Mastercard).

**Scope:** vmu_core · **Estimated effort:** 3–4 weeks (dependent on HSM vendor)

| # | Task | File(s) | Status | Completed |
|---|------|---------|--------|-----------|
| 7A | HSM adapter behaviour — `VmuCore.FAS.HSM` behaviour with callbacks: `verify_cvv/4`, `verify_arqc/5`, `generate_arpc/3`, `verify_pin/3`, `build_issuer_scripts/2`; delegation helpers read adapter from `Application.get_env(:vmu_core, :hsm_adapter, SoftHSM)` | `fas/hsm/hsm.ex` | ✅ Done | 2026-07-02 |
| 7B | SoftHSM — Visa 3DES CVV algorithm via `:crypto`; ISO 9564 Format-0 PIN block XOR decode + PBKDF2-SHA256 verify; session key diversification with ATC for ARQC; tag 71/72 TLV builder for issuer scripts. `import Bitwise` for `&&&`/`>>>` | `fas/hsm/soft_hsm.ex` | ✅ Done | 2026-07-02 |
| 7C | Production HSM adapter — skeleton with `{:error, :not_implemented}` on all callbacks + Logger.warning; placeholder for TCP/PKCS#11 vendor binding | `fas/hsm/production_hsm.ex` | ✅ Done | 2026-07-02 |
| 7D | CVV1 / iCVV validation — `CardValidator.validate_cvv/4`; DE55 present → iCVV (returns `:skip`, ARQC check is authoritative); DE35 present → parse track2 CVV1, call `HSM.verify_cvv/4`; logo param `cvv_required: false` disables; `{:error, :not_implemented}` (ProductionHSM stub) → `:ok` fail-open; RC "82" on mismatch | `fas/card_validator.ex` (extended) | ✅ Done | 2026-07-02 |
| 7E | PIN block verify + try counter — `cms_card_pins` table (pan_token unique, pin_hash, pin_salt, try_counter, pin_locked_at); `CardPin` schema; `maybe_verify_pin/1` in authorization.ex decodes ISO 9564 Format-0, calls `HSM.verify_pin/3`; increments try_counter on wrong PIN; locks after `max_pin_tries`; RC "55" wrong, "75" locked | `fas/hsm/soft_hsm.ex` (verify_pin) · `cms/card_pin.ex` · migration `20260702000002` · `fas/authorization.ex` | ✅ Done | 2026-07-02 |
| 7F | DE55 EMV BER-TLV parser — `EmvParser.parse/1` (hex or binary); single/multi-byte tags; short/long-form length; struct fields: arqc(9F26), unpredictable_no(9F37), atc(9F36), iad(9F10), aid(84), tvr(95), tsi(9B), currency_code(5F2A), amount(9F02). `import Bitwise` for `&&&` | `fas/iso8583/emv_parser.ex` | ✅ Done | 2026-07-02 |
| 7G | ARQC verification + ARPC generation — `EmvHandler.verify_arqc/1` parses DE55, calls `HSM.verify_arqc/5`; `build_response_de55/3` builds tag 8A (ARC) + tag 91 (ARPC); `arqc_decline_on_fail` config governs hard-decline vs fail-open | `fas/emv_handler.ex` | ✅ Done | 2026-07-02 |
| 7H | Issuer scripts — `EmvHandler.script_commands/2` → `:block_card` for BLOCKED/SUSPENDED, `:reset_pin_tries` for newly-unlocked; `HSM.build_issuer_scripts/2` builds tag 71 (pre-GenAC) + tag 72 (post-GenAC) TLV; injected into 0110 DE55 via `inject_de55/2` | `fas/emv_handler.ex` · `fas/hsm/soft_hsm.ex` | ✅ Done | 2026-07-02 |

**FAS-P7 Progress: 8 / 8 complete ✅**

---

## FAS-P8 — Observability & Operations

**Goal:** Production visibility into FAS decisions, hold aging, GL variance, and
exception queues. Leverages existing LiveDashboard and mw_risk PubSub.

**Scope:** vmu_core + wallet_gl extension · **Estimated effort:** 1–2 weeks

| # | Task | File(s) | Status | Completed |
|---|------|---------|--------|-----------|
| 8A | FAS Prometheus-compatible telemetry — `FAS.Telemetry` module with `execute_auth/4`, `execute_risk_call/2`, `execute_stip/1`, `execute_hold_aging/2`; `metrics/0` merged into `VmuCoreWeb.Telemetry.metrics/0`; emitted from `authorization.ex` (per-call, timed) and `risk_adapter.ex` (per-run, timed); STIP events on stand-in path | `fas/telemetry.ex` · `vmu_core_web/telemetry.ex` (updated) · `fas/authorization.ex` (wired) · `fas/risk_adapter.ex` (wired) | ✅ Done | 2026-07-02 |
| 8B | mw_risk real-time fraud feed — `RiskFeedSubscriber` GenServer; subscribes to `"risk:scores"` on `VmuCore.PubSub`; rebroadcasts `:decline` events to `"fas:risk_alerts"` for admin dashboard; `stats/0` call for health-check; added to supervision tree | `fas/risk_feed_subscriber.ex` · `application.ex` | ✅ Done | 2026-07-02 |
| 8C | Hold aging monitor — `HoldAgingMonitor` GenServer; 60-second poll of `fas_pending_holds` (expired, uncleared); broadcasts `{:hold_aging_alert, ...}` to `"fas:hold_alerts"` PubSub; emits `hold_aging` telemetry; threshold from `config :vmu_core, :hold_aging_alert_threshold_mins, 60`; added to supervision tree | `fas/hold_aging_monitor.ex` · `application.ex` | ✅ Done | 2026-07-02 |
| 8D | Exception queue admin UI — `ExceptionQueueComponent` LiveComponent; status filter tabs (pending/escalated/resolved); paginated table (25/page); Resolve and Escalate actions; subscribes to `"fas:hold_alerts"` (alert banner) and `"fas:risk_alerts"` (live decline feed); wired in `admin_live.ex` sidebar | `live/admin/exception_queue_component.ex` · `admin_live.ex` | ✅ Done | 2026-07-02 |
| 8E | Trial balance — `TrialBalance.report/2` aggregates `cms_ledger_entries` by GL account code + month (DR and CR separately, then merged); `to_csv/1` export; `summary/1` totals. Account names from 5-account card chart | `fas/gl/trial_balance.ex` | ✅ Done | 2026-07-02 |
| 8F | Auth history search — `AuthHistoryComponent` LiveComponent; search by PAN last-4 (suffix LIKE), approval_code, STAN, date from/to; paginated 50/page; shows MTI, RC, amount, risk score, hold status, decision path; hold status computed from `fas_pending_holds` join; wired in `admin_live.ex` sidebar | `live/admin/auth_history_component.ex` · `admin_live.ex` | ✅ Done | 2026-07-02 |

**FAS-P8 Progress: 6 / 6 complete ✅**

---

## Overall Progress

| Phase | Description | Items | Done | In Progress | Pending |
|-------|-------------|-------|------|-------------|---------|
| FAS-P1 | FAS Foundation (TCP + ISO 8583 + Auth History) | 7 | 7 | 0 | 0 |
| FAS-P2 | mw_risk Integration Bridge | 5 | 5 | 0 | 0 |
| FAS-P3 | Card Validation Hardening | 7 | 7 | 0 | 0 |
| FAS-P4 | settlement_core ↔ vmu_core Bridge | 4 | 4 | 0 | 0 |
| FAS-P5 | GL Posting Bridge | 5 | 5 | 0 | 0 |
| FAS-P6 | Reversals, Incrementals & Completions | 4 | 4 | 0 | 0 |
| FAS-P7 | HSM / PIN / CVV / EMV (Network Cert) | 8 | 8 | 0 | 0 |
| FAS-P8 | Observability & Operations | 6 | 6 | 0 | 0 |
| **TOTAL** | | **46** | **46** | **0** | **0** |

**Overall: 46 / 46 complete (100%) ✅**

---

## FR Coverage Map

| FR Group | FRs | Primary Phase | Status |
|----------|-----|---------------|--------|
| Authorization Gateway (TCP + ISO 8583) | 001–010 | FAS-P1 | ⬜ |
| Card Validation (CAF) | 011–016 | FAS-P3 | ✅ (FR-012 expiry ✅, FR-013/015 hot card ✅, FR-014 BIN ✅ via PE, FR-016 supplementary ✅) |
| Account Validation (AAF) | 017–020 | FAS-P3 | ✅ (FR-017 PAN→account ✅, FR-018 account_status ✅ via ASC, FR-019/020 supplementary sub_limit ✅) |
| Product & Transaction Controls | 021–024 | FAS-P3 | 🔄 (FR-022/023 channel flags ✅ via 3E; FR-021/024 product-type/MCC classification ✅ via ASC) |
| Limit & Available Credit | 025–030 | FAS-P3 | 🔄 (FR-025/026 OTB ✅, FR-027 single/daily limits ✅ via 3F, FR-028 overlimit ✅ via 3G, FR-029/030 ✅) |
| Memo Posting / Pending Holds | 031–035 | FAS-P1 | ⬜ |
| Velocity Controls | 036–039 | FAS-P2 (mw_risk) | 🔄 (bridge + rules seeded and verified; velocity features need Redis, not running in dev) |
| Fraud / MCC / Geography | 040–045 | FAS-P2 (mw_risk) | 🔄 (bridge + rules seeded and verified for MCC/value; geography rules not yet seeded) |
| PIN / CVV / HSM | 046–051 | FAS-P7 | ✅ (CVV1/iCVV ✅, PIN block ISO 9564 ✅, try counter + lock ✅, HSM behaviour + SoftHSM ✅, ProductionHSM skeleton ✅) |
| EMV / Chip (DE55) | 052–058 | FAS-P7 | ✅ (BER-TLV parser ✅, ARQC verify ✅, ARPC generation ✅, tag 8A/91 in 0110 DE55 ✅, issuer scripts tag 71/72 ✅) |
| Network Processing | 059–063 | FAS-P1 | ⬜ |
| Decision Engine | 064–068 | FAS-P2 (mw_risk) | 🔄 (bridge + rules seeded and verified — review/approve/decline thresholds confirmed) |
| Response Code Framework | 069–072 | FAS-P1 | ⬜ |
| Stand-In Processing (STIP) | 073–077 | **Already done** ✅ | ✅ |
| Reversals | 078–082 | FAS-P6 | ✅ (0400 match+release+OTB-restore ✅, unmatched→exception_queue ✅) |
| Incrementals / Completions | 083–087 | FAS-P6 | ✅ (incremental via DE90 ✅, hold extend/trim ✅, 0200 completion/advice ✅) |
| Duplicate Detection | 088–091 | FAS-P2 + FAS-P3 | 🔄 (STAN dup done; velocity/mw_risk-side dup pending) |
| Clearing Match | 092–097 | FAS-P4 | ✅ (auth lookup ✅, approval_code verify ✅, 5.5 exception ✅, hold release ✅) |
| FAS-to-CMS Posting | 098–104 | FAS-P4 | ✅ (PURCHASE LedgerEntry idempotent post ✅, DR 1001/CR 2001 ✅) |
| Authorization History | 105–107 | FAS-P1 | ⬜ |

---

## ADR Notes

> Record integration decisions here as they are made.

### ADR-001: mw_risk Integration Mechanism
**Decision:** ✅ Option A — Direct Elixir module call (same umbrella)  
**Options:** (A) Direct Elixir module call if apps can be in same umbrella · (B) Internal HTTP API endpoint in mw-core umbrella  
**Rationale:** Eliminates network hop and serialization overhead on the latency-sensitive auth path. mw_risk will be included as a dependency of vmu_core within the same umbrella.

### ADR-002: GL Integration Mechanism
**Decision:** ✅ Option B — Reuse wallet_gl via direct call / shared lib  
**Options:** (A) Implement `GlAdapter` behaviour in vmu_core posting directly to AFEX · (B) Call wallet_gl functions from settlement_core (if shared or HTTP) · (C) Separate GL microservice  
**Rationale:** Reuse wallet_gl's idempotency guards, retry logic, and reconciliation engine rather than re-implementing. Wire settlement_core MIS approval event to `WalletGl.create_posting/5`.

### ADR-003: GL Posting Mechanism (FAS-P5 refinement of ADR-002)
**Decision:** ✅ Call `VmuCoreGlAdapter.post_entry/2` directly — do NOT go through `WalletGl.create_posting/5`  
**Rationale:** `WalletGl.create_posting/5` routes through `GlPostingStore` (ETS-backed GenServer) which also writes through to `wallet_database`. Neither `GlPostingStore` nor `wallet_database` is started in vmu_core's supervision tree. Calling `create_posting/5` would raise at runtime. The `WalletGl.GlAdapter` behaviour is still implemented (`VmuCoreGlAdapter`) for contract compliance and so the full pipeline can be enabled when vmu_core and wallet-app are co-deployed in the same OTP release (VisionPlus milestone 2). Until then, `SettlementPostingAdapter` calls the adapter directly.

---

## Key File Reference

| Component | File | Notes |
|-----------|------|-------|
| FAS entry point | `lib/vmu_core/fas/authorization.ex` | Implements `DaSwitchCore.FAS.Authorizer` behaviour; builds response inline |
| TCP listener | `muNSwitch/apps/da_issuer/lib/da_issuer/listener_supervisor.ex` | Relocated out of vmu_core — see Reconciliation Note |
| ISO 8583 extractor | `muNSwitch/apps/da_switch_core` (`DaSwitchCore.Packagers.ISOMsg`) | Relocated — no separate extractor in vmu_core |
| ISO 8583 response builder | n/a — folded into `fas/authorization.ex#authorize/1` | No separate file; uses `ISOMsg`/`MTIConverter` |
| Auth history schema | `lib/vmu_core/fas/authorization_record.ex` | Create in FAS-P1 |
| Pending hold schema | `lib/vmu_core/fas/pending_hold.ex` | Create in FAS-P1 |
| Response codes | `lib/vmu_core/fas/response_codes.ex` | Create in FAS-P1 |
| Risk adapter | `lib/vmu_core/fas/risk_adapter.ex` | ✅ Created in FAS-P2; `warm_cache/0` added in seeding follow-up |
| Risk rule seed script | `priv/repo/seed_risk_rules.exs` | ✅ Added in FAS-P2 seeding follow-up — `mix run priv/repo/seed_risk_rules.exs` |
| Card validator | `lib/vmu_core/fas/card_validator.ex` | ✅ Created in FAS-P3 (3A: expiry only so far) |
| Hot card cache | `lib/vmu_core/fas/hot_card_cache.ex` | ✅ Created in FAS-P3 (3B: ETS cache, 5-min refresh, auth pipeline wired) |
| PIN verify (in SoftHSM) | `lib/vmu_core/fas/hsm/soft_hsm.ex` (`verify_pin/3`) | ✅ Created in FAS-P7 — ISO 9564 Format-0 XOR decode; PBKDF2-SHA256; try counter in `cms_card_pins` |
| CardPin schema | `lib/vmu_core/cms/card_pin.ex` | ✅ Created in FAS-P7 — schema for `cms_card_pins`; reset/increment/lock changesets |
| EMV parser | `lib/vmu_core/fas/iso8583/emv_parser.ex` | ✅ Created in FAS-P7 — BER-TLV recursive parser; lenient on unknown tags |
| EMV handler | `lib/vmu_core/fas/emv_handler.ex` | ✅ Created in FAS-P7 — ARQC verify + ARPC build + issuer scripts + DE55 inject |
| HSM behaviour | `lib/vmu_core/fas/hsm/hsm.ex` | ✅ Created in FAS-P7 — 5-callback behaviour + delegation helpers |
| SoftHSM (dev) | `lib/vmu_core/fas/hsm/soft_hsm.ex` | ✅ Created in FAS-P7 — 3DES CVV, ISO 9564 PIN, ARQC, issuer scripts via `:crypto` |
| ProductionHSM (stub) | `lib/vmu_core/fas/hsm/production_hsm.ex` | ✅ Created in FAS-P7 — skeleton for TCP/PKCS#11 vendor HSM |
| GL card codes | `lib/vmu_core/fas/gl/card_account_codes.ex` | ✅ Created in FAS-P5 — 5-account card chart, `journal_pair/1` per transaction type |
| GL adapter | `lib/vmu_core/fas/gl/vmu_core_gl_adapter.ex` | ✅ Created in FAS-P5 — `WalletGl.GlAdapter` behaviour, writes to `cms_ledger_entries`, direct call (ADR-003) |
| GL reconciliation | `lib/vmu_core/fas/gl/gl_reconciliation.ex` | ✅ Created in FAS-P5 — gap detector: approved auths without a settlement LedgerEntry; `summary/2` for monitoring |
| Settlement adapter | `lib/vmu_core/fas/settlement_posting_adapter.ex` | ✅ Created in FAS-P4 — idempotent confirm: LedgerEntry + hold clear |
| Auth lookup | `lib/vmu_core/fas/auth_lookup.ex` | ✅ Created in FAS-P4 — verify/2, by_approval_code_and_rrn/2 |
| FAS internal API | `lib/vmu_core_web/controllers/fas_api_controller.ex` | ✅ Created in FAS-P4 — GET /api/fas/auth/lookup, POST /api/fas/settlement/confirm |
| API auth plug | `lib/vmu_core_web/plugs/internal_api_auth.ex` | ✅ Created in FAS-P4 — x-vmu-api-key header enforcement |
| vmu_core HTTP adapter | `tmsuat_apps-main/apps/settlement_core/lib/settlement_core/vmu_core_adapter.ex` | ✅ Created in FAS-P4 — :httpc-based, verify_auth/2 + confirm_settlements/1 |
| Exception queue | `lib/vmu_core/fas/exception_queue.ex` | ✅ Created in FAS-P6 — `fas_reversal_exceptions` schema; `insert_reversal_exception/2` |
| Reversal handler | `lib/vmu_core/fas/reversal_handler.ex` | ✅ Created in FAS-P6 — 0400 match + hold release + OTB restore |
| Incremental handler | `lib/vmu_core/fas/incremental_handler.ex` | ✅ Created in FAS-P6 — DE90 detect, extend/trim hold, OTB debit/credit |
| Completion handler | `lib/vmu_core/fas/completion_handler.ex` | ✅ Created in FAS-P6 — 0200 trim-or-accept, advice cannot be declined |
| AccountStateCoordinator | `lib/vmu_core/cms/account_state_coordinator.ex` | Extend in FAS-P3 + FAS-P6 |
| ParameterEngine | `lib/vmu_core/shared/parameter_engine.ex` | Extend in FAS-P3 |
| STIP | `lib/vmu_core/fas/stip.ex` | Already complete ✅ |
| FAS migrations | `priv/repo/migrations/` | Phases 1 (2 migrations) · 7 (1 migration) |

---

*This tracker is maintained manually. Update the Status column and Completed date after each task is merged.*
