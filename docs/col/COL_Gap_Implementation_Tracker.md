# COL — Gap Implementation Tracker

> Source: `COL_Module_Requirements.md` gap analysis / open questions.
> Statuses: `✅ Done` · `🔄 In Progress` · `⬜ Pending`
> Last updated: 2026-07-24

---

## Re-port note (2026-07-24)

Everything below (P1-P9) was built and verified once on 2026-07-10, but was
**never committed to git** in standalone vmu_core — a later `"M2: extract
vmu_col into Avenza umbrella"` commit moved it into `Avenza/apps/vmu_col`,
and it was never carried back after the platform-of-record reversal to
standalone vmu_core (2026-07-23, see
`[[project_platform_of_record_vmu_core]]`). Found live while starting Way4
parity plan Phase 0 item 4: `lib/vmu_core/col/` on disk had only 4 files
(`collection_case.ex`/`collection_queue_job.ex`/`dunning_job.ex`/
`write_off_processor.ex` — the pre-P1 baseline) even though this doc
describes P1-P9 as done and the DB migrations were still applied.

Confirmed the Avenza copy was intact and re-ported all 18 `lib/vmu_core/col/`
files + `ColComponent` verbatim (self-contained, never diverged since
extraction), then hand-merged the cross-cutting wiring points that vmu_core
had independently moved on since (`age_buckets_job.ex`/
`accrue_interest_job.ex` for COL-P3/P7/P9 hooks, `payment_intake.ex`'s
`"agency"` channel for P8, `module_config_catalog.ex`/`role_permission.ex`/
`admin_live.ex` module registration, `approval_inbox_component.ex`'s 3 COL
sections) rather than overwriting them, since those files had already grown
this session's own FR-057/058/067/070 CMS work.

**One real adaptation, not just a copy**: Avenza's `col_component.ex` and
`approval_inbox_component.ex` had since been upgraded to a `WalletWeb.
Authorization.Policy`/`current_claims` authorization scheme that doesn't
exist in standalone vmu_core — rewritten back to this app's real
`VmuCore.ASM.Authz.can?/3` pattern (matching every other admin component
here) before it would even compile. Also dropped an Avenza-only "HCS
Facility Limit Changes" section from `approval_inbox_component.ex` (a
different, unrelated new-card-products feature that piggybacked onto the
same file over there — out of scope for a COL port).

8/8 new `col_component_test.exs` tests (list/detail, log-call, agency
place+recall, workout request, settlement request, agency-files generate
+import, CS_AGENT view-only gate) — this repo's admin LiveView test suites
never survived the M2 extraction either, so this is fresh coverage, not a
restoration. Full CMS/FAS/COL/admin regression run before and after showed
the exact same pre-existing failures (10, unrelated to this port — 4 in
this doc's own already-orphaned `WriteOffRecoveryTest`, which references
`VmuCore.COL.QueueRouter`/`CollectionAccount`, modules that never existed in
either the pre-P1 baseline or the real P1-P9 build; plus the already-known
`InterestIntegrationTest`/`AuthorizationIntegrationTest` breakage).

---

## COL-P1 — Module Configuration Foundation ✅ (2026-07-10)

Resolves `COL_Module_Requirements.md` §6's four open questions as configurable
settings via the shared, reusable `VmuCore.Shared.ModuleConfigCatalog` framework
(see `docs/shared/Module_Configuration_Framework.md`) — the same pattern used for
CTA/ASM/DPS. Config storage only, mirroring how those modules started (DPS-P1);
scope confirmed with user before implementing.

**Correction made before implementing, not after:** the §6 answer's pasted
`bucket_strategy_matrix` example (`[penalty_fees, past_due_interest,
current_interest, principal]`) is a payment-allocation waterfall, not FR-COL-011's
collection treatment-step engine (ordered SMS/call/letter steps by DPD day). Confirmed
with user to implement the FR-011 meaning instead — a per-segment ordered list of
`{day, step}` treatment steps — since the pasted waterfall example is a different
concern (payment posting) that would belong to a CMS catalog, not COL's.

| # | Task | File(s) | Status |
|---|---|---|---|
| P1.1 | COL config catalog — 9 keys across the 4 §6 areas: `bucket_strategy_matrix` (FR-011, redefined per above), `agency_config` (FR-018/019), `writeoff_dpd_threshold` / `writeoff_approval_matrix` / `writeoff_ifrs9_stage` (FR-020, split from the pasted nested-map into 3 scalar/list/enum keys — matches the per-bank scope the ModuleConfig framework already provides, no need for a market-code map key), `contact_cap_sms_per_day` / `contact_cap_calls_per_week` / `contact_cap_emails_per_week` / `contact_cooloff_hours` (FR-013, split into scalar keys so the admin UI renders proper number inputs instead of a raw JSON textarea) | `lib/vmu_core/col/config_catalog.ex` | ✅ |
| P1.2 | Registered in the shared `ModuleConfigCatalog.all/0` — rendered by the existing generic Module Configuration admin screen automatically, no COL-specific UI code | `lib/vmu_core/shared/module_config_catalog.ex` | ✅ |

**Verification (2026-07-10):** `mix compile` clean (no new warnings). Live smoke test
(`iex`/`mix run` against the real dev DB): all 9 keys resolve to their catalog
defaults with no DB rows present (`writeoff_dpd_threshold` → 180,
`bucket_strategy_matrix` → the 8-step default ladder below); wrote a bank-scope
override (`writeoff_dpd_threshold` = 150 for `BANK1`), confirmed `BANK1` now
resolves to 150 while an unrelated `BANK2` still resolves to the default 180
(cascade + isolation both correct); an invalid `writeoff_ifrs9_stage` value
(`"Stage9"`) was rejected with `{:error, :invalid_value}`. Test rows deleted after.

