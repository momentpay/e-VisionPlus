# E-VisionPlus TRAM — Implementation Tracker

> **How to use:** Update the `Status` column as each item is completed.
> Statuses: `✅ Done` · `🔄 In Progress` · `⬜ Pending` · `➖ N/A`
>
> Source of truth: `TRAM_Module_Developer_Requirements.md` + sub-specs 04–12
> Gap analysis produced: 2026-07-03
> Last updated: 2026-07-03 — ALL PHASES COMPLETE (25/25)
> Phases use the `TRAM-P1`..`TRAM-P6` prefix so they never collide with
> `../phase-tracker.md`'s Phase 1-8 or `../fas/FAS_Implementation_Tracker.md`'s
> FAS-P1..P8 — three separate workstreams.

---

## Gap Analysis vs. Existing Code (2026-07-03)

TRAM does **not** start from zero. The following already exists and is
integrated with, not rebuilt:

| Capability | Where it lives | TRAM relationship |
|---|---|---|
| Authorization decisioning + records | `fas/authorization.ex` · `fas_authorizations` · `fas_pending_holds` | TRAM consumes; references `fas_authorization_id`; never duplicates decision data |
| Reversal / incremental / completion handling | `fas/reversal_handler.ex` · `incremental_handler.ex` · `completion_handler.ex` (FAS-P6) | TRAM hooks append lifecycle events after each handler succeeds |
| Clearing file ingest | `trams/ipm_pipeline.ex` (Broadway) · `trams/mastercard_ipm.ex` · `trams/visa_base_ii.ex` · `trams_clearing_records` | TRAM adds the **matching engine** these were built for (`matched_auth_id` was never populated by anything) |
| GL posting | `cms/internal_gl_poster.ex` · `cms_ledger_entries` · `fas/settlement_posting_adapter.ex` (FAS-P4/P5) | TRAM posting cycle uses the SAME idempotency key convention (ADR-T3) so no double-posting is possible |
| Disputes | `dps/dispute.ex` (`dps_disputes`, full state machine, provisional credit, Oban deadlines) | Stays in DPS; TRAM links via `trams_transaction_id` and mirrors lifecycle events (ADR-T5) |
| Balance-level statements | `cms/statement_generator.ex` (interest, min payment) | TRAM adds transaction-level statement **lines** feeding it |
| Observability plumbing | FAS-P8 telemetry + admin LiveView shell | TRAM inquiry/exception views reuse the same admin UI pattern |

**Latent bug found during analysis:** `IpmPipeline.handle_batch/4` inserts
clearing records with `conflict_target: :idempotency_key`, but neither the
`trams_clearing_records` migration nor `ClearingRecord` schema has that column
— it would raise at runtime on the first IPM file. Fixed in TRAM-P1 migration.

---

## TRAM-P1 — Core Transaction Repository

**Goal:** The event-sourced transaction aggregate: master row, append-only
event log, external-identifier table, state machine, event store API.

| # | Task | File(s) | Status | Completed |
|---|------|---------|--------|-----------|
| 1A | Migration — `trams_transactions`, `trams_transaction_events` (append-only, unique (transaction_id, seq)), `trams_transaction_identifiers`, `trams_adjustments`, `trams_maintenance_actions`, `trams_statement_lines`; fix `trams_clearing_records` (add `idempotency_key` + unique index, `matched_transaction_id`); add `trams_transaction_id` to `dps_disputes` | migration `20260703000001` | ✅ Done | 2026-07-03 |
| 1B | `Transaction` schema — aggregate root; `fas_authorization_id` unique (idempotent FAS feed); merchant fields inline (ADR-T4); state projection column (ADR-T1) | `trams/transaction.ex` | ✅ Done | 2026-07-03 |
| 1C | `TransactionEvent` + `TransactionIdentifier` schemas | `trams/transaction_event.ex` · `trams/transaction_identifier.ex` | ✅ Done | 2026-07-03 |
| 1D | `StateMachine` — 14 lifecycle states per spec Section 7.2; transition table; event_type → state mapping; stateless (audit-only) events; idempotent self-transitions | `trams/state_machine.ex` | ✅ Done | 2026-07-03 |
| 1E | `EventStore` — `append/4` (row-lock, next seq, validate transition, insert event + update state projection in one DB txn), `open/3` (idempotent on fas_authorization_id), `history/1` | `trams/event_store.ex` | ✅ Done | 2026-07-03 |
| 1F | `Adjustment`, `MaintenanceAction`, `StatementLine` schemas (commands come in P4/P5/P6) | `trams/adjustment.ex` · `trams/maintenance_action.ex` · `trams/statement_line.ex` | ✅ Done | 2026-07-03 |

