# DPS — Gap Implementation Tracker

> Source: `DPS_Module_Requirements.md` gap analysis / open questions.
> Statuses: `✅ Done` · `🔄 In Progress` · `⬜ Pending`
> Last updated: 2026-07-09

**Note:** this tracker starts at DPS-P1 — it does not retroactively re-document DPS's
earlier build work (state machine, deadline enforcement, provisional credit, TRAM
linkage — built and smoke-tested during TRAM-P5, per `DPS_Module_Requirements.md` §5).
That history stays in the requirements doc's existing gap-analysis table. This tracker
covers new phases going forward, starting with configuration.

---

## DPS-P5 — Ops UI ✅ (2026-07-23)

Builds the screen DPS-P1–P4 never had: case list + detail, a deadline
monitor, an evidence upload/list panel, a case-notes/assignment panel, and
reason-code reference-data admin. This was also this repo's **first-ever
LiveView test** (`test/vmu_core_web/live/admin/dps_component_test.exs`) and
surfaced a cluster of real, pre-existing bugs nothing had ever exercised
through a browser or a real FK-constrained insert before.

| # | Task | File(s) | Status |
|---|---|---|---|
| P5.1 | `VmuCoreWeb.Live.Admin.DpsComponent` — list (open/closed/per-status filters, pagination), detail (case summary, status transition, deadline monitor with overdue/due-soon/ok badges, assignment, case notes, evidence panel), reason-code CRUD, "File a New Dispute" form | `lib/vmu_core_web/live/admin/dps_component.ex` | ✅ |
| P5.2 | Real file upload (`allow_upload`/`live_file_input`) + a plain controller download route (`VmuCoreWeb.DpsEvidenceController`) gated by the same `dps`/`view` permission — a genuine round-trip through `VmuCore.DPS.Evidence`'s existing `attach/3`/`fetch_data/1`/`delete/2`, not a stub | `lib/vmu_core_web/controllers/dps_evidence_controller.ex`, `router.ex` | ✅ |
| P5.3 | Registered `"dps"` as a real admin module: `RolePermission.@modules`, a default-matrix grant per role (SUPERVISOR/RISK full; OPS/CS_AGENT view+create, no edit/approve; COMPLIANCE view-only), sidebar + routing in `AdminLive` | `lib/vmu_core/asm/role_permission.ex`, `lib/vmu_core_web/live/admin/admin_live.ex` | ✅ |

**6 real bugs found and fixed while building this** (all pre-existing —
DPS-P1–P4's own backend was never exercised through a real browser session,
a real file FK, or a real `Oban testing: :inline` test run before today):