**`bucket_strategy_matrix` default** (mirrors what `CollectionQueueJob`/`DunningJob`
already hardcode today, so wiring them later is a faithful swap, not a behavior
change):

```
default:
  - day 3,  sms
  - day 3,  email
  - day 30, letter
  - day 60, demand_letter
  - day 60, courier
  - day 90, legal_notice
  - day 90, registered_mail
  - day 90, agency_referral
```

**Still not wired (honest status, config-only for now):**

- `bucket_strategy_matrix` — `CollectionQueueJob.queue_for_dpd/1` and
  `DunningJob.notice_for_dpd/1`/`channels_for_dpd/1` still hardcode their ladders;
  neither reads this config yet.
- `agency_config` — no agency placement file-exchange code exists at all
  (`CollectionCase.assigned_to` is a free-text field only, FR-018/019 gap). Nothing
  to wire into.
- `contact_cap_*` — no contact-attempt history exists (FR-COL-005, "Not found" in
  the gap analysis), so there is nothing to count against these caps yet.
- `writeoff_dpd_threshold` — **more than "not wired": there is currently no
  automatic write-off trigger of any kind.** `WriteOffProcessor.write_off/1` exists
  and works when called directly, but nothing calls it. Confirmed while reading
  `CMS.EOD.AgeBucketsJob`: its DPD ladder (`@dpd_buckets [0, 30, 60, 90, 120]`) caps
  at 120 and never advances to 150/180, so accounts never even reach the DPD level
  this threshold describes today.
- `writeoff_approval_matrix` / `writeoff_ifrs9_stage` — same as above; no approval
  workflow or IFRS9 staging code exists to consume them.

## COL-P2 — Write-off Auto-trigger + Contact-attempt Tracking ✅ (2026-07-10)

Picks up the two candidates COL-P1 flagged as "NEXT UP." Both are real feature
builds, not config rewires — same posture as DPS-P2/P3.

**Correction made before implementing, not after:** `writeoff_approval_matrix`'s
default (`["risk_head"]`, from the pasted §6 answer) named a role that doesn't exist
in this system. The real ASM role taxonomy is `VmuCore.ASM.Operator.roles/0` —
`TELLER/CS_AGENT/OPS/SUPERVISOR/RISK/COMPLIANCE/ADMIN`. Fixed the catalog's
`default` to `["RISK"]` and `allowed` to the real role list (previously `nil`, so
garbage values would have validated successfully) before wiring anything to depend
on it.