**TRAM-P1 Progress: 6 / 6 complete ✅**

---

## TRAM-P2 — FAS → TRAM Feed (spec 10 §2.1)

**Goal:** Every FAS authorization outcome creates/advances a TRAM transaction.
All hooks are fail-safe (rescue → log) and run off the auth hot path.

| # | Task | File(s) | Status | Completed |
|---|------|---------|--------|-----------|
| 2A | `AuthConsumer` — `record_authorization/3` (create txn + `authorization_approved`/`authorization_declined` + identifiers), `record_reversal/2`, `record_incremental/4`, `record_completion/4`; every entry point wrapped fail-safe | `trams/auth_consumer.ex` | ✅ Done | 2026-07-03 |
| 2B | Hook standard auth path — call `record_authorization` inside FAS `persist_async` Task after auth record insert | `fas/authorization.ex` | ✅ Done | 2026-07-03 |
| 2C | Hook 0400 reversal — `record_reversal` after `do_reverse` succeeds | `fas/reversal_handler.ex` | ✅ Done | 2026-07-03 |
| 2D | Hook incremental — `record_incremental` after extend/trim succeeds | `fas/incremental_handler.ex` | ✅ Done | 2026-07-03 |
| 2E | Hook 0200 completion — `record_completion` after matched completion processed | `fas/completion_handler.ex` | ✅ Done | 2026-07-03 |

**TRAM-P2 Progress: 5 / 5 complete ✅**

---

## TRAM-P3 — Matching Engine & Posting Cycle (specs 10 §2.2–2.3, 09 §2.2)

**Goal:** Clearing records matched to authorizations via the identifier
hierarchy; matched+cleared transactions posted to the ledger.