1. **`Dispute.file/1`/`transition/2` returned stale structs.** Both hand-patched
   only specific fields (`status`, `network_ref`) onto the struct fetched
   *before* their own `Repo.update_all` writes — `provisional_credit_posted`
   (set by `post_provisional_credit/1`) and `closed_at` (set by `transition/2`
   itself) were correct in the database but never reflected in what the
   function returned to its caller. Fixed by re-fetching after all writes
   complete, rather than hand-patching. Confirmed via the pre-existing
   `DisputeLifecycleTest`, which had been asserting on these exact stale
   fields (see #4 below — that suite had never actually run to completion).
2. **`put_provisional_credit_deadline/1`/`maybe_file_with_network/3` crashed
   on any non-UUID `account_id`** (`Ecto.Query.CastError`) instead of
   falling through to their existing "account not found" handling — `:binary_id`
   casts leniently at the changeset level but not at query-dump time. Guarded
   with a `valid_uuid?/1` check before every `Repo.get`.
3. **`DeadlineJob.perform/1` never verified its own deadline had arrived** —
   it treated "the job ran" as proof "the deadline passed," which holds in
   production only because Oban's `scheduled_at` naturally delays real
   execution. Under this project's own `Oban testing: :inline` config, a
   freshly-filed dispute cascaded straight through CHARGEBACK_FILED to
   CLOSED_WIN in the same call. Same risk exists in production for any early
   retry. Fixed: re-verifies `Date.compare(Date.utc_today(), deadline)`
   before acting; skips (logged) instead of acting early.
4. **`test/vmu_core/dps/dispute_lifecycle_test.exs` — pre-existing, was never
   passing.** Used a plain fake string as `account_id`, but `dps_disputes.
   account_id` has a real FK to `cms_accounts`; every test in the file
   raised `Ecto.ChangeError` at insert. Not something this session broke —
   confirmed via `git log` this file has no history of ever inserting
   successfully. Fixed with a real `CMS.Account`/`Shared.Customer` fixture
   (same pattern now shared with `DpsComponentTest`).
5. **The test DB (`vmu_core_test`) carries no seeded SYS/BANK/LOGO/BLOCK
   rows at all** — `priv/repo/seeds.exs` only ever populates the dev DB.
   Both DPS test files now build their own minimal parameter hierarchy
   fixture inside the sandboxed transaction rather than depending on an
   external seed step.
6. **The Endpoint had no `secret_key_base` configured for `:test`** — only
   `dev.exs` set one. Every session/cookie-dependent test (i.e. any test of
   the authenticated admin console) failed identically with "cookie store
   expects conn.secret_key_base to be set," regardless of what the test did.
   This is very likely *why* no LiveView test existed anywhere in this repo
   before today. Added a distinct test-only value to `config/test.exs`.

Also added `{:lazy_html, ">= 0.1.0", only: :test}` — `phoenix_live_view`
1.1's test helpers require it directly; the pre-existing `floki` transitive
dependency wasn't sufficient on its own.

**Verification (2026-07-23) — 11/11 tests passing** (`dps_component_test.exs`
+ the now-fixed `dispute_lifecycle_test.exs`), real Postgres via Sandbox, no
mocking: filed a dispute through the live form and confirmed the real row;
deadline badges render overdue/ok correctly; assign/note/transition all
persist and are reflected on reload; a real file upload → real `DbStore`
row → real HTTP download round-trip (byte-identical) → real delete; reason-code
create; CS_AGENT role gating (sees "+ File Dispute," does not see
edit-only controls — this caught a real gap where the transition form
wasn't `:if`-gated in the template at all, only in the event handler).
Confirmed via isolation runs that 10 pre-existing failures in unrelated
files (`COL.WriteOffRecoveryTest`, `CMS.InterestIntegrationTest`,
`FAS.AuthorizationIntegrationTest`) and a pre-existing compile error in
`test/vmu_core/lms/points_lifecycle_test.exs` are untouched by this work —
same class of "verification was always done via live scripts, not `mix
test`" gap found repeatedly elsewhere this session, flagged but out of
scope here.

**Not built in this phase:** real S3/Azure evidence backends and real
VROL/Mastercom network integration remain stubs (DPS-P3's own scope,
unchanged); no i18n; no bulk/export actions on the case list.

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

## DPS-P2 — Arbitration Flow Completion (win/loss GL cycle) ✅ (2026-07-08)

Resolves §6 open question 4 ("complete the flow") and the FR-010b/FR-019 gap analysis
rows. The dispute state machine already accepted PRE_ARB → ARBITRATION →
CLOSED_WIN/CLOSED_LOSE transitions with no guard preventing them — the real gap was
financial, not state-machine: cases closed with no GL resolution beyond the
provisional credit posted at filing, which then sat on the books indefinitely
regardless of outcome.

| # | Task | File(s) | Status |
|---|---|---|---|
| P2.1 | `post_resolution_gl/1`, called from `Dispute.transition/2` on every status change: `CLOSED_WIN` posts a scheme-recovery entry (DR 3002 new "scheme recovery clearing" account / CR 3001, clearing the Disputed Receivable with no customer-balance impact — the cardholder keeps the credit); `CLOSED_LOSE`/`CANCELLED` post a reversal entry (DR 1001 / CR 3001, the exact mirror of the original provisional-credit entry, re-debiting the cardholder) and reset `provisional_credit_posted` to `false`. Only fires when a credit was actually posted (guards on `provisional_credit_posted: true`); a repeat transition to the same closed status is a safe no-op (the flag is already `false`, and `InternalGlPoster`'s idempotency key would reject a duplicate anyway). | `lib/vmu_core/dps/dispute.ex` | ✅ |
| P2.2 | Registered the two new transaction codes (`DISPUTE_REVERSAL`, `DISPUTE_RECOVERY`) in `LedgerEntry`'s changeset inclusion list — caught during verification: the GL post was silently rejected (`transaction_code: is invalid`) before this fix. | `lib/vmu_core/cms/ledger_entry.ex` | ✅ |
| P2.3 | **Bug found + fixed during verification:** `post_provisional_credit/1` set `provisional_credit_posted: true` unconditionally, regardless of whether the GL post actually succeeded — a failed post would still flag the dispute as credited, so a later `CLOSED_LOSE` would incorrectly attempt to reverse a credit that was never posted. Now only sets the flag on `{:ok, _}` from `InternalGlPoster.post/1`. | `lib/vmu_core/dps/dispute.ex` | ✅ |

**Verification (2026-07-08):** live end-to-end test against a real account, filing 3
disputes and resolving each differently: `CLOSED_WIN` posted the DR 3002/CR 3001
recovery entry and left `provisional_credit_posted` unchanged (`true` — customer
correctly keeps the credit); `CLOSED_LOSE` posted the DR 1001/CR 3001 reversal and
flipped `provisional_credit_posted` to `false`; `CANCELLED` behaved identically to
`CLOSED_LOSE`; a second `transition/2` call to `CLOSED_LOSE` on the same dispute
completed without error and without double-posting (idempotency held). Test data
cleaned up after.

## DPS-P3 — Evidence Store + Network Integration Scaffolding ✅ (2026-07-09)

Wires `dps.evidence_storage_backend`/`evidence_storage_config` (FR-DPS-014, "Not
found" in the gap analysis) and `dps.network_connectivity_mode` (FR-DPS-020, "Manual
transitions only today") into real, working code for the first time — both were
config-only with zero consumer since DPS-P1. Scope confirmed with user: code-only,
verified via scripts — no DPS ops UI (case list/detail is a separate, larger,
already-tracked Roadmap 6.9–6.12 item).

**Honest split of what's real vs. stubbed** (no cloud SDK dependency or scheme API
credentials exist in this project — adding either was explicitly out of scope, so
those paths are scaffolded, not faked, matching `VmuCore.FAS.HSM.ProductionHSM`'s
existing stub pattern):

| # | Task | File(s) | Status |
|---|---|---|---|
| P3.1 | `dps_dispute_evidence` table + `VmuCore.DPS.DisputeEvidence` schema — one row per uploaded document, linked to a dispute; `backend` recorded per-row (not just per-bank-config) so evidence stays retrievable if a bank's backend choice changes later | migration `20260709000001_create_dps_dispute_evidence.exs`, `lib/vmu_core/dps/dispute_evidence.ex` | ✅ |
| P3.2 | `VmuCore.DPS.EvidenceStore` behaviour (mirrors `VmuCore.FAS.HSM`'s shape) + 3 adapters: `DbStore` — **real**, bytes live in the row itself; `S3Store`/`AzureBlobStore` — **stubs**, `{:error, :not_implemented}` with moduledocs describing exactly what a real integration needs (dependency, config, object-key convention) | `lib/vmu_core/dps/evidence_store.ex`, `lib/vmu_core/dps/evidence_store/{db_store,s3_store,azure_blob_store}.ex` | ✅ |
| P3.3 | `VmuCore.DPS.Evidence` context — `attach/3`/`list/1`/`fetch_data/1`/`delete/2`, resolving the dispute's bank/logo scope, dispatching to the configured backend, auditing via the existing `AuditLog` sink. Never inserts a row on a storage failure. | `lib/vmu_core/dps/evidence.ex` | ✅ |
| P3.4 | `VmuCore.DPS.NetworkAdapter` behaviour + `for_network/3` dispatch (per-network, since `network_connectivity_mode` is a map, not one global mode; normalizes `Dispute.network`'s short codes `"VI"/"MC"` against the config's full names `"VISA"/"MASTERCARD"`) + 3 adapters: `Manual` — **real**, formalizes today's actual manual-portal process; `Vrol`/`Mastercom` — **stubs** | `lib/vmu_core/dps/network_adapter.ex`, `lib/vmu_core/dps/network_adapter/{manual,vrol,mastercom}.ex` | ✅ |
| P3.5 | Wired into `Dispute.transition/2`: transitioning to `CHARGEBACK_FILED` now calls the configured network adapter and folds a returned `network_ref` into the same update — never blocks/fails the transition on an adapter error (external-system-optional, same posture as `post_resolution_gl/1`) | `lib/vmu_core/dps/dispute.ex` | ✅ |

**Verification (2026-07-09):** live end-to-end script against a real account: attached
evidence with the default `db` backend, confirmed the row persisted and
`fetch_data/1` returned byte-identical data; switched the bank's backend to `s3`,
confirmed a clean `{:error, :not_implemented}` with **no phantom row inserted**
(evidence count unchanged); deleted the `db`-backend evidence, confirmed it's gone;
transitioned a real dispute to `CHARGEBACK_FILED` under the default `manual` mode,
confirmed success with `network_ref` still `nil` (ops fills it in later); switched
`VISA` to `api` mode and filed a second dispute, confirmed the `Vrol` stub's
`{:error, :not_implemented}` did **not** block the status transition. All test
config/data reverted after.

## DPS-P4 — Reason-Code Reference Table + Case Notes/Assignment ✅ (2026-07-09)

Resolves FR-DPS-004 (reason codes were a free string with no reference data) and
FR-DPS-015 (case notes/investigator assignment — "Not found"). Per
`docs/tram/08_chargebacks_disputes.md` §4: reason codes and their dispute windows
differ by network and change periodically via network rule updates — modeled as
admin-editable reference data, not a hardcoded enum, so updates never require a code
deployment.

| # | Task | File(s) | Status |
|---|---|---|---|
| P4.1 | `dps_reason_codes` table + `VmuCore.DPS.ReasonCode` schema (network + code + description + category + dispute window + evidence-required list) — 9 illustrative Visa/Mastercard rows seeded (validate against current network operating regulations before go-live, per the source spec's own caveat) | migration `20260709000002_create_dps_reason_codes.exs`, `lib/vmu_core/dps/reason_code.ex`, `priv/repo/seed_dps_reason_codes.exs` | ✅ |
| P4.2 | `TRAMS.DisputeBridge.check_dispute_window/3` now looks up the dispute window per network+reason-code via `ReasonCode.window_days/3`, falling back to the historical static `Application.get_env(:vmu_core, :trams_dispute_window_days, 120)` only when a code isn't in the reference table | `lib/vmu_core/trams/dispute_bridge.ex` | ✅ |
| P4.3 | `Dispute.assigned_to` field (current investigator) + `dps_dispute_notes` table/`VmuCore.DPS.DisputeNote` schema (append-only running note log) + `VmuCore.DPS.CaseNotes` context (`add_note/3`, `list_notes/1`, `assign/3`), audited via the existing `AuditLog` sink | migration `20260709000003_add_case_management_to_dps.exs`, `lib/vmu_core/dps/dispute_note.ex`, `lib/vmu_core/dps/case_notes.ex`, `lib/vmu_core/dps/dispute.ex` | ✅ |
| P4.4 | **Bug caught before shipping:** `CaseNotes.assign/3` initially reused `Dispute.changeset/2` for the `assigned_to` update — but that changeset also recomputes `chargeback_deadline`/`provisional_credit_deadline` from *current* config on every call (necessary at filing time), which would have silently drifted a dispute's stored deadlines on an unrelated assignment change if config had shifted since filing. Fixed to use a narrow `Repo.update_all`, the same pattern `Dispute.transition/2` already uses for status updates. | `lib/vmu_core/dps/case_notes.ex` | ✅ |

**Verification (2026-07-09):** live end-to-end script against a real account:
confirmed `ReasonCode.window_days/3` returns the seeded per-code value (90 days for
Visa 11.3) vs. the 120-day default for other codes and the fallback for unknown
codes; filed a dispute against a 100-day-old transaction — correctly **rejected**
under reason 11.3's 90-day window and correctly **accepted** under reason 10.4's
120-day window on the *same* transaction, proving the per-code lookup is genuinely
driving the decision, not just a global constant; added two case notes and confirmed
newest-first ordering; assigned an investigator and confirmed
`provisional_credit_deadline` was unchanged after (confirming the P4.4 fix holds).
Test data cleaned up after.

## Follow-up (not yet started)

- Real S3/Azure evidence backends (need a cloud SDK dependency — not added this
  session), real VROL/Mastercom API integration (need vendor credentials — not
  available this session), ops UI (case list/detail/deadline monitor, plus an
  evidence upload/list panel and a case-notes/assignment panel once it exists) —
  see `DPS_Module_Requirements.md` §5 gap analysis.

## Overall

| Phase | Items | Done |
|-------|-------|------|
| DPS-P1 Module Configuration | 3 | 3 |
| DPS-P2 Arbitration Flow Completion | 3 | 3 |
| DPS-P3 Evidence Store + Network Integration Scaffolding | 5 | 5 |
| DPS-P4 Reason-Code Table + Case Notes/Assignment | 4 | 4 |
| **TOTAL** | **15** | **15** |