| # | Task | File(s) | Status |
|---|---|---|---|
| P2.1 | `col_writeoff_requests` table + `VmuCore.COL.WriteOffRequest` schema — maker-checker parking row (PENDING_APPROVAL → APPROVED/REJECTED/POSTED), mirroring `TRAMS.Adjustment`'s shape | migration `20260710000001_...`, `lib/vmu_core/col/write_off_request.ex` | ✅ |
| P2.2 | `VmuCore.COL.WriteOffCommand` — `request/2` (idempotent: no-ops if a PENDING_APPROVAL/POSTED request already exists for the account), `approve/2` (maker ≠ checker, then approver's ASM role must be in `col.writeoff_approval_matrix` for the account's bank — ADMIN always qualifies, matching `Authz`'s short-circuit — before calling `WriteOffProcessor.write_off/1`), `reject/2`, `pending/1` | `lib/vmu_core/col/write_off_command.ex` | ✅ |
| P2.3 | `AgeBucketsJob`'s DPD ladder extended `[0,30,60,90,120] → [0,30,60,90,120,150,180]`; `next_bucket/1`'s fallback now caps at the ladder's last element instead of a hardcoded `120` — accounts can finally reach 150/180 DPD, which they never could before this phase | `lib/vmu_core/cms/eod/age_buckets_job.ex` | ✅ |
| P2.4 | `CollectionQueueJob` calls `WriteOffCommand.request/2` once `account.delinquency_bucket >= col.writeoff_dpd_threshold` (bank-scoped config read), after the existing case-upsert logic | `lib/vmu_core/col/collection_queue_job.ex` | ✅ |
| P2.5 | `col_contact_attempts` table (append-only, no `updated_at`) + `VmuCore.COL.ContactAttempt` schema | migration `20260710000002_...`, `lib/vmu_core/col/contact_attempt.ex` | ✅ |
| P2.6 | `VmuCore.COL.ContactHistory` — `record_attempt/3`, `record_call/3` (manual collector call-log entry point for FR-COL-005's "call outcomes" — no admin UI drives it yet, same honesty split as DPS-P3's stubbed adapters), `within_cap?/4` (rolling-window check: 24h for `contact_cap_sms_per_day`, 7d for the weekly call/email caps), `cooloff_ok?/3` (`contact_cooloff_hours` against the most recent attempt of any channel) | `lib/vmu_core/col/contact_history.ex` | ✅ |
| P2.7 | `DunningJob` checks `cooloff_ok?`/`within_cap?` per channel before dispatch (skips + logs a capped/cooling-off channel without blocking the others) and records every successful dispatch via `ContactHistory.record_attempt/3` | `lib/vmu_core/col/dunning_job.ex` | ✅ |
| P2.8 | `ApprovalInboxComponent` — added a third "COL Write-offs" section (`WriteOffCommand.pending/1`, `approve_writeoff`/`reject_writeoff` events), reusing the existing `approvals:view`/`approvals:approve` gate; role-mismatch surfaces a distinct notice naming the allowed roles | `lib/vmu_core_web/live/admin/approval_inbox_component.ex` | ✅ |

**Verification (2026-07-10):** `mix ecto.migrate` clean; `mix compile --force`
produced zero new warnings from any touched/new file. Live end-to-end script
against the real dev DB (test data cleaned up after):
- Created a DELINQUENT account at 180 DPD (credit_limit 1000, OTB 200). Ran
  `CollectionQueueJob.perform/1` directly — it opened the collection case AND
  parked a write-off request (`PENDING_APPROVAL`, dpd=180, amount=800.00,
  ifrs9_stage="Stage3" — all three read from config, not hardcoded). Ran it again —
  confirmed exactly one request row still exists (idempotency held).
- Approval as an `OPS` operator → `{:error, {:role_not_authorized, ["RISK"]}}`
  (correctly rejected — `OPS` is not in the default `writeoff_approval_matrix`).
  Approval as a `RISK` operator → `{:ok, request}` with `status: "POSTED"`; reloaded
  the account and confirmed `account_status: "WRITTEN_OFF"`, `open_to_buy: 0.00`
  (GL transaction actually committed — `begin`/`commit` observed in the query log,
  not just a status flip); collection case also flipped to `WRITTEN_OFF`.
- Second account at 30 DPD: `DunningJob.perform/1` dispatched and recorded both
  `sms` and `email` contact attempts. Set `contact_cap_sms_per_day` to 0 for the
  bank and ran again — sms count stayed at 1 (skipped) while email count grew to 2
  (its own cap, 2/week default, not yet hit) — confirms caps are evaluated
  independently per channel. Set `contact_cooloff_hours` to a large value and ran
  again — total attempts stayed at 3 (both channels skipped), confirming the
  cross-channel cool-off gate.

**Still not wired (honest status, unchanged from P1):** `bucket_strategy_matrix`
(`CollectionQueueJob`/`DunningJob` still hardcode their treatment ladders) and
`agency_config` (no agency placement file-exchange code exists) remain config-only.
`ContactHistory.record_call/3` has no admin UI to drive it from yet — a collector
cannot actually log a call outcome anywhere today, only via direct function call.

## COL-P3 — Wire `bucket_strategy_matrix` (FR-COL-011) ✅ (2026-07-10)

Turned out not to be a pure rewire — wiring surfaced a real, pre-existing dead-code
bug that a plain "swap constants for config reads" would have silently preserved.

**Bugs found + fixed before wiring, not after:**

1. **P1's `bucket_strategy_matrix` default was unusable.** Its `day` values (3, 30,
   60, 90) were copied literally from FR-011's illustrative text ("SMS day 3, call
   day 7..."), but `AgeBucketsJob`'s DPD ladder only ever produces
   `[0, 30, 60, 90, 120, 150, 180]` — there is no continuous day counter in this
   system. A "day 3" step could never match any real DPD value. Redefined the
   default to `{day, notice_type, channels}` entries aligned to the real ladder
   (30/60/90/120), matching exactly what `DunningJob` used to hardcode.
2. **COL handoff only ever fired at 120+ DPD.** `AgeBucketsJob` only enqueued
   `CollectionQueueJob` when `new_dpd >= 120`, and `CollectionQueueJob` only
   scheduled dunning when `delinquency_bucket >= 120`. This meant no collection
   case was ever opened and no dunning ever fired for 30/60/90 DPD accounts via the
   automatic EOD flow — the 30/60/90 branches in both jobs' now-removed hardcoded
   functions were unreachable dead code from day one, not just after this wiring.
   Fixed both gates to fire on any DPD bucket change past 0, matching FR-COL-001
   ("auto case creation on delinquency," not "on severe delinquency").