| # | Task | File(s) | Status | Completed |
|---|------|---------|--------|-----------|
| 3A | Matching engine — hierarchy per spec §6.4: RRN+pan → auth_code+pan → pan+amount(±tolerance)+date-window (STAN dropped: clearing records don't carry it and it rolls over); identifier tiers ignore amount (tips/FX variance expected); tier-3 excludes auths already linked to a clearing; unmatched → `EXCEPTION` review queue; `run_unmatched_sweep/1` batch entry point. Tolerances configurable: `trams_match_amount_tolerance_pct` (20), `trams_match_date_window_days` (3) | `trams/matching_engine.ex` | ✅ Done | 2026-07-03 |
| 3B | Posting cycle worker — Oban `:clearing` queue, cron 22:30 (after 21:30 IPM ingest): runs matching sweep, then per CLEARED transaction posts via **`FAS.SettlementPostingAdapter.confirm_one/1`** (same code path + idempotency key as settlement_core HTTP confirm — ADR-T3 realized literally), appends `transaction_posted` → POSTED; syncs aggregate when settlement_core posted first (ledger-key check); skips fraud-FLAGged; per-txn rescue isolation | `trams/oban/posting_cycle_job.ex` · `config/config.exs` (cron) | ✅ Done | 2026-07-03 |
| 3C | Matching wired into IpmPipeline — post-commit (avoids nesting matching transactions inside the batch insert), re-fetch by `idempotency_key` (resolves the real row under `on_conflict: :nothing` redelivery), only UNMATCHED rows matched, per-record rescue | `trams/ipm_pipeline.ex` | ✅ Done | 2026-07-03 |

**TRAM-P3 Progress: 3 / 3 complete ✅**

**Verification (2026-07-03):** smoke-tested against `vmu_core_dev` — tier-1 RRN
match links auth + TRAM txn, `settlement_matched` → CLEARED with
`settled_amount`/`clearing_id`/clearing-identifier row recorded, orphan record →
EXCEPTION, re-match is a no-op. Fixed during test: `EventStore.json_safe_value/1`
crashed on `Date` structs in event payloads (structs now handled before the
generic map clause).

**Addendum (2026-07-04) — real-time sync on the settlement_core path:**
`SettlementPostingAdapter.confirm_one/1` now calls
`AuthConsumer.record_settlement_confirmation/3` after the posting transaction
commits (and on the already-posted branch, covering a crash-between-post-and-sync
retry). The hook walks the aggregate AUTHORIZED → CLEARED → POSTED as needed —
previously aggregates on the HTTP confirm path lagged until the nightly posting
cycle's ledger-key check. Fail-safe (a TRAM error never fails the confirm);
idempotent against the posting cycle racing it. Smoke-tested 4/4: confirm on an
AUTHORIZED aggregate produced POSTED + settled_amount + hold clear + GL entry
with a 3-event timeline; re-confirm added no events. | `fas/settlement_posting_adapter.ex` · `trams/auth_consumer.ex`

---

## TRAM-P4 — Reversals, Adjustments & Auto-Expiry (spec 06)

| # | Task | File(s) | Status | Completed |
|---|------|---------|--------|-----------|
| 4A | Auth auto-expiry sweep — Oban cron 23:00 (after posting cycle): holds past `expires_at` + grace (`trams_auth_expiry_grace_hours`, default 24) → row-locked re-check, release hold (`reversal_at`), credit OTB via `ASC.credit_open_to_buy/2` (not `reverse/3` — the STAN-keyed ASC entry is gone after multi-day holds), append `authorization_expired` → REVERSED. Skips holds whose aggregate is CLEARED/POSTED or whose settlement ledger key exists (clearing in flight owns the hold). Complements `FAS.HoldAgingMonitor` (alerts) — this job acts | `trams/oban/auth_expiry_sweep_job.ex` · `config/config.exs` (cron) | ✅ Done | 2026-07-03 |
| 4B | Adjustment command — POSTED/STATEMENTED/PAID only; zero-delta rejected; above `trams_adjustment_approval_threshold` (default 1000.00) parks PENDING_APPROVAL with maker≠checker enforcement; posts GL via `InternalGlPoster` key `"adjustment:<id>"` (DEBIT → DR 1001/CR 2001, CREDIT → DR 2001/CR 1001), updates `settled_amount`, appends `adjustment_applied` (audit-only); `pending/1` feeds the ops approval queue | `trams/adjustment_command.ex` | ✅ Done | 2026-07-03 |

**TRAM-P4 Progress: 2 / 2 complete ✅**

**Verification (2026-07-03):** smoke-tested against `vmu_core_dev` — non-POSTED
and zero-delta requests rejected; below-threshold CREDIT adjustment posted
immediately (GL 2001/1001, settled_amount updated); above-threshold parked,
maker self-approval blocked, checker approval posted DEBIT; 2× `adjustment_applied`
in history with state unchanged; expiry sweep released a 3-day-overdue hold and
moved the aggregate to REVERSED; sweep re-run is a no-op.

---

## TRAM-P5 — Statement Lines & Dispute Bridge (specs 07, 08)

| # | Task | File(s) | Status | Completed |
|---|------|---------|--------|-----------|
| 5A | Statement extraction — per account+cutoff: POSTED not yet statemented → `trams_statement_lines` (idempotent via unique key + `on_conflict: :nothing`), append `statement_generated` → STATEMENTED; late POSTED adjustments on earlier-statemented transactions → summed ADJUSTMENT_CREDIT/DEBIT lines on the CURRENT cycle (`adjustment_flag: true`), never edits to past statements; RRN reference prefers clearing-sourced identifier; `lines_for_cycle/2` = pure-read reprint | `trams/statement_extraction.ex` | ✅ Done | 2026-07-03 |
| 5B | Wired into CMS EOD — extraction runs before `StatementGenerator.generate` (same cutoff for lines and balance snapshot), fail-safe wrapped so line extraction can never block the balance-level statement | `cms/eod/generate_statement_job.ex` | ✅ Done | 2026-07-03 |
| 5C | Dispute bridge — `file_dispute/2` validates dispute window (`trams_dispute_window_days`, default 120) + POSTED/STATEMENTED/PAID state, delegates to `DPS.Dispute.file/1` (provisional credit + deadlines untouched), links `trams_transaction_id`, appends `dispute_created` → DISPUTED; `notify_transition/1` (called post-commit from `DPS.Dispute.transition/2`, fail-safe) mirrors: CHARGEBACK_FILED→`chargeback_created`, CLOSED_WIN/CANCELLED→`dispute_resolved`, CLOSED_LOSE→`chargeback_reversed`, intermediate stages→`dispute_stage_changed` (new audit-only event) | `trams/dispute_bridge.ex` · `dps/dispute.ex` · `trams/state_machine.ex` | ✅ Done | 2026-07-03 |

**TRAM-P5 Progress: 3 / 3 complete ✅**

**Verification (2026-07-03):** smoke-tested against `vmu_core_dev` — extraction
statements 2 txns with correct line content (RRN, merchant, amount), re-run is a
0-line no-op, late adjustment produced one ADJUSTMENT_CREDIT 20.00 line on the
next cycle, full dispute round-trip (file → provisional credit → chargeback →
representment stage → CLOSED_LOSE) drove the aggregate DISPUTED → CHARGEBACKED →
RESOLVED with an 8-event timeline, expired-window intake rejected.

**Two pre-existing DPS bugs found and fixed during verification:**
1. `cms_ledger_entries.transaction_code` was varchar(10) but `"DISPUTE_CREDIT"`
   is 14 chars — every provisional-credit post crashed with
   `string_data_right_truncation`. Widened to 20 (migration `20260703000002`).
2. `DPS.Dispute.deadline_dt/1` used `DateTime.new!(date, time, "UTC")` — raises
   `:utc_only_time_zone_database` (the built-in zone is `"Etc/UTC"`) — every
   dispute filing crashed at deadline scheduling. Fixed in `dps/dispute.ex`.
   Disputes had never been filed end-to-end against a real database before.

---

## TRAM-P6 — Inquiry, Maintenance & Batch Ops (specs 04, 05, 09, 11)

| # | Task | File(s) | Status | Completed |
|---|------|---------|--------|-----------|
| 6A | `TransactionSearch` — filters: account_id / full-PAN (tokenized at query time; "last-4" search impossible by design — pan_token is SHA-256) / RRN / STAN / auth_code (via identifiers subquery) / merchant (ILIKE name or exact ID) / amount range / date range / state; paginated with total | `trams/transaction_search.ex` | ✅ Done | 2026-07-03 |
| 6B | `TransactionView.detail/1` — full aggregate assembly: auth record + identifiers + clearing + ordered event timeline + adjustments + maintenance history + statement lines + dispute case; cardholder-facing status mapping (spec 04 §2.4 — AUTHORIZED→"Pending" etc.) | `trams/transaction_view.ex` | ✅ Done | 2026-07-03 |
| 6C | Admin LiveView — search form (RRN/STAN/auth-code/merchant/state/date-range), results table with statement/clearing flags, detail drawer (identifiers, event timeline, related records); wired into `/visionplus/admin/tram_inquiry` sidebar | `live/admin/tram_inquiry_component.ex` · `admin_live.ex` | ✅ Done | 2026-07-03 |
| 6D | Maintenance commands — DESCRIPTIVE_CORRECTION + FLAG apply immediately (blocking is the safe direction); LINKAGE_CORRECTION / STATUS_OVERRIDE / REDRIVE require maker≠checker approval; before/after values captured; amount changes rejected (belong to AdjustmentCommand); FLAG lift via `reject/2`; REDRIVE re-enqueues PostingCycleJob; every application appends `maintenance_applied` | `trams/maintenance_command.ex` | ✅ Done | 2026-07-03 |
| 6E | Reconciliation — three-way (TRAM POSTED vs MATCHED clearing vs `settlement:*` ledger keys) counts + amounts; break lists: `posted_without_ledger` (posting event without money movement), `matched_not_posted` (stuck in pipeline); open-exception count; `balanced?` flag | `trams/reconciliation.ex` | ✅ Done | 2026-07-03 |
| 6F | Archive sweep — weekly cron (Sun 02:00): close pass (REVERSED/DECLINED/PAID/RESOLVED idle > `trams_close_after_days` 90 → CLOSED) then archive pass (CLOSED > `trams_archive_retention_days` 365 → ARCHIVED, **never with an open dispute case**); TRAM telemetry (event-appended by type + match outcomes) merged into LiveDashboard | `trams/oban/archive_sweep_job.ex` · `trams/telemetry.ex` · `event_store.ex` · `matching_engine.ex` · `vmu_core_web/telemetry.ex` · `config/config.exs` | ✅ Done | 2026-07-03 |

**TRAM-P6 Progress: 6 / 6 complete ✅**

**Verification (2026-07-03):** smoke-tested against `vmu_core_dev` (11/11) —
RRN/PAN/merchant/identifier searches with state filtering; detail assembly with
cardholder status mapping; descriptive correction applied immediately; status
override blocked for maker, applied by checker (state forced AUTHORIZED→CLEARED
with full audit); FLAG applied + lifted; amount-via-maintenance rejected; 3×
`maintenance_applied` audit events; reconciliation surfaced a genuine stale
`matched_not_posted` break in dev data; close pass CLOSED a 100-day-idle
REVERSED txn; archive pass ARCHIVED it after aging past retention.

---

## Overall Progress

| Phase | Description | Items | Done | Pending |
|-------|-------------|-------|------|---------|
| TRAM-P1 | Core Transaction Repository | 6 | 6 | 0 |
| TRAM-P2 | FAS → TRAM Feed | 5 | 5 | 0 |
| TRAM-P3 | Matching Engine & Posting Cycle | 3 | 3 | 0 |
| TRAM-P4 | Reversals, Adjustments & Auto-Expiry | 2 | 2 | 0 |
| TRAM-P5 | Statement Lines & Dispute Bridge | 3 | 3 | 0 |
| TRAM-P6 | Inquiry, Maintenance & Batch Ops | 6 | 6 | 0 |
| **TOTAL** | | **25** | **25** | **0** |

**Overall: 25 / 25 complete (100%) ✅ — all phases done 2026-07-03**

---

## ADR Notes

### ADR-T1: Pragmatic Event Sourcing
**Decision:** `trams_transaction_events` is the append-only audit source of
truth; `trams_transactions.state` is a **projection** updated in the same DB
transaction as each event append (row-locked, seq-ordered).
**Rationale:** Full replay-on-read CQRS is overkill for the query patterns
(inquiry, batch sweeps); a same-transaction projection gives the audit
guarantees of the spec (Section 7.3) with simple indexed reads. Regeneration
("what was true as of cutoff") remains possible by folding events up to a
timestamp.

### ADR-T2: FAS Remains Untouched as Decision Engine
**Decision:** TRAM references `fas_authorization_id`; it never duplicates
decision data (rc, risk score, decision_path stay in `fas_authorizations`).
TRAM hooks in FAS run inside the existing async persistence Task or a new
`Task.start`, wrapped fail-safe — a TRAM failure can never affect an
authorization response.

### ADR-T3: Shared GL Idempotency Key Convention
**Decision:** TRAM's posting cycle uses idempotency key
`"settlement:<approval_code>:<rrn>"` — identical to FAS-P4's
`SettlementPostingAdapter`.
**Rationale:** Two paths can trigger posting for the same transaction (the
settlement_core HTTP confirm path and TRAM's clearing-file posting cycle).
With the same key, whichever runs first wins and the other is a no-op
(`on_conflict: :nothing`), making double-posting structurally impossible.

### ADR-T4: No Merchant Master Table (Deferred)
**Decision:** `merchant_id` (DE42), `merchant_name` (DE43), `mcc` stored
inline on `trams_transactions`. The spec's normalized Merchant entity is
deferred until a merchant master data source exists on the issuer side.

### ADR-T5: Disputes Stay in DPS
**Decision:** `dps_disputes` keeps its state machine, provisional credit GL
posting, and Oban deadline enforcement. TRAM adds a `trams_transaction_id`
FK column and a `DisputeBridge` that mirrors dispute lifecycle events into
the TRAM event log so the transaction timeline is complete.

### ADR-T6: PubSub-less Feed (Direct Calls, Fail-Safe)
**Decision:** FAS→TRAM feed uses direct function calls inside async tasks,
not Phoenix PubSub, because both live in the same OTP app and the calls are
already off the hot path. The spec-recommended outbox pattern (10 §4) is
deferred to when TRAM events need durable cross-service delivery.

---

## Lifecycle State Map (implemented in `trams/state_machine.ex`)

```
INITIATED → AUTHORIZED → AUTH_MAINTENANCE ⟲ → CLEARED → POSTED → STATEMENTED → PAID
     └→ DECLINED              └→ REVERSED                   └────────┴──→ DISPUTED
                                                                            ├→ CHARGEBACKED → RESOLVED
                                                                            └→ RESOLVED
REVERSED / DECLINED / PAID / RESOLVED / CHARGEBACKED → CLOSED → ARCHIVED
```

Audit-only events (no state change): `adjustment_applied`,
`maintenance_applied`, `settlement_received`, `identifier_added`.

---

*This tracker is maintained manually. Update the Status column and Completed date after each task is merged.*
