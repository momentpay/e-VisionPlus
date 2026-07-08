# DPS — Gap Implementation Tracker

> Source: `DPS_Module_Requirements.md` gap analysis / open questions.
> Statuses: `✅ Done` · `🔄 In Progress` · `⬜ Pending`
> Last updated: 2026-07-08

**Note:** this tracker starts at DPS-P1 — it does not retroactively re-document DPS's
earlier build work (state machine, deadline enforcement, provisional credit, TRAM
linkage — built and smoke-tested during TRAM-P5, per `DPS_Module_Requirements.md` §5).
That history stays in the requirements doc's existing gap-analysis table. This tracker
covers new phases going forward, starting with configuration.

---

## DPS-P1 — Module Configuration Foundation ✅ (2026-07-08)

Resolves 3 of the 4 open questions in `DPS_Module_Requirements.md` §6 — network
connectivity mode, provisional credit window, and evidence storage were all answered
as "make it configurable" (and, for network connectivity, explicitly "both options" —
manual portal *and* API integration must coexist, selectable per network). Implemented
via the shared, reusable configuration framework rather than DPS-specific plumbing.
Full design and verification: `docs/shared/Module_Configuration_Framework.md`.
(Question 4 — completing the arbitration flow — is state-machine/GL feature work, not
a config key; not part of this phase, flagged for a future DPS phase.)

| # | Task | File(s) | Status |
|---|---|---|---|
| P1.1 | DPS config catalog — 4 keys: `network_connectivity_mode` (per-network manual/api), `provisional_credit_window_days`, `evidence_storage_backend` + `evidence_storage_config` (db/s3/azure_blob) | `lib/vmu_core/dps/config_catalog.ex` | ✅ |
| P1.2 | Registered in the shared `ModuleConfigCatalog` + rendered by the generic Module Configuration admin screen (built in CTA-P4, reused here — no DPS-specific UI code) | `lib/vmu_core/shared/module_config_catalog.ex`, `lib/vmu_core_web/live/admin/module_config_component.ex` | ✅ |

**Verification (2026-07-08):** covered by the shared framework's smoke test (default
fallback, cascade, validation, audit trail — see
`docs/shared/Module_Configuration_Framework.md` §7).

**Correction (2026-07-08, same day):** P1.1/P1.2 above only built the config *storage*
— the catalog keys existed and were editable, but no DPS business logic actually read
them yet (`network_connectivity_mode` and `evidence_storage_backend` still have
nothing downstream to consume them — see Follow-up below). This was caught and fixed
for `provisional_credit_window_days` specifically:

| # | Task | File(s) | Status |
|---|---|---|---|
| P1.3 | `VmuCore.DPS.Dispute` now computes `provisional_credit_deadline` (new field) from the account's `sys_id`/`bank_id`/`logo_id` via `ModuleConfigEngine.get("dps", "provisional_credit_window_days", ...)` at filing time, instead of the config sitting unused. Bug caught during wiring: first attempt incorrectly plugged this value into `TRAMS.DisputeBridge.check_dispute_window/1` (the *dispute-filing eligibility* window, FR-DPS-003, a distinct 120-day concept) — reverted before it shipped; that function is untouched and still reads `Application.get_env(:vmu_core, :trams_dispute_window_days, 120)` as before. | `lib/vmu_core/dps/dispute.ex`, migration `20260708000001_add_provisional_credit_deadline_to_dps_disputes.exs` | ✅ |

**Verification (2026-07-08):** live smoke test against a real account (full app boot,
Oban running): default window resolves to 10 days → `provisional_credit_deadline` =
filed_at + 10; wrote a bank-scope override to 5 days → next dispute's deadline
correctly shifted to filed_at + 5; reverted the override. Confirms the config value is
now load-bearing, not just stored.

**Still not wired (honest status):** `network_connectivity_mode` and
`evidence_storage_backend`/`evidence_storage_config` remain config-only — there is no
VROL/Mastercom API integration or manual-portal branch to select between, and no
evidence storage abstraction to point at db/s3/azure_blob. Wiring those requires
building the underlying capability first (see Follow-up), not just a config read.

## Follow-up (not yet started)

- Arbitration flow completion (§6 Q4) — PRE_ARB → ARBITRATION state transitions + GL
  entries for the full win/loss cycle.
- Reason-code reference table (FR-DPS-004), evidence store (FR-DPS-014), case notes/
  assignment (FR-DPS-015), network message integration (FR-DPS-020), ops UI (case
  list/detail/deadline monitor) — see `DPS_Module_Requirements.md` §5 gap analysis.

## Overall

| Phase | Items | Done |
|-------|-------|------|
| DPS-P1 Module Configuration | 3 | 3 |
| **TOTAL** | **3** | **3** |