| # | Task | File(s) | Status |
|---|---|---|---|
| P3.1 | `bucket_strategy_matrix` default redefined (see bug #1) | `lib/vmu_core/col/config_catalog.ex` | ✅ |
| P3.2 | `AgeBucketsJob` hands off to COL on any bucket change `> 0`, not just `>= 120` (see bug #2) | `lib/vmu_core/cms/eod/age_buckets_job.ex` | ✅ |
| P3.3 | `CollectionQueueJob` always calls `schedule_dunning/2` (no more `>= 120` gate) — `queue_for_dpd/1` (FR-COL-003, queue segmentation) intentionally left hardcoded, a distinct concern from FR-011's treatment steps | `lib/vmu_core/col/collection_queue_job.ex` | ✅ |
| P3.4 | `DunningJob` replaced `notice_for_dpd/1`/`channels_for_dpd/1` with `step_for_dpd/2` — reads the account's logo-scoped `bucket_strategy_matrix`, picks the `"default"` segment's step with the largest `day <= dpd` (nil-safe: no dispatch if none match); switched channel representation from atoms to strings throughout (config-driven values should never be turned into atoms dynamically) | `lib/vmu_core/col/dunning_job.ex` | ✅ |

**Verification (2026-07-10):** `mix compile --force` clean, no new warnings. Live
script against the real dev DB: created an ACTIVE account with an unpaid minimum,
ran the actual `AgeBucketsJob.perform/1` — DPD advanced 0→30 **and** a real
`VmuCore.COL.CollectionQueueJob` row appeared in `oban_jobs` for that account
(confirmed via direct SQL against the job table — before this fix that job would
never have been enqueued at DPD 30). Then ran `DunningJob.perform/1` directly for
DPD 30/60/90/120/150/180 and confirmed channels dispatched exactly:
`30→[email,sms]`, `60→[email,letter]`, `90→[courier,letter]`,
`120/150/180→[courier,letter,registered_mail]` (the 120 entry correctly reused as
catch-all for 150/180, matching the old hardcoded behavior). Test data cleaned up
after, including the inserted `oban_jobs` rows.

## COL-P4 — Agency Placement + File Exchange (FR-COL-018/019) ✅ (2026-07-10)

New capability, not a rewire — `CollectionCase.assigned_to` was previously just a
free-text field with nothing behind it.

**Honest split of what's real vs. stubbed** (same posture as DPS-P3 — no
SFTP/vendor client exists in this project, and no vendor XML sample exists to
validate a real parser against):

| # | Task | File(s) | Status |
|---|---|---|---|
| P4.1 | `col_agency_placements` (placement lifecycle: PLACED/RECALLED/CLOSED) + `col_agency_activity` (one row per ingested file line) tables + schemas | migration `20260710000003_...`, `lib/vmu_core/col/agency_placement.ex`, `lib/vmu_core/col/agency_activity.ex` | ✅ |
| P4.2 | `VmuCore.COL.AgencyDesk.place/2` — validates the agency code exists in the account's bank-scoped `agency_config` (the "validation layer" the §6 answer asked for) before placing; sets case status `AGENCY`. `recall/2` reopens the case to `OPEN` (agency churn = recall, then `place/2` with a different agency) | `lib/vmu_core/col/agency_desk.ex` | ✅ |
| P4.3 | `generate_assignment_file/3` — **real** generation in all 3 formats (CSV/JSON/XML are all plain string-building, no vendor dependency needed for output). `deliver_assignment_file/3` — **stub**, logs what would be sent; no SFTP/email client exists in this project | `lib/vmu_core/col/agency_desk.ex` | ✅ |
| P4.4 | `import_activity_file/4` — **real** parsing for CSV/JSON; XML returns `{:error, :xml_not_implemented}` (no vendor sample to validate a real parser against). Malformed rows (missing account_id, invalid activity_type, missing amount on a PAYMENT) are rejected individually via `AgencyActivity.status = "REJECTED"`, never fail the whole batch | `lib/vmu_core/col/agency_desk.ex` | ✅ |
| P4.5 | Applying activities, all real: `PAYMENT` on a `WRITTEN_OFF` account → `CMS.ChargeOffRecovery.record_recovery/3` (real GL posting, reusing COL-P1-era code); `PROMISE` → updates the real `CollectionCase.promise_date`/`promise_amount` fields + status `PROMISED`; `CONTACT` → `ContactHistory.record_call/3` (reusing COL-P2's contact-history capability — an agency's calls now show up in the same history as the bank's own dunning) | `lib/vmu_core/col/agency_desk.ex` | ✅ |
| P4.6 | Commission calculation (`flat_percent`/`fixed_fee`/`tiered_percent`, per `agency_config`'s `commission_type`/`commission_value`) computed and stored on each `PAYMENT` activity at processing time (not recomputed later from possibly-changed config); `commission_due/1` sums it per agency | `lib/vmu_core/col/agency_desk.ex` | ✅ |

**Flagged gap, not silently faked:** a `PAYMENT` activity against an account that
is *not yet* written off is recorded (`status: "APPLIED"`, commission still
calculated — the agency did collect it) but **not** routed through the full CMS
payment/balance-bucket waterfall (`RepaymentDistributor`) — `reject_reason` carries
a `"recorded_only"` note so this is visible on the row, not hidden. Wiring agency
payments into `PaymentIntake` is real future work, not done here.

**Verification (2026-07-10):** `mix ecto.migrate` + `mix compile --force` clean, no
new warnings. Live script against the real dev DB covering the full lifecycle:
attempted a placement before any `agency_config` existed → correctly got
`{:error, :agency_not_configured}`; configured `AGENCY1` (CSV, 10% flat commission);
placed a written-off account's case and a still-delinquent account's case with it
(both flipped to status `AGENCY`); generated a real CSV assignment file and
confirmed both accounts' rows were present with correct amounts; imported a 4-line
CSV activity file — result `{applied: 4, rejected: 0}`; confirmed the written-off
account's `PAYMENT` actually posted to GL (`ChargeOffRecovery.total_recovered/1`
returned 100.00) with a stored commission of 10.00 (10% of 100); confirmed the
not-written-off account's `PAYMENT` was recorded with the `"recorded_only"` flag and
its own 5.00 commission (10% of 50), *not* posted to GL; confirmed the `PROMISE`
activity flipped that case to `PROMISED` with the correct `promise_amount`/
`promise_date`; confirmed the `CONTACT` activity appears in
`ContactHistory.list_for_account/1` as a `"call"` with `attempted_by:
"AGENCY:AGENCY1"`; `commission_due("AGENCY1")` correctly summed to 15.00; a
follow-up batch with one bogus `activity_type` and one valid `CONTACT` row returned
`{applied: 1, rejected: 1}` — the bad row didn't take down the good one; finally
recalled the written-off account's placement and confirmed its case reopened to
`OPEN`. Test data cleaned up after.

## COL-P5 — Case List/Detail Admin UI ✅ (2026-07-10)

First real UI surface for COL — everything built in P1–P4 was verified only at the
code layer before this. Fills the exact gap flagged as "NEXT UP" after P4.

| # | Task | File(s) | Status |
|---|---|---|---|
| P5.1 | `VmuCoreWeb.Live.Admin.ColComponent` — filterable case list (status, account search) + detail view: account/customer context, write-off requests (read-only — approval stays in the existing Approval Inbox, one action surface not two), agency placement (place/recall via `AgencyDesk`), and contact history + a "log a call" form — the first UI for `ContactHistory.record_call/3` (FR-COL-005) | `lib/vmu_core_web/live/admin/col_component.ex` | ✅ |
| P5.2 | Registered `"col"` as a new admin module — added to `RolePermission.@modules`/`default_matrix` (SUPERVISOR/OPS/RISK: view+edit; CS_AGENT/COMPLIANCE: view-only — customer service can look up collection status, only ops/risk mutate it) and to `AdminLive`'s module map, sidebar, and dispatch — no new route needed, reuses the existing `/visionplus/admin/:module` hub-and-spoke | `lib/vmu_core/asm/role_permission.ex`, `lib/vmu_core_web/live/admin/admin_live.ex` | ✅ |

**Verification infrastructure added (this project had zero LiveView tests before
today):** hit a hard blocker — `Phoenix.LiveViewTest.live/1` requires the `lazy_html`
package unconditionally, which conflicted with the locked `elixir_make 0.10.0`.
Confirmed with user before adding: `{:lazy_html, ">= 0.1.0", only: :test}` +
`{:elixir_make, "~> 0.9", override: true}` in `mix.exs` (a genuine version
conflict, not a casual override), plus a `secret_key_base` for
`VmuCoreWeb.Endpoint` in `config/test.exs` (previously only configured for dev —
another gap this exposed). New test file:
`test/vmu_core_web/live/admin/col_component_test.exs` (4 tests, all passing).

**Bug caught by the test itself, fixed before shipping:** `handle_event("log_call",
_params, socket)` and `handle_event("place_with_agency", _params, socket)`
originally ignored the actual submitted form params and read from a separate
`call_form`/`place_form` assign that only `phx-change` updates — a direct form
submit (no prior change event) would silently log/place with stale or empty
values. Fixed both handlers to read the real submitted params directly
(`%{"outcome" => outcome, "notes" => notes}` / `%{"agency_code" => code}`), keeping
the assigns only for controlled-input redisplay.

**Verification (2026-07-10):** `mix ecto.migrate`/`mix compile --force` clean, no
new warnings anywhere. Full LiveView click-through test suite (real DB, no
mocking): list view renders a real seeded case; unauthenticated request redirects
to login; a SUPERVISOR views a case, logs a call (verified against the real
`col_contact_attempts` row afterward, not just the rendered HTML), configures an
agency and places the case with it (verified against the real
`col_agency_placements` row — status `PLACED`, correct agency code), then recalls
it (verified `status: "RECALLED"`); a CS_AGENT (view-only role) sees no log-call
form and a submit attempt is correctly blocked with no row written. All dev-DB
test data cleaned up after (customers/accounts/cases/contact
attempts/role-permission rows).

## COL-P6 — Queue Segmentation Wiring + Admin UI Growth ✅ (2026-07-10)

Picks up the smaller COL-P6 candidates: FR-003 queue wiring, agency file exchange
UI, and bulk case placement. User explicitly deferred the two larger candidates
(hardship/workout + settlement offers, and agency-payment→PaymentIntake wiring) to
their own phases (P9 and P8) rather than bundling them in here.

| # | Task | File(s) | Status |
|---|---|---|---|
| P6.1 | Extracted `VmuCore.COL.BucketStrategy.step_for_dpd/2` from `DunningJob` (COL-P3 had it private there) so both `DunningJob` (FR-011) and `CollectionQueueJob` (FR-003) read the *same* `bucket_strategy_matrix` step list instead of two separate hardcoded ladders. Added a `"queue"` field to each default step (`EARLY_COLLECTIONS`/`COLLECTIONS`/`SENIOR_COLLECTIONS`/`EXTERNAL_AGENCY` at 30/60/90/120 — unchanged from the old hardcoded values) | `lib/vmu_core/col/bucket_strategy.ex`, `lib/vmu_core/col/config_catalog.ex` | ✅ |
| P6.2 | `CollectionQueueJob.queue_for_dpd/1` now takes the account and reads `BucketStrategy.step_for_dpd/2`'s `"queue"` field, with a logged fallback to `EARLY_COLLECTIONS` if no step matches (shouldn't happen in practice) | `lib/vmu_core/col/collection_queue_job.ex` | ✅ |
| P6.3 | `ColComponent` — bulk case selection (checkboxes) + a bulk "place selected cases with agency" action bar, calling `AgencyDesk.place/2` per selected case and reporting a placed/failed tally | `lib/vmu_core_web/live/admin/col_component.ex` | ✅ |
| P6.4 | `ColComponent` — new "Agency Files" panel: pick a bank, generate an assignment file for a configured agency (displays the real generated content) and import an activity file by pasting its content, both calling the existing `AgencyDesk` functions for the first time from a UI. Pasted content rather than a real file-upload widget is a deliberate scope line — no `live_upload`/multipart wiring added; still fully functional for CSV/JSON pasted from an agency email or portal | `lib/vmu_core_web/live/admin/col_component.ex` | ✅ |

**Bug caught by the test suite itself while adding P6.3/P6.4's tests, fixed before
shipping:** `VmuCore.Shared.ModuleConfigEngine`'s cache is a global ETS table, not
part of the Sandbox DB transaction each test runs in — a `col.agency_config` write
in one test was still visible (stale) in the *next* test that happened to reuse the
same `sys_id`/`bank_id`, because ETS writes don't roll back with the DB
transaction. Fixed by giving each test in `col_component_test.exs` its own random
4-character `sys_id`/`bank_id` (with a matching `SysParameter`/`BankParameter`
pair) instead of one shared fixture value — a real testing gotcha worth
remembering for any future test that writes `ModuleConfigWriter` data.

**Verification (2026-07-10):** `mix compile --force` clean, no new warnings. Live
script against the real dev DB: created 4 accounts at DPD 30/60/90/120, ran
`CollectionQueueJob.perform/1` on each, confirmed `assigned_to` resolved to
`EARLY_COLLECTIONS`/`COLLECTIONS`/`SENIOR_COLLECTIONS`/`EXTERNAL_AGENCY`
respectively — config-driven, matching the old hardcoded behavior exactly. Full
LiveView test suite (now 6 tests, all passing): bulk-selected two cases and placed
both with an agency in one action (verified two real `AgencyPlacement` rows,
status `PLACED`); generated a real CSV assignment file from the Agency Files panel
(verified the seeded account's last-four appears in the actual generated content,
not just a canned string) and imported a pasted CSV activity line (verified
"Applied: 1 · Rejected: 0" against the real import result). Test data cleaned up
after (dev DB confirmed clean of residue).

## COL-P7 — Dispute Exclusion + Promise Auto-verification ✅ (2026-07-10)

Both new capabilities, resolving two real gaps from the original analysis:
FR-COL §2's DPS exclusion cross-link ("Not found") and FR-COL-006b (promise
kept/broken tracking existed only as static fields, with nothing verifying them).

| # | Task | File(s) | Status |
|---|---|---|---|
| P7.1 | `VmuCore.COL.DisputeExclusion.open_dispute?/1` — any DPS dispute on the account not in a terminal status (`CLOSED_WIN`/`CLOSED_LOSE`/`CANCELLED`). **Scope simplification, documented not hidden**: a hard per-account gate, not a per-transaction amount split against `CMS.BalanceBucket.disputed_amount` — COL has no transaction-level data model to do the latter | `lib/vmu_core/col/dispute_exclusion.ex` | ✅ |
| P7.2 | Wired into `WriteOffCommand.request/2` (refuses to park — `{:error, :open_dispute_exists}`, never even creates a pending row) and `AgencyDesk.place/2` (refuses to place, same error) | `lib/vmu_core/col/write_off_command.ex`, `lib/vmu_core/col/agency_desk.ex` | ✅ |
| P7.3 | `ColComponent`'s placement error handling surfaces a plain-language notice for `:open_dispute_exists` instead of a raw `inspect/1` dump | `lib/vmu_core_web/live/admin/col_component.ex` | ✅ |
| P7.4 | `col_collection_cases.promise_status` (PENDING/KEPT/BROKEN) + `promise_logged_at` (the verification baseline — deliberately its own timestamp, not reused from `updated_at`, since that column bumps on unrelated case changes too) | migration `20260710000004_...`, `lib/vmu_core/col/collection_case.ex` | ✅ |
| P7.5 | `VmuCore.COL.PromiseVerification.log_promise/3` (case → `PROMISED`, `promise_status` → `PENDING`) and `verify_case/2` (once the promise date arrives: sums `PAYMENT` ledger entries between `promise_logged_at` and `promise_date` — `>=` promise amount → `KEPT`, else `BROKEN`; case returns to `OPEN` either way so the normal collection cycle resumes). `AgencyDesk`'s existing PROMISE-activity handler refactored to call `log_promise/3` too — one code path for "a promise was made," whether logged by the bank's own collector or reported by an agency | `lib/vmu_core/col/promise_verification.ex`, `lib/vmu_core/col/agency_desk.ex` | ✅ |
| P7.6 | `AgeBucketsJob` calls `PromiseVerification.verify_case/2` once per day for any account with a `PROMISED` case — same daily cadence everything else in COL rides on, no new job/cron needed | `lib/vmu_core/cms/eod/age_buckets_job.ex` | ✅ |
| P7.7 | `ColComponent` — new "Log promise" form on the case detail view (amount + date), the first UI for logging a promise directly (previously only reachable via an agency's activity file) | `lib/vmu_core_web/live/admin/col_component.ex` | ✅ |

**Testability gotcha found and worked around, not silently patched over:** the
first LiveView test to ever call `VmuCore.DPS.Dispute.file/1` under `mix test`
revealed that this project's `config :vmu_core, Oban, testing: :inline` executes
a job **immediately on insert regardless of `scheduled_at`** — so
`schedule_chargeback_deadline/1`'s 120-day-out `DeadlineJob` ran synchronously
during filing and auto-cascaded the dispute through `FILE_CHARGEBACK` etc. all the
way to `CLOSED_WIN` before the test's own assertions ran. This is a pre-existing
characteristic of the test config (not something this session introduced), simply
never triggered before since no test previously exercised `Dispute.file/1`. Worked
around in the test by inserting the dispute row directly (bypassing the
scheduling side-effect) rather than changing the shared Oban test config, which
would have blast radius beyond COL.

**Verification (2026-07-10):** `mix ecto.migrate` (dev + test) / `mix compile
--force` clean, no new warnings. Live script against the real dev DB: filed a
real DPS dispute against a 180-DPD account — `open_dispute?` correctly `true`;
`WriteOffCommand.request/2` correctly refused with `{:error,
:open_dispute_exists}`; `AgencyDesk.place/2` on a second case, same account,
correctly refused the same way; closed the dispute to `CLOSED_WIN` directly —
`open_dispute?` flipped to `false` and a write-off request now parks normally.
Separately: logged a promise, backdated `promise_logged_at` to simulate a
promise made days ago now coming due — `verify_case/2` with no payment posted
correctly returned `{:ok, :broken}` (case → `OPEN`, `promise_status` →
`BROKEN`); re-logged the same promise, posted a real `PAYMENT` GL entry >= the
promised amount — `verify_case/2` correctly returned `{:ok, :kept}`. LiveView
test suite (now 8 tests, all passing) covers: logging a promise via the UI form
and both its pending/broken verification transitions, and the UI correctly
blocking agency placement on an account with an open dispute (with zero
`AgencyPlacement` rows created). Test data cleaned up after (dev DB confirmed
clean).

## COL-P8 — Agency Payments Routed Through PaymentIntake ✅ (2026-07-10)

Closes the flagged gap from P4.5: a `PAYMENT` activity against a *not-yet*
written-off account used to be recorded with a `"recorded_only"` note and never
actually posted anywhere. Turned out to be a small, low-risk change, not the
big rewrite the "higher blast radius" framing suggested — `CMS.PaymentIntake`
already had the exact routing this needed built in.

| # | Task | File(s) | Status |
|---|---|---|---|
| P8.1 | Added `"agency"` to `PaymentIntake.@valid_channels` — one line. Agency-remitted payments now go through the *same* validated entry point every other payment channel uses, subject to the *same* bank-level `payment_channels_enabled` gate (not bypassed just because the source is an agency) | `lib/vmu_core/cms/payment_intake.ex` | ✅ |
| P8.2 | `AgencyDesk.apply_activity/3`'s `PAYMENT` clause simplified from a hand-rolled `if account.account_status == "WRITTEN_OFF"` branch (real GL post for written-off / `"recorded_only"` no-op for everyone else) to a single call to `PaymentIntake.receive_payment/1` — which *already* internally routes `WRITTEN_OFF` accounts to `ChargeOffRecovery` (CMS-G4.3) and runs the full balance-bucket waterfall + GL + OTB restore for everyone else. One real payment pipeline, not two paths to maintain | `lib/vmu_core/col/agency_desk.ex` | ✅ |

**Verification (2026-07-10):** `mix compile --force` clean, no new warnings. Live
script against the real dev DB covering all three cases:
- **Not-written-off account**, real balance bucket, agency channel enabled:
  imported a 150.00 `PAYMENT` — `{applied: 1, rejected: 0}`; confirmed the
  *actual* `BalanceBucket.retail_balance` dropped from 500.00 to 350.00 (real
  waterfall distribution, not a no-op); confirmed `last_payment_date` stamped to
  today; confirmed a real `PAYMENT` ledger entry exists; commission (8% flat)
  correctly stored as 12.00. (OTB restore itself lives in the in-memory
  `AccountStateCoordinator` GenServer, not the DB row — verifying that specific
  piece would need a running coordinator process for the test account, not
  attempted; every DB-durable effect was confirmed.)
- **Written-off account** (regression check): same import flow —
  `{applied: 1, rejected: 0}`; `ChargeOffRecovery.total_recovered/1` correctly
  returned 100.00, confirming the pre-existing P4 path is unchanged.
- **Channel not enabled**: a second bank without `"agency"` in
  `payment_channels_enabled` — import correctly returned `{applied: 0,
  rejected: 1}` with reason `{:channel_not_enabled, "agency"}` on the activity
  row, proving the gate is real, not decorative.

Also updated the LiveView test fixture (`col_component_test.exs`) to enable the
`"agency"` channel and add a real `BalanceBucket`, since the existing "Agency
Files" panel test (P6) now exercises the real payment pipeline instead of a
no-op — all 8 tests still pass. Test data cleaned up after (dev DB confirmed
clean).

## COL-P9 — Hardship/Workout Plans + Settlement Offers ✅ (2026-07-10)

The largest single phase, as flagged going in. Genuinely new capability, not a
rewire — FR-014/015 had no schema, workflow, or wiring of any kind beforehand
(only a `workout_plan_id` field on `CollectionCase` that nothing ever set).

**Honest split of what's real vs. tracked-only** — decided before writing code,
not discovered partway through:

| Plan type | Real effect | Where |
|---|---|---|
| `PAYMENT_HOLIDAY` | Suppresses late/overlimit fee assessment **and** DPD aging while active | `CMS.EOD.AgeBucketsJob` checks `WorkoutCommand.active_holiday?/2` |
| `APR_REDUCTION` | Overrides the interest calculation's purchase/cash APR — takes priority over penalty-APR escalation (hardship relief should win over a punitive rate) | `CMS.EOD.AccrueInterestJob` checks `WorkoutCommand.active_apr_override/2` |
| `RESTRUCTURE` | **Tracked only.** `CMS.EmiSchedule.create_schedule/1` is the real primitive that *would* convert the balance to an EMI schedule, but doing it correctly needs a registered `plan_segments` `plan_id` — bank/logo product configuration outside COL's scope to fabricate. Approval activates the plan record for reporting; ops must set up the EMI plan manually today (logged clearly on approval, surfaced in the UI) | `VmuCore.COL.WorkoutCommand` |
| Settlement offer | Fully real: on `settle/3`, posts the actual payment received (`"PAYMENT"`) then forgives the remainder (`"ADJUSTMENT"` — the same transaction code `WriteOffProcessor` already uses, no new ledger code to forget registering), case → `RECOVERED` | `VmuCore.COL.SettlementCommand` |

| # | Task | File(s) | Status |
|---|---|---|---|
| P9.1 | Config: `workout_approval_matrix` (role list, mirrors `writeoff_approval_matrix`) and `settlement_authority_matrix` (tiered by discount %, mirrors `TRAMS.AdjustmentCommand`'s authority-limit shape — a role's tier is a ceiling, not a band) + `settlement_min_acceptable_percent` (floor on how deep a discount can go) | `lib/vmu_core/col/config_catalog.ex` | ✅ |
| P9.2 | `col_workout_plans` / `col_settlement_offers` tables + schemas | migration `20260710000005_...`, `lib/vmu_core/col/workout_plan.ex`, `settlement_offer.ex` | ✅ |
| P9.3 | `VmuCore.COL.WorkoutCommand` — `request/4`, `approve/2` (role-list gate + maker≠checker), `reject/2`, `pending/1`, `active_holiday?/2`, `active_apr_override/2` | `lib/vmu_core/col/workout_command.ex` | ✅ |
| P9.4 | `VmuCore.COL.SettlementCommand` — `request/5` (rejects offers deeper than the configured floor), `approve/2` (tiered authority gate + maker≠checker), `reject/2`, `settle/3` (payment + forgiveness GL posting, case → `RECOVERED`), `pending/1` | `lib/vmu_core/col/settlement_command.ex` | ✅ |
| P9.5 | `AgeBucketsJob`/`AccrueInterestJob` wired as described above | `lib/vmu_core/cms/eod/age_buckets_job.ex`, `accrue_interest_job.ex` | ✅ |
| P9.6 | `ApprovalInboxComponent` — two more sections (Workout Plans, Settlement Offers), same pattern as write-offs | `lib/vmu_core_web/live/admin/approval_inbox_component.ex` | ✅ |
| P9.7 | `ColComponent` case detail — request forms for both (plan-type-specific fields shown dynamically), plus a "Settle" action on an `APPROVED` offer | `lib/vmu_core_web/live/admin/col_component.ex` | ✅ |

**Verification (2026-07-10):** `mix ecto.migrate` (dev + test) / `mix compile
--force` clean, no new warnings. Live script against the real dev DB (real
`BlockParameter` at 36% APR, real EOD jobs, not mocks):
- **Payment holiday**: requested → `OPS` correctly denied (`role_not_authorized`)
  → `SUPERVISOR` approved → `ACTIVE`; `active_holiday?` correctly bounded by
  `end_date` (true today, false 100 days out); ran the real
  `AgeBucketsJob.perform/1` during the holiday — DPD stayed at 60 (no aging) and
  zero `FEE` ledger entries were posted (suppressed).
- **APR reduction**: requested (9% vs. base 36%) → approved →
  `active_apr_override` returned `{:ok, 9.00}`; ran the real
  `AccrueInterestJob.perform/1` — posted interest reflected the 9% rate (0.15 for
  a 1-day cycle on 600.00 — the 36% base rate would have posted ~4x that).
- **Settlement**: a 70%-discount offer correctly rejected at request time
  (`:discount_too_deep`, floor is 60% by default); a 25%-discount offer's
  `SUPERVISOR` approval correctly rejected (`:discount_exceeds_authority`, their
  tier caps at 10%); a 20%-discount offer approved fine by `RISK` (tier caps at
  25%); `settle/3` posted a real `PAYMENT` entry (800.00) and a real
  `ADJUSTMENT` forgiveness entry (200.00), and the case flipped to `RECOVERED`.

LiveView test suite (now 9 tests, all passing) adds: requesting a workout plan
and a settlement offer through the case detail UI (verified against real DB
rows), approving the offer via the command layer (the Approval Inbox is a
separate component, exercised at the command level here), and settling it
through the UI's "Settle" button — verified `status: "PAID"` and the case
reaching `RECOVERED`. Test data cleaned up after (dev DB confirmed clean).

---

## COL module status as of 2026-07-10

Nine phases (P1–P9) built in one continuous session. Every phase was verified
against real data (real Postgres rows, real GL postings, real EOD job runs —
not mocks) before being marked done, and every phase's admin UI surface (from
P5 onward) was click-through tested via `Phoenix.LiveViewTest`, not just
compiled. `lib/vmu_core/col/` now has 16 files; `col_component_test.exs` has 9
tests.

**Still open** (not attempted, or explicitly scoped out — tracked honestly, not
silently dropped):

- XML parsing for agency activity files (P4) — no vendor sample to validate
  a real parser against.
- `RESTRUCTURE` workout plans don't auto-generate an EMI schedule (P9) — needs
  a registered `plan_segments` plan_id, bank/logo product configuration.
- Post-write-off recovery accounting beyond `CMS.ChargeOffRecovery`
  (FR-021-023), deceased/bankruptcy special handling (FR-024).
- FR-COL-009 cure-detection auto-close — a kept promise or a cured DPD resets
  its own status/promise field but doesn't auto-close the whole case.
- The "COL MI" dashboard (FR-025, Roadmap Phase 8 in the original plan).
