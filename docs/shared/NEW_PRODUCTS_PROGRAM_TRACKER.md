# New Card Products Program — Implementation Tracker

> **⚠️ 2026-07-16 — Platform unification approved; `wallet-app` renamed
> to `Avenza`.** In direct response to the real cross-repo friction hit
> building Debit's D-UI1 (a synchronous FAS↔wallet-app HTTP bridge), the
> decision is made: collapse vmu_core entirely into what was `wallet-app`
> (repo/folder renamed to **`Avenza`** on disk, at
> `d:\momentPay\Products\E-VisionPlus\Avenza` — same codebase, same
> Elixir module namespaces for now, folder rename only per explicit
> scope), on a single Postgres database, as one unified Way4/VisionPlus-
> class issuing platform (credit, virtual, debit, prepaid, fleet, wallet
> all under one roof). Full design + phased plan:
> `Avenza/docs/platform-unification-plan.md`. This tracker's remaining
> vmu_core-only work (Track 1/2 items already done stay done and
> reusable) and Track 3's Debit D-UI2-4 (paused) get re-sequenced into
> that plan's M2-M5 phases rather than continuing here independently.
> Plan written, M0/M1 not yet started as of this note.

> Source: `NEW_PRODUCTS_UI_OPERATIONS_PLAN.md` §6 (Gate 0 passed 2026-07-12).
> Statuses: `✅ Done` · `🔄 In Progress` · `⬜ Pending` · `🔒 Blocked`
> Spans two repos: `vmu_core` (this repo, Postgres) and the sibling
> `wallet-app` (MySQL). Each phase below names its repo explicitly.
> Individual product planning docs (`docs/{debit,prepaid,wps,fleet,bnpl,wallet}/`)
> remain the source of truth for backend build phases (D1/D2/…, W1/W2/…,
> etc.) — this tracker covers UI/ops phases + the three new cross-cutting
> workstreams (A1/A2/A3) added during the 2026-07-12 review.

---

## Program dependency graph

```
Track 1 (vmu_core-only, no dependency)          Track 2 (foundational)
  V-UI1a ─────────────────────────┐               A1 (API layer, thin slice)
  F1 + F-UI1 → F-UI2 → F-UI3      │                 ├──> A3.1 (Party Registry)
                                   │                 │      ├──> A3.3 (CIF status + flags)
                                   └──> V-UI1b <─────┘      └──> A3.4/A3.5 (KYC attain./providers)
                                                     └──> A2 (SSO) [parallel, independent]

Track 3 (wallet-app products) — starts once A3.1 exists
  W-UI1..4 (WPS)  ⇄  P-UI1..4 (Prepaid) ──> D-UI1..4 (Debit + D4 recon) ──> B-UI1..4 (BNPL)
```

---

## Track 1 — vmu_core, immediate, zero cross-system risk

### Phase V-UI1a — Virtual Card Admin Issuance ✅ Done (2026-07-12)
| # | Task | File(s) | Status |
|---|---|---|---|
| V1a.1 | `+ New Card` button + card-type selector (PRIMARY/SUPPLEMENTARY/VIRTUAL) on the account Cards tab | `lib/vmu_core_web/live/admin/account_component.ex` | ✅ |
| V1a.2 | `VmuCore.CTA.PanGenerator` — **new module**, the first real implementation of "the issuance tokenizer" `CardLifecycle.replace/3`'s docs had referenced but never built: BIN prefix from the account's own `LogoParameter` (never guessed), random body, real Luhn check digit, SHA-256 token, raw PAN discarded | `lib/vmu_core/cta/pan_generator.ex` | ✅ |
| V1a.3 | `CardLifecycle.issue_new/2` — issues to INACTIVE via `Cards.issue/1` (audited), optionally chains into the existing audited `activate/2` rather than setting status directly (so `activated_at` stamping and account-denormal sync aren't bypassed) | `lib/vmu_core/cta/card_lifecycle.ex` | ✅ |
| V1a.4 | LiveView wiring: `card_issue_open`/`card_issue_save` events + action panel | `lib/vmu_core_web/live/admin/account_component.ex` | ✅ |

**Verification (2026-07-12):** live script, real Postgres, no mocking:
independently re-verified the Luhn formula against 4 known-valid real test
PANs; issued a VIRTUAL card → straight to INACTIVE, correct type, 64-hex
token; issued a PRIMARY card with `activate: true` → correctly chained into
`activate/2`, `activated_at` stamped, account PAN denormal synced; invalid
card_type rejected; two generations produce distinct PANs (real
randomness). Test data cleaned up, dev DB confirmed clean.

**Known gap flagged, not fixed here (out of scope for this phase):** unlike
the system/organization/logo/block/customer components (ASM-P5), the
account component's card-lifecycle buttons (including this new one) have
no per-action `Authz.can?` gating — anyone who can open the account screen
can issue/activate/block/replace cards. Pre-existing, not introduced by
this phase; worth its own ASM/CTA follow-up.

### Phase F1 + F-UI1 — Fleet HCS Fixes + Base Admin UI ✅ Done (2026-07-12)
| # | Task | File(s) | Status |
|---|---|---|---|
| F1.1 | `DAILY_CAP` enforcement in `LimitController.apply_control/4` — added a `daily_spend`/`daily_spend_date` counter on `EmployeeCard`, maintained at the same `debit_limits/2` choke point already used for `available_individual`/`available_limit` (not a separate ledger-sum query or a second source of truth) | `lib/vmu_core/hcs/limit_controller.ex`, `employee_card.ex`, migration `20260712000001` | ✅ |
| F1.2 | `can_withdraw_cash` enforcement — `check_hcs_limits/5` now takes the same `cash_txn` boolean `AccountStateCoordinator.do_authorize/6` already computes (reused, not recomputed) and declines with `:cash_access_blocked` when the card doesn't allow it | `lib/vmu_core/hcs/limit_controller.ex`, `cms/account_state_coordinator.ex` | ✅ |
| F-UI1.1 | HCS admin module: company list/detail/create/edit + employee-card and spending-control read-only rosters. Facility **limit changes are requested, not edited directly** — parked via `FacilityLimitCommand.request/3`, approved from the existing unified Approval Inbox (same "one action surface" split COL uses for write-offs/workout/settlement) | `lib/vmu_core/hcs/{facility_limit_change,facility_limit_command,config_catalog}.ex`, `lib/vmu_core_web/live/admin/hcs_component.ex`, migration `20260712000005` | ✅ |
| F-UI1.2 | `AdminLive` registration (sidebar + dispatch) + `RolePermission` grants (`hcs` module added, SUPERVISOR/OPS/RISK view+edit, CS_AGENT/COMPLIANCE view-only — same shape as `col`) + Approval Inbox wired with a new "HCS Facility Limit Changes" section | `admin_live.ex`, `role_permission.ex`, `approval_inbox_component.ex` | ✅ |
| F-UI1.3 | LiveView tests (7) — list render, unauthenticated redirect, view detail, create company, request-limit-change parks without changing the limit, CS_AGENT sees no edit/request buttons, **full cross-component approval flow** (request → approve from the Approval Inbox → limit actually applied) | `test/vmu_core_web/live/admin/hcs_component_test.exs` | ✅ |

**Bug found + fixed during this phase (pre-existing, not introduced by
F-UI1):** `CompanyOnboarding.onboard_company/1` and `.add_employee_card/3`
both referenced `account.id` — but `CMS.Account`'s primary key is
`:account_id`, not `:id`. Building "Create Company" was the **first ever
real caller** of `onboard_company/1`; it crashed with a `KeyError` on
every single call, meaning this function had never actually run against a
real Account before. Fixed both call sites (same root cause, same file).
Noted, not fixed (lower severity, no crash): both functions also set a
nonexistent `account_type` field on `CMS.Account` — silently dropped by
`cast/2`, dead intent rather than a bug, out of scope here.

**Verification (2026-07-12):** F1 — live script, real Postgres: cash
withdrawal correctly blocked when `can_withdraw_cash: false`, unaffected
for non-cash transactions; spend of 200 against a 300 daily cap approved,
debited, and reflected in the counter; a further 150 correctly declined
with `:daily_cap_exceeded`; a further 90 correctly approved; a stale
(prior-day) counter correctly treated as zero. F-UI1 — 7/7 LiveView tests
passing against real Postgres (Sandbox), including the full maker-checker
loop: a SUPERVISOR requests a limit change (parked, limit unchanged), an
OPS operator's request is approved from the Approval Inbox by a different
operator, and the company's `credit_limit` is confirmed actually updated
afterward. All test data cleaned up (dev-DB smoke scripts) or
sandbox-rolled-back (LiveView tests).

**Not built in this phase (F-UI2/F-UI3 scope, per the product doc):**
vehicle/driver sub-accounts, enhanced fuel line-item capture, fuel
reports, anomaly detection queue.

### Phase F2/F3 + F-UI2/F-UI3 — Fleet Vehicle Sub-Account + Roster + Reports ✅ Done (2026-07-12)
Two open product questions blocked this phase per the Fleet doc's own
"needs product/business input" list — resolved via AskUserQuestion before
starting: **(1)** vehicle identity = VIN + plate **+ driver assignment
history** (not a bare 1:1 card-to-vehicle shape); **(2)** v1 ships
*without* enhanced fuel line-item capture (odometer/product-type/unit-
price) since no real acquirer fuel-dispenser spec has been sourced —
roster + standard-transaction reports only, per the doc's own suggested
minimal v1.

| # | Task | File(s) | Status |
|---|---|---|---|
| F2.1 | `HCS.Vehicle` — **parallel schema to `EmployeeCard`**, not a variant (vehicle and employee are different identity concepts, per the doc's own recommendation) — VIN/plate/make/model/year | `lib/vmu_core/hcs/vehicle.ex`, migration `20260712000006` | ✅ |
| F2.2 | `HCS.DriverAssignment` + `DriverAssignmentCommand` — the "current" assignment for a vehicle is always the single row with `unassigned_at == nil`; `assign_driver/3` closes any open assignment before opening a new one in the same transaction, so reassignment is a single action, never a two-step "unassign then assign" | `lib/vmu_core/hcs/{driver_assignment,driver_assignment_command}.ex` | ✅ |
| F2.3 | `HCS.FleetCard` — deliberately shares field names with `EmployeeCard` for every limit/control field (`available_individual`, `can_withdraw_cash`, `daily_spend`, `daily_spend_date`) so `LimitController`'s existing checks work unchanged against either struct | `lib/vmu_core/hcs/fleet_card.ex` | ✅ |
| F2.4 | `LimitController` generalized to enforce **either** card kind on the same authorization path — `get_active_card/1` tries `EmployeeCard` then `FleetCard`; `SpendingControl` gained a `VEHICLE` scope + `fleet_card_id` column since card-scoped controls now live in one of two columns depending on kind | `lib/vmu_core/hcs/limit_controller.ex`, `spending_control.ex`, migration `20260712000006` | ✅ |
| F3.1 | `FleetOnboarding.add_vehicle/2` + `.add_fleet_card/3` — fleet card accounts reuse the company's own parent `CMS.Account.customer_id` (a vehicle isn't a separate KYC entity); pool-check sums **both** employee and fleet allocations (stricter than the pre-existing `add_employee_card/3`, which only sums its own kind — see note below) | `lib/vmu_core/hcs/fleet_onboarding.ex` | ✅ |
| F-UI2.1 | Vehicle roster on the company detail screen (list + "+ Add Vehicle"), vehicle detail sub-screen (info, fleet card issuance, driver assignment + history) | `lib/vmu_core_web/live/admin/hcs_component.ex` (new `:vehicle_detail` render mode) | ✅ |
| F-UI3.1 | `HCS.FleetReport` — spend-by-vehicle and spend-by-driver, built from `cms_ledger_entries` (same source `ConsolidatedStatementGenerator` already uses for company billing, not a new transaction feed); spend-by-driver attributes 100% of a vehicle's period spend to its **current** driver only — explicitly not split across a mid-period reassignment (flagged in the UI, not silently simplified) | `lib/vmu_core/hcs/fleet_report.ex`, report panel in `hcs_component.ex` | ✅ |

**Bugs found + fixed during this phase:**
1. The `Ecto.Query` `dynamic/2` fragment for the card-kind-specific `SpendingControl` filter can't be interpolated mid-`and`-chain inside a single `where:` — Ecto requires dynamic fragments at the top level of a clause. Fixed by splitting into separate chained `where:` clauses (Ecto ANDs them automatically) instead of one combined boolean expression.
2. `FleetReport`'s period-range query used `DateTime.new!(date, time, "UTC")` — "UTC" is not a valid IANA zone name under Elixir's built-in `Calendar.UTCOnlyTimeZoneDatabase` (only "Etc/UTC" resolves); raised `ArgumentError` the first time the report actually ran. Fixed to "Etc/UTC". **Flagged, not fixed (out of scope, pre-existing):** `HCS.ConsolidatedStatementGenerator` has this exact same "UTC" literal and has likely never been exercised against a real time-zone-database config either — same "looks complete, never actually run" class of finding as `CompanyOnboarding` in F-UI1.
3. A LiveView state-ordering bug in the new `issue_fleet_card_save`/`assign_driver_save`/`unassign_driver` handlers: `load_vehicle_detail/2` (the shared reload helper) resets `notice: nil` as part of a fresh view load, but the handlers were assigning the success notice *before* calling it — so the reload immediately clobbered the notice before it ever rendered. Fixed by reordering: reload first, success notice assigned on top.

**Verification (2026-07-12):** live smoke script, real Postgres, no
mocking — DAILY_CAP enforcement proven for a **fleet** card specifically
(200 approved → 150 declined `:daily_cap_exceeded` → 90 approved, same as
F1's employee-card proof, now confirmed generalized); cash-access block
for a fleet card with `can_withdraw_cash: false`; individual and company
pool checks; driver reassignment correctly closes the prior assignment
(never two open at once — verified via row count + `unassigned_at`
state) and unassign clears it; fleet spend report correctly summed a
real `cms_ledger_entries` row by vehicle and by (unassigned) driver. All
smoke-test data cleaned up, dev DB confirmed clean (0 residual rows).
**14/14 LiveView tests passing** (7 pre-existing F-UI1 + 7 new: roster
render, add vehicle, issue fleet card + confirm it authorizes, driver
reassignment closes prior assignment, unassign, spend report renders
real aggregated data, CS_AGENT view-only gating) — zero regressions in
the full `test/vmu_core_web/live/admin/` suite (23/23 passing). Full
project `mix compile --force` clean, zero new warnings.

**Not built in this phase (F4/F5 scope per the Fleet doc, deliberately
deferred pending the fuel-dispenser spec decision above):** enhanced
fuel line-item capture (odometer/product-type/unit-price), MPG/
consumption anomaly detection, per-fuel-type reporting.

---

## Track 2 — Foundational (vmu_core)

### Phase A1 — vmu_core API Layer (thin first slice) ✅ Done (2026-07-12)
| # | Task | File(s) | Status |
|---|---|---|---|
| A1.1 | `VmuCore.ASM.ServiceAccount` — machine-caller identity distinct from `Operator` (no password/session; single opaque bearer token, only its SHA-256 `token_hash` ever persisted, raw token returned once at creation) + flat `scopes` list (e.g. `"accounts:read"`), deliberately simpler than the operator role×module×action matrix — different concern, different change cadence | `lib/vmu_core/asm/service_account.ex`, migration `20260712000002` | ✅ |
| A1.2 | First real endpoint: `GET /api/v1/accounts/:id`, read-only, scope-gated, clean 404 on both "not found" and malformed-UUID input (no 500 crash) | `lib/vmu_core_web/controllers/api/v1/account_controller.ex`, `router.ex` | ✅ |
| A1.3 | `VmuCoreWeb.Api.V1.ErrorEnvelope` — shape deliberately mirrors wallet-app's own error envelope (`error: {code, message, retryable, category, details}`, `meta: {request_id, correlation_id, timestamp}`) so its first consumer needs one client-side error handler, not two | `lib/vmu_core_web/api/v1/error_envelope.ex` | ✅ |
| A1.4 | `VmuCoreWeb.Api.V1.RateLimiter` — ETS-backed fixed 60s window, `:ets.update_counter/4` (no GenServer round-trip per request), one global default limit (120/min) for this thinnest-possible slice | `lib/vmu_core_web/api/v1/rate_limiter.ex`, registered in `application.ex` | ✅ |
| A1.5 | API access audit — reuses `ASM.AuditLog.record/4` (called with `nil` operator + service-account identity folded into `details`, since `AuditLog` expects an `Operator`-shaped struct, not a `ServiceAccount`) | `account_controller.ex` | ✅ |
| A1.6 | `VmuCoreWeb.Plugs.ApiV1Auth` — Bearer-token auth pipeline, distinct from the pre-existing `/api/fas` shared-secret `InternalApiAuth` (single internal caller, no scoping) — this is the new general, multi-consumer, scoped API auth | `lib/vmu_core_web/plugs/api_v1_auth.ex`, `router.ex` (`:api_v1` pipeline) | ✅ |

**Correction to the original A1 framing:** this doc previously said vmu_core
"has zero external API surface." More precisely: `/api/fas` already existed
(a single shared-secret header, one caller — settlement_core, FAS-P4) — but
nothing resembling a scoped, multi-consumer, audited API existed, which is
what A1 actually built.

**Verification (2026-07-12) — 12/12 checks, live HTTP calls against the
real running Endpoint, no mocking:** missing/invalid/disabled-account
tokens all → 401; valid token without the required scope → 403; unknown
(but well-formed) account id → 404; malformed (non-UUID) account id → 404,
**not a 500 crash**; valid token + scope → 200 with correct account data;
125 rapid requests against the same service account correctly triggered
429s once the limit was exceeded; every successful read produced a real
`cms_operator_audit` row; `last_used_at` updated on the service account.
All test data (accounts, customers, service accounts, audit rows) cleaned
up after; dev DB confirmed clean.

**Entry criteria:** none — done.
**Unblocks:** A3.1, V-UI1b, and any other API-first work per the Q4/Q5
architectural direction.

### Phase A3.1 — Party Registry ✅ Done (2026-07-12)
Per the revised D7 in the ops plan.
| # | Task | File(s) | Status |
|---|---|---|---|
| A3.1.1 | Schema: `parties`, `party_identifiers`, `party_product_links`, `party_kyc_attainments`, `party_flags`, `party_match_reviews` | `lib/vmu_core/party/{party,identifier,product_link,kyc_attainment,flag,match_review}.ex`, migrations `20260712000003`/`...004` | ✅ |
| A3.1.2 | Identifier scheme config (Module Config Framework — per SYS/BANK `identifier_hierarchy`, e.g. IN: PAN primary/Aadhaar-ref/phone-secondary; AE: Emirates ID primary) | `lib/vmu_core/party/config_catalog.ex` | ✅ |
| A3.1.3 | Deterministic matcher (`Registry.find_or_create/1`) + `Registry.link_cif_customer/1` — wires the previously-dead `Shared.Customer.find_duplicates/1` as a real same-system dedupe check alongside the cross-system party match | `lib/vmu_core/party/registry.ex` | ✅ |
| A3.1.4 | Probable-match review queue (`MatchReview`) — fuzzy name+DOB matches (stdlib `String.jaro_distance/2`, same non-hot-path posture as `SanctionsChecker.fuzzy_check/1`) queue for review, **never auto-merge** | `lib/vmu_core/party/registry.ex` | ✅ |
| A3.1.5 | `POST /api/v1/parties` (create/link) + `GET /api/v1/parties/:id` (identity, masked identifiers, linked products, active flags) | `lib/vmu_core_web/controllers/api/v1/party_controller.ex`, `router.ex` | ✅ |

**Bug found + fixed during verification:** the first migration's unique
index on `party_identifiers` (`id_type`, `country`, `id_value_hash`)
assumed every identifier type must be globally unique — true for a
genuine national ID (Emirates ID, PAN), **wrong for phone**, which is
deliberately excluded from ever being a sole match key precisely because
numbers get recycled/shared. The constraint made that legitimate case
(two different real parties, same phone number) impossible to store at
all — crashed on live verification the first time two smoke-test parties
shared a phone number. Fixed via a follow-up migration (`20260712000004`)
replacing the unique index with a plain lookup index; uniqueness for
genuine national IDs is enforced at the application layer instead
(`Registry.deterministic_match/2` always finds and reuses an existing
party before a duplicate insert would occur).

**Verification (2026-07-12) — 14/15 checks, live, real Postgres (the one
"failure" was a wrong hardcoded expectation in the test script itself, not
a product bug — the masking behavior it checked was actually correct):**
default `identifier_hierarchy` config resolves; two records with the same
Emirates ID deterministically link to the *same* party across two
different systems; a different Emirates ID with a very similar name
("Ahmed Khan" vs "Ahmed Khann", same DOB) correctly creates a **distinct**
new party AND queues a `MatchReview` (score 0.97) — never auto-merged;
**phone misconfigured with `sole_match_key: true` still correctly refused
to force-link two different people** (the hard-coded rule overriding bad
config); `link_cif_customer/1` real end-to-end with a real `Customer` row,
correctly masked identifier stored; flags raised/listed/cleared; the API
created a party, read it back with masked identifiers, and a second POST
with the same identifier correctly linked to the *same* party rather than
creating a duplicate; missing-field and missing-scope requests correctly
rejected. All test data cleaned up, dev DB confirmed clean (0 residual
parties).

**Not built in this phase (flagged, not silently dropped):** a manual
merge action for confirmed `MatchReview` entries (ops reviews and
confirms/rejects, but nothing executes a merge yet — reasonable next step
whenever the review queue needs a UI); wallet-app-side linkage (A3.2).

### Phase A3.2 — Backfill Existing Customers ✅ Done (2026-07-12)
`VmuCore.Party.Backfill` — links pre-existing `cms_customers` rows into
the Party Registry. Deterministic matches auto-link; fuzzy matches queue
a `MatchReview` (never auto-merge, per A3.1); real errors (bad data) are
collected per-record, not fatal to the whole run.
| # | Task | File(s) | Status |
|---|---|---|---|
| A3.2.1 | `Backfill.dry_run/0` — runs the real `Registry.link_cif_customer/1` path inside a transaction that always rolls back, so it's a true preview (real matching logic, zero persisted writes) | `lib/vmu_core/party/backfill.ex` | ✅ |
| A3.2.2 | `Backfill.run/0` — the live run; idempotent by design (pre-checks for an existing `party_product_links` row per customer before calling `link_cif_customer/1`, since that function itself has no such guard) | `lib/vmu_core/party/backfill.ex` | ✅ |

**Bugs found + fixed during this phase (in `Party.Registry`, from A3.1 —
never previously exercised against messy real data):**
1. `create_new/2` crashed via a `{:ok, party} = ... |> Repo.insert()`
   MatchError the moment a real customer failed `Party` changeset
   validation (a dev customer tagged `customer_tier: "CORPORATE"` with no
   `company_name` on file — a real pre-existing data-quality gap, not
   something I altered). Fixed to return `{:error, changeset}`, matching
   what `find_or_create/1`'s own `@spec` already (falsely) promised.
2. That fix's first attempt used `Repo.rollback(changeset)` inside
   `create_new/2`'s transaction — which is wrong when `create_new/2` is
   called from *within* an already-open outer transaction (exactly what
   `Backfill.dry_run/0` does): Ecto doesn't create a real savepoint for a
   nested `Repo.transaction/1` call, so that rollback would abort the
   **caller's entire transaction**, not just this one record. Fixed by
   moving the `Party` insert outside any transaction (a changeset
   validation failure never touches the DB, so there's nothing to roll
   back) and only wrapping the remaining, expected-to-succeed steps.

**Verification (2026-07-12), live against the real 10 pre-existing dev
customers (not synthetic smoke data):** `dry_run/0` left party/link
counts unchanged (0 persisted); `run/0` created 5 `Party` records + 5
`ProductLink`s from 9 successfully-processed customers (4 deterministically
matched into parties created earlier in the *same* run — i.e., some of
these dev customers already shared a national ID, exactly the case Party
Registry exists to catch) + 1 real data-quality error (the CORPORATE/no-
company_name customer, now visible instead of crashing); re-running
`run/0` a second time correctly skipped all 10 (idempotency confirmed —
zero new parties). Zero `MatchReview`s queued (no fuzzy name+DOB overlaps
among these particular records). **This dev-DB data is the actual
delivered backfill, not smoke-test residue — left in place**, unlike the
throwaway companies/customers created for other phases' smoke tests.

### Phase A3.3 — CIF Status Field + Flag Propagation ✅ Done (2026-07-12)
| # | Task | File(s) | Status |
|---|---|---|---|
| A3.3.1 | `Customer.status` field (ACTIVE/INACTIVE/DECEASED/BLACKLISTED — closes CIF FR-008) | `lib/vmu_core/shared/customer.ex`, migration `20260712000007` | ✅ |
| A3.3.2 | Inbound flag propagation — `Party.FlagInboxRecord` + `Party.FlagPropagation.submit_inbound_event/1` + `.process_inbox/0` (resolves a reported identifier to a `Party`, raises the flag, propagates to every linked CIF customer's `status`) + `Party.Oban.FlagInboxWorker` (cron, every 5 min) | `lib/vmu_core/party/{flag_inbox_record,flag_propagation}.ex`, `lib/vmu_core/party/oban/flag_inbox_worker.ex` | ✅ |
| A3.3.3 | Outbound flag publishing — `Party.FlagOutboxRecord` + `Party.FlagPropagation.deliver_outbox/0` + `Party.FlagSubscriber` behaviour (register via `config :vmu_core, :party_flag_subscribers, [...]`) + `Party.Oban.FlagOutboxWorker` (cron, every 5 min) | `lib/vmu_core/party/{flag_outbox_record,flag_subscriber,flag_propagation}.ex`, `lib/vmu_core/party/oban/flag_outbox_worker.ex` | ✅ |

**Design note:** while researching this phase, found the sibling
wallet-app repo already has a real, working generic eventing system
(`apps/wallet_events`, tables `wallet_events_outbox_records` /
`_inbox_records`, described in `docs/adr/0002-eventing-and-outbox.md`).
vmu_core's new `party_flag_inbox`/`party_flag_outbox` tables deliberately
mirror that same field vocabulary (`event_name`, `payload` map, `status`
pending/dispatched/failed) so a future bridge between the two is a thin
adapter, not a rewrite. **This phase does not read or write wallet-app's
actual tables** — per the tracker's own earlier-flagged open item,
touching another system's live production event pipes needs ownership
confirmation first; what's built here is the vmu_core-side mechanism plus
a real, testable extension point (`FlagSubscriber`), with zero subscribers
registered by default.

**Verification (2026-07-12), live smoke script, real Postgres:** raised a
DECEASED flag directly → linked CIF customer's `status` flipped to
DECEASED; outbound event correctly queued `pending`; `deliver_outbox/0`
dispatched it to a registered test subscriber (received via message pass,
confirming the callback actually fires) and marked it `dispatched`;
cleared the flag → customer correctly reverted to ACTIVE (only when no
other active flags remain); submitted a real *inbound* event (simulating
"another system reports a sanctions hit" against the customer's real
PASSPORT identifier) → `process_inbox/0` resolved it to the right party
and flipped status to BLACKLISTED; a second inbound event against an
**unresolvable** identifier correctly failed gracefully (`processed: 0,
failed: 1`) rather than crashing the batch. All smoke-test data cleaned
up (three separate cleanup passes needed due to two schemaless-query
UUID-decoding mistakes in the cleanup script itself, not in the shipped
code — fixed by querying through the real Ecto schemas instead of raw
table names). Dev DB confirmed clean of all A3.3 smoke-test residue.
Full admin LiveView suite still 23/23 passing — zero regressions from the
`Registry.ex` fix or the new `Customer.status` field.

**Not built in this phase (flagged, explicitly out of scope):** wiring
the CIF admin UI (`customer_component.ex`) to expose `Customer.status` or
let an operator manually raise a flag from the UI — A3.3's scope was the
schema + propagation mechanism, not new UI surface; a real wallet-app-side
subscriber (the cross-repo integration step, needs ownership confirmation
per the open items list below).

### Phase V-UI1b — Virtual Card Credential Delivery API ✅ Done (2026-07-12)
The real cardholder-facing capability V-UI1a's admin-only flow didn't
provide: an API a UI (wallet-app) calls to issue a virtual card and,
separately, reveal its credentials exactly once.

| # | Task | File(s) | Status |
|---|---|---|---|
| V-UI1b.1 | `HSM.generate_cvv/3` — new callback, the forward direction of the already-real `verify_cvv/4` algorithm (`SoftHSM` reuses the exact same `compute_cvv/4` internals so generation/verification can never drift; falls back to a clearly-synthetic value when no CVK is configured, matching `verify_cvv/4`'s own dev-mode posture) | `lib/vmu_core/fas/hsm/{hsm,soft_hsm,production_hsm}.ex` | ✅ |
| V-UI1b.2 | `PanGenerator.generate_with_raw/3` — the only caller in the codebase that legitimately needs the raw PAN, even momentarily (every other caller only ever needed `pan_token`) | `lib/vmu_core/cta/pan_generator.ex` | ✅ |
| V-UI1b.3 | `CTA.CredentialVault` — **new** ephemeral, exactly-once credential store. GenServer-owned ETS table (never Postgres — nothing durable ever stores the raw PAN/CVV); `reveal/1` atomically reads-and-deletes so a second reveal for the same card can never succeed; a 5-minute sweep expires anything left unrevealed past 15 minutes | `lib/vmu_core/cta/credential_vault.ex`, registered in `application.ex` | ✅ |
| V-UI1b.4 | `CardLifecycle.issue_virtual_with_credentials/2` — issues + activates a VIRTUAL card immediately (no dispatch step, unlike physical plastic), computes the CVV, stashes credentials in the vault, returns **only card metadata** | `lib/vmu_core/cta/card_lifecycle.ex` | ✅ |
| V-UI1b.5 | `POST /api/v1/cards/virtual` (scope `cards:issue`) + `POST /api/v1/cards/:card_id/reveal` (scope `cards:reveal`) — every reveal attempt audited, success **or failure** (an already-revealed/expired attempt is itself security-relevant) | `lib/vmu_core_web/controllers/api/v1/virtual_card_controller.ex`, `router.ex` | ✅ |

**Verification (2026-07-12), live HTTP calls against the real running
Endpoint (same posture as A1), no mocking:** issued a virtual card via a
real `POST /api/v1/cards/virtual` → 201, card metadata only, **zero
PAN/CVV in the issuance response**; first `POST .../reveal` → 200, a real
16-digit PAN correctly prefixed with the account's own configured BIN
(453201) and a real 3-digit CVV; **second reveal for the same card → 404**
(exactly-once semantics proven, not just asserted); a service account
without `cards:issue` → 403; a nonexistent account → 404. Audit trail
confirmed 5 real rows for the one card: `card_issue_virtual` +
`card_activate` (CardLifecycle's own internal audits), `api_card_issue_virtual`
+ `api_card_reveal` (the controller's API-access audits), and
`api_card_reveal_failed` for the rejected second reveal attempt — proving
failed accesses are audited too, not just successes. Zero regressions —
full `test/vmu_core_web/live/admin/` suite still 23/23. Dev DB confirmed
clean after cleanup.

**Not built in this phase (explicitly out of scope):** a real HSM-backed
CVK (dev/UAT runs on the synthetic fallback, same posture as the
pre-existing `verify_cvv/4`); wallet-app-side UI to actually call these
endpoints (that's wallet-app's own work, this phase is vmu_core's API
side only).

### Phase A2 — SSO / IdP Integration (vmu_core side) ✅ Done (2026-07-13)
Wires ASM's existing `authn_source`/`authn_provider_config` config keys
(ASM-P6, previously unwired — no consumer at all) into a real OIDC
Authorization Code flow for operator login. Three scope decisions
resolved via AskUserQuestion before starting: **(1)** protocol = OIDC/
OAuth2, not SAML; **(2)** no real corporate IdP exists in this
environment, so verification is against a **self-hosted mock IdP** (real
RS256 signatures, real JWKS, same posture as `SoftHSM`) rather than
skipped; **(3)** scope = **vmu_core side only** — wallet-app's own
JWT-claims `AdminAuth` wiring is a separate, flagged cross-repo follow-up
(same precedent as A3.3's outbound flag subscriber).

| # | Task | File(s) | Status |
|---|---|---|---|
| A2.1 | Added `{:jose, "~> 1.11"}` — a well-vetted JWT/JWK library rather than hand-rolled signature verification. This is auth code for the admin console; JWT parsing has a real history of subtle vulnerabilities (algorithm confusion, "alg: none") a maintained library already closes | `mix.exs` | ✅ |
| A2.2 | `ASM.OidcConfig` — resolves `authn_source`/`authn_provider_config` into a usable client config. **Explicit endpoint URLs**, not a bare issuer + guessed discovery-path convention (real IdPs don't agree on one). Flagged v1 simplification: resolves against the *first* `BankParameter` row, matching the ASM login page's existing no-tenant-selector posture — real multi-tenant SSO would need its own tenant-selection step | `lib/vmu_core/asm/oidc_config.ex` | ✅ |
| A2.3 | `ASM.OidcClient` — authorization-URL builder, code exchange, ID-token verification. Algorithm is **always pinned to RS256 explicitly** — never read from the token's own header to decide how to verify it (the classic "alg confusion" JWT vulnerability class) | `lib/vmu_core/asm/oidc_client.ex` | ✅ |
| A2.4 | `ASM.Auth.authenticate_sso/2` — matches a verified claim to an **existing** `Operator` only. Deliberately **no JIT auto-provisioning** — creating an Operator carries a `role` with real authorization weight; auto-assigning one from an IdP claim is a separate, security-sensitive decision this phase doesn't make | `lib/vmu_core/asm/auth.ex` | ✅ |
| A2.5 | `OidcSessionController` (start/callback) + SSO button on the login page, config-gated via the same `OidcConfig.resolve/0` both use so they can't disagree about availability | `lib/vmu_core_web/controllers/{oidc_session_controller,operator_session_controller}.ex`, `router.ex` | ✅ |
| A2.6 | `VmuCoreWeb.MockIdp` — dev/test-only self-hosted OIDC provider (real RSA keypair, real signed JWTs, real JWKS). Compiled out of prod entirely (`if Mix.env() in [:dev, :test]`, both the routes and the supervision-tree registration) | `lib/vmu_core_web/mock_idp.ex`, `controllers/mock_idp_controller.ex`, `router.ex`, `application.ex` | ✅ |

**Bug found + fixed during this phase (pre-existing, not introduced by
A2 — pre-dates this whole session):** `Auth.audit/4`'s `Repo.insert_all`
silently failed and was swallowed by its own `rescue` clause whenever an
`outcome` string exceeded `asm_login_audit.outcome`'s `varchar(20)`
limit. Never previously exercised because every pre-existing `authenticate/3`
outcome string (`"success"`, `"bad_password"`, `"locked"`, `"disabled"`,
`"unknown_user"`) happens to fit under 20 characters — **A2's own
`"sso_no_matching_operator"` (24 chars) was the first outcome string ever
long enough to hit it.** Found live: the login flow behaved correctly
(right error shown to the user) while its audit row silently never
existed — exactly the kind of gap that only shows up when you check the
audit trail, not just the HTTP response. Fixed by shortening to
`"sso_no_match"`.

**Verification (2026-07-13), live HTTP calls against the real running
Endpoint + the real mock IdP, no mocking of vmu_core's own code:** full
success path — login page shows the SSO button (config-gated correctly)
→ `/auth/oidc/start` redirects to the mock IdP → mock IdP auto-approves
and redirects back with a real authorization code → callback exchanges
it for a real signed RS256 ID token, verifies it, matches `preferred_username`
to an existing Operator → session established → `/visionplus/admin`
correctly shows the operator's display name. Negative cases: an SSO
identity with **no matching Operator** correctly rejected with a clear
message (not a crash, not a silent login); **replaying the same
authorization code twice** correctly rejected on the second use (the
mock IdP's codes are genuinely single-use, not just documented as such);
a **tampered `state` parameter** correctly rejected (the OAuth CSRF
defense actually works, not just present in the code). Full audit trail
confirmed: exactly 3 real `asm_login_audit` rows for the whole run
(`sso_success`, `sso_no_match`, `sso_success`) — matching the 3 real
login *attempts* made, not the request count. Zero regressions — full
`test/vmu_core_web/live/admin/` suite still 23/23. Dev DB confirmed
clean.

**Not built in this phase (explicitly out of scope, per the scope
decision above):** wallet-app's own `AdminAuth` wiring against the same
IdP (flagged cross-repo follow-up); JIT operator auto-provisioning from
SSO claims (a separate, security-sensitive design decision); connecting
against a real vendor IdP (Okta/Azure AD/Keycloak) — the protocol
implementation is real and standards-correct, but has only been proven
against the mock, not a live vendor tenant, since none exists in this
environment.

### Phase A3.4 / A3.5 — KYC Attainment + External Provider Adapters ⬜ Pending 🔒
Config-driven KYC recognition rules (A3.4) + market-gated external KYC
provider adapters, e.g. India CKYC (A3.5) — scoped only once a launch
market is confirmed; no adapter built against a guessed spec.

**2026-07-14 note:** the *dynamic KYC form/method builder* capability
this item originally implied is now being built as a genuinely new
module in **wallet-app**, not here — see Track 3's new "KYC-P1..4" phase
below and `wallet-app/docs/kyc-module-design-tracker.md` for why (vmu_core
has no customer/merchant-facing UI at all to render a KYC form against).
A3.4/A3.5 as written here — config-driven *recognition* rules and
market-gated *provider adapters* — remain real, separate, still-parked
vmu_core-side questions once a launch market is confirmed; they are not
satisfied or closed by the wallet-app work.

---

## Track 3 — wallet-app products (repo: `wallet-app`)

### Phase W-UI1..4 — WPS Ops UI 🔄 W-UI1/W-UI2/W-UI3 done (2026-07-13), W-UI4 parked
Per ops plan §3.1. Backend (`wallet_wps`) already exists and is real —
this phase is UI + the maker-checker pattern (D5) only.
**Note on the A3.1 dependency:** not a hard blocker for W-UI1 (upload/
pre-flight/batch status don't need party linkage) — but worker-wallet
provisioning should link to a party from day one rather than being
backfilled, so sequence W-UI1 to start once A3.1 exists even though it
could technically start earlier. (A3.1 was already done by the time
W-UI1 started, so this was moot in practice.)

**W-UI1 (upload/pre-flight/batch status) done and live-verified in the
wallet-app repo** — full design + phase tracking lives in wallet-app's
own `docs/wps-ui-screen-flow-tracker.md` (this tracker only points to it,
per the "each repo tracks its own detailed work" convention). Summary:
real `Phoenix.LiveView` file upload (a first for wallet-app), a new
`WalletWps.Ingestion` orchestration module (no context/facade existed
before), a new minimal `wallet_wps_beneficiary_links` table + store
(closes a real gap — there was no employee→wallet-account mapping
anywhere, so no salary credit could ever have posted), and real wiring
of `PostSalaryCredit`'s `beneficiary_resolver`/`ledger_poster` seams
(previously untested-in-production callbacks) to `WalletLedger.Commands.
ApplyCredit`. Live-verified end-to-end (real upload → parse → pre-flight
→ post → real ledger credit landing in a real account → exception
correctly queued for an unlinked employee → re-run proven idempotent),
4/4 new tests passing, 233/233 passing on every shared file touched
(`Policy`, `AccessToken`, `LiveViewCase`, `MerchantAdminLive`) — zero
regressions. Found and fixed 4 real bugs along the way, including a
missing `wallet_web` → `wallet_wps` dependency that had never been
exercised, and a debit-normal ledger sign convention that the very first
real caller of `ApplyCredit` in this codebase's history surfaced. See
the wallet-app tracker doc for full detail.

**W-UI2 (exception queue + maker-checker) done and live-verified** —
`SalaryCredit.mark_retrying/1` (`:failed -> :pending`, closed the
previous one-way-terminal gap), `ExceptionsLive` (retry + inline
beneficiary-link), and wallet-app's first-ever real maker-checker
pattern: `wallet_wps_refund_requests` + `Commands.RequestEmployerRefund`/
`DecideEmployerRefund` + `ApprovalsLive`, deliberately scoped to
*never-settled* (`:posted`, not `:settled`) credit refunds only — not the
deferred post-payment worker-clawback question from §7 Q2. Self-approval
is rejected both in the UI and, independently, at the command layer.
Live-verified: real exception → real beneficiary link + retry → real
ledger credit → real refund request → self-approval genuinely rejected →
different-user approval → **real `WalletLedger.Commands.ReversePosting`
reversal** (asserted via account balance, not just a status flag) →
separate reject-path test. Also found and fixed a real, silent W-UI1 bug:
the new `wallet_wps_beneficiary_links` table's `correlation_id` schema
field had no matching DB column, so every beneficiary-link DB write had
been silently failing since W-UI1 shipped (ETS stayed correct; the
write-through's "DB is durable" contract didn't). 4/4 new tests passing,
zero regressions (`Policy` 77/77, full `wallet_web` suite 829 tests/126
pre-existing unrelated failures — same baseline as W-UI1). **Manually
browser-verified 2026-07-13** — login + admin console confirmed working.
Getting there needed an environment fix, not a code fix: an unrelated
process was squatting on `127.0.0.1:24000` specifically (not VS Code's
own port-forwarding, which was empty — some other stray local process),
silently swallowing all `localhost` traffic even though the real server
logged a clean boot; resolved by closing/reopening VS Code and
restarting the dev server. See wallet-app's own tracker doc for the full
diagnostic trail if this recurs.

### Phase P-UI1..4 — Prepaid 🔄 P-UI1/P-UI2/P-UI3 done (2026-07-13/14), P-UI4 pending
Per ops plan §3.2. Builds on wallet-app's existing `wallet_accounts`/
`wallet_ledger`/`wallet_cards`. A3.1 (Party Registry) is already done —
same "not a hard blocker in practice" situation WPS was in. Phases:
P-UI1 program mgmt + load flow → P-UI2 load recon + exception queue →
P-UI3 expiry/dormancy dashboards → P-UI4 KYC step-up UX. Full screen-flow
design doc written in the wallet-app repo before implementation started
(`docs/prepaid-ui-screen-flow-tracker.md`), same discipline as
`wps-ui-screen-flow-tracker.md`.

**P-UI1 (program management + load flow) done and live-verified.** User
answered 3 open design questions before build started: (1) implement the
negative-balance-policy config key now (per-program field, not a global
setting — `allow_and_collect`/`decline_to_exception`/`write_off_threshold`,
config-only in this phase since load flow is credit-only and has no debit
path to enforce it against yet); (2) make load channel tagging available
now including payment-gateway/bank-rail options (a real, separate
integration doesn't exist yet — this is the data model only, flagged
explicitly); (3) escheatment left to the builder's own judgment (no
written product spec exists) — decided as a dormancy-plus-threshold
read-only candidate flag, never an automated fund transfer (a real legal
process, always manual/ops-reviewed).

Real architecture finding mid-build: `wallet_ledger` already depends on
`wallet_accounts` in this umbrella, so the new `PrepaidProgram`/
`PrepaidLoad` domain data had to stay in `wallet_accounts`, but the actual
`ApplyCredit` call had to move to `wallet_web` (which already legitimately
depends on both) to avoid a circular umbrella dependency — confirmed via
`mix.exs`/grep before building, not discovered by a broken build. Also
found that `WalletProductType.min_kyc_tier` (an integer 0-3 captured on
the existing product-type Settings screen) is never actually read or
enforced anywhere in the codebase — real tier limits key off
`WalletAccounts.Account.tier`'s real 3-value atom instead.

2 more real, pre-existing bugs found live-testing this phase (first real
exercise of both code paths, same recurring pattern as WPS): the admin
user-search directory crashed on a `KeyError` for every seeded back-office
account (fixed, plus a genuinely more robust ETS-ownership fallback
added); and `String.to_existing_atom/1` on two `<select>` conversions
raised in a fresh test process (fixed to explicit literal-atom mappings).
Negative-balance policy (ops-plan Q1, answered "configurable per region/bank") is
shared with Debit — implement once, both products consume the same
config key.

**P-UI2 (load-channel recon + exception queue) done and live-verified.**
Real finding flagged before building: no external payment-gateway/bank-rail
integration exists anywhere in wallet-app (confirmed, not assumed) —
rather than fake a live channel, P-UI2 builds the two things that are
real and useful regardless: a recon-file ingestion + matching engine
(ops uploads a CSV shaped like a real provider settlement file; ready to
receive a real feed later without a rewrite) and an exception queue for
unmatched rows — the literal "failed load" scenario (money moved per the
channel, no wallet credit exists). Added `external_reference` to
P-UI1's `PrepaidLoad` (required for any non-admin-manual channel — the
only real key a recon file can match against) as a small, additive
change to the already-shipped Load Funds screen. Deliberately no
automated remediation on a mismatch — always a human "mark reviewed"
decision, same money-movement caution as everywhere else this session.
1 real bug found live-testing (a mismatched accumulator key between the
import module and the record's own status atom — `KeyError` on the
first unmatched row of the first real test). 4/4 new tests, zero
regressions — same 124-failure baseline as P-UI1.

**P-UI3 (expiry/dormancy dashboard) done and live-verified.** Researched
first: no `last_activity_at` field exists on any wallet record, and the
DB-only transaction table has no ETS wrapper (would be untestable here);
real "last activity" is computed from `WalletLedger.LedgerStore`'s own
ETS entries instead (already flagged by that store's own author as a
scale-limited stopgap headed for a real DB-query replacement — riding on
debt this codebase already knowingly carries, not adding new debt).
Added `WalletProductStore.list_all/0` (a real, small gap — no
all-wallets scan existed, following the same pattern 41 other stores
already use). Deliberately dropped the ops-plan's "sweep job" from the
outline — a sweep job would only be useful if it *did* something (e.g.
apply a dormancy fee), and no fee-deduction command exists anywhere
(P-UI1's load flow is credit-only by design); the dashboard computes
dormancy/escheatment on demand at read time instead, always accurate,
never stale. "Upcoming expirations" is explicitly labeled an estimate,
not a real remaining-balance calculation — no per-load FIFO/tranche
tracking exists to know if a specific loaded amount has already been
spent. Live-verified the actual point of the feature: the very same real
wallet transitions from not-dormant → dormant → an escheatment candidate
purely by advancing the report's clock past the program's real
configured thresholds (89 days: not yet; 90: dormant; 120: also a
candidate) — proving the computation itself is correct, not just that a
canned status renders. 8/8 new tests, zero regressions — same
124-failure baseline as P-UI1/P-UI2.

### Phase KYC-P1..4 — Dynamic KYC Module (repo: `wallet-app`) ✅ Done (2026-07-16, KYC-P1..P4 all complete)
New module, not in the original ops-plan — user request, modeled after a
working Laravel reference implementation (`MerchantManagementSystem`),
researched before designing. Originally scoped for vmu_core (see A3.4/A3.5
above); moved to wallet-app after confirming vmu_core has no customer/
merchant-facing UI at all to render a KYC form against — every real
consumer (customer self-serve, merchant self-serve, admin review) is a
wallet-app screen. Full design in `wallet-app/docs/kyc-module-design-tracker.md`.

Builds a genuine dynamic form builder (admin-defined fields/types/
validation/conditional logic — 16 field types incl. repeatable "group"
fields, matching the reference) as a **new `apps/wallet_kyc` app**, with
one deliberate improvement over the reference: a single shared
`kyc_requests` table for every product (`product_scope` is a free string
tag), not the reference's per-product table forking (its "loan" product
literally duplicated the whole table+controller rather than reusing the
mechanism). Extends, does not replace, wallet-app's existing
`WalletCompliance.KycCase` state machine — the new module drives it
underneath on submit/approve so every existing consumer (customer
dashboard KYC widget, admin user-detail overview tab) keeps working
unchanged. Real OCR integration wired to a running local OCR server
(`localhost:4000/api/detect_text`) as the module's first provider
adapter. Explicitly out of scope, flagged not assumed: LSEG/sanctions
screening, country-risk tiers, credit scoring (real in the reference but
a separate concern); a live cross-repo write into vmu_core's
`Party.KycAttainment` (the two repos don't share a database and no event
bridge is running); a dedicated merchant-portal screen (merchants
currently share the customer KYC screen via a KYB type, unchanged here).

Phases: KYC-P1 (schema + method/field builder admin UI) → KYC-P2
(submission/review workflow, real customer + admin screens) → KYC-P3
(conditional logic + OCR provider) → KYC-P4 (per-product method
assignment). See the wallet-app doc for the full phase tracker.

### Phase D-UI1..4 + D4 Recon — Debit (repo: `wallet-app`, + a new vmu_core-side FAS adapter) 🔄 D-UI1 done (2026-07-16), D-UI2..4 pending
Per ops plan §3.3. Prepaid dependency now satisfied (P-UI1-3 done). The
"FAS integration design" blocker is this phase's own D-UI1 — full design
in `wallet-app/docs/debit-ui-screen-flow-tracker.md`: a genuinely new
real-time synchronous bridge between vmu_core's FAS (authorization hot
path) and wallet-app's `WalletLedger`, since neither side has ever had
this — confirmed via research, not assumed (no balance-sufficiency check
exists anywhere in `wallet_ledger`, no hold-lifecycle model, `LogoParameter.
product_type` is a dead metadata field never read by FAS's authorization
pipeline). Scope decisions (AskUserQuestion, 2026-07-16): build the bridge
for real on both sides (not a mock) since both services already run in
this environment; a separate Debit-specific negative-balance policy (not
a reuse of Prepaid's, since Prepaid's was never actually enforced against
a debit path); overdraft in scope for v1; funding internal-transfer-only
for v1. Includes the cross-system reconciliation workstream (D4) as a
go-live gate, not a follow-up — folded into D-UI1's auth-hold monitor
phase since D4 needs real holds to reconcile against.

### Phase B-UI1..4 — BNPL ⬜ Pending 🔒 (blocked on Q3 answer + A1 merchant API + A3 borrower identity)
Per ops plan §3.4. **B-UI2 (refund/return workbench) additionally blocked
on §7 Q3** (BNPL return/refund state machine — still unanswered).

---

## Parked / To-Do (deliberately deferred, not forgotten)

1. **W-UI4 — WPS Regulator Report + SLA Tile.** Parked 2026-07-13 per
   user direction to move to Prepaid instead. Resumption criteria:
   product/business answers the regulator transmission-format/channel
   question (tracker doc §8/§10 in wallet-app's own
   `docs/wps-ui-screen-flow-tracker.md`) — don't build the extract
   against a guessed format. The SLA-tile half doesn't strictly need
   that answer and could be split out and started independently if
   ever prioritized ahead of the regulator-extract half.
2. **A3.4/A3.5 — KYC attainment + provider adapters.** Parked
   2026-07-13 per user direction, market-gated (India CKYC etc.),
   needs separate planning before starting.
3. **wallet-app coordination items** (from #4 below) — a real
   consuming subscriber for A3.3's outbound party-flag events,
   wallet-app's own `AdminAuth` wiring against A2's mock-IdP-verified
   OIDC flow, and wallet-app-side backfill into parties. Not blocking
   anything currently in progress, but real gaps someone needs to pick
   up eventually.
4. **Real IdP credentials for A2** — currently verified only against a
   self-hosted mock IdP; needs a real vendor tenant (Okta/Azure AD/
   Keycloak/Auth0) to prove production readiness.

---

## Open items blocking phase starts (not yet answered)

1. ~~**A1.1 auth scheme**~~ — ✅ resolved 2026-07-12: ASM service-account
   tokens, built and verified (see A1 above).
2. **§7 Q3** — BNPL return/refund state machine (blocks B-UI2 only).
3. ~~**A2 scope**~~ — ✅ resolved 2026-07-13: OIDC, mock-IdP-verified,
   vmu_core side only (see A2 above).
4. **wallet-app coordination** — a real *consuming* subscriber for A3.3's
   outbound events, wallet-app's own `AdminAuth` wiring against A2's IdP,
   and any wallet-app-side backfill into parties all still require
   wallet-app-side work; confirm who executes that (this session can
   write to the wallet-app repo directly, but changes there should be
   coordinated with however wallet-app's own team/process currently tracks
   its work — its `docs/phase-tracker.md` and 15-phase history suggest
   active parallel development). vmu_core's side of all three is now
   built and real (`Party.Backfill`, `Party.FlagPropagation` +
   `FlagSubscriber`, `ASM.OidcClient`) — only the cross-repo wiring
   remains.
5. **Real IdP credentials** — A2's OIDC adapter is verified against a
   self-hosted mock IdP (real crypto, real protocol flow) but not yet a
   live vendor tenant. Needs a real Okta/Azure AD/Keycloak/Auth0
   client_id+secret+issuer to prove end-to-end against production
   infrastructure.

## Overall — as of 2026-07-13

| Track | Phases | Done |
|---|---|---|
| Track 1 (vmu_core) | V-UI1a ✅, F1 ✅, F-UI1 ✅, F2/F3 ✅, F-UI2/F-UI3 ✅ | **5/5 — Track 1 complete** |
| Track 2 (foundational) | A1 ✅, A3.1 ✅, A3.2 ✅, A3.3 ✅, V-UI1b ✅, A2 ✅ (A3.4, A3.5 ⬜) | **6/8** |
| Track 3 (wallet-app) | WPS: W-UI1 ✅, W-UI2 ✅, W-UI3 ✅ (W-UI4 parked); Prepaid: P-UI1 ✅, P-UI2 ✅, P-UI3 ✅, **P-UI4 ✅ (satisfied by KYC-P4's Prepaid step-up flow, 2026-07-16)**; Debit: **D-UI1 ✅** (D-UI2..4 ⬜ + D4); BNPL×4 | 8/17 |
| Track 3 addendum (wallet-app) | **KYC module** (not in original ops-plan): KYC-P1 ✅, KYC-P2 ✅, KYC-P2b ✅, KYC-P3 ✅, KYC-P4 ✅ | **4/4 — complete** |

**Session summary (2026-07-12/13):** 10 phases built and live-verified
against real Postgres or real HTTP calls — F1 (2 real HCS enforcement
bugs fixed: DAILY_CAP, cash-access), V-UI1a (virtual card issuance, incl.
a genuinely new `PanGenerator`), A1 (the vmu_core API layer's first
vertical slice), A3.1 (the Party Registry — the direct answer to the
customer/KYC architecture concern), F-UI1 (HCS's first-ever admin UI —
company CRUD + facility-limit-change maker-checker flow), F2/F3 +
F-UI2/F-UI3 (fleet vehicle sub-accounts, driver assignment history,
`LimitController` generalized to enforce either card kind, vehicle
roster + spend reporting UI), A3.2 (backfilled the 10 real pre-existing
dev customers into the Party Registry — the actual delivered data, not
smoke-test residue), A3.3 (CIF FR-008's `Customer.status` field +
two-directional flag propagation), V-UI1b (the real cardholder-facing
virtual-card capability: issue + one-time-reveal credential API, a
genuinely new `CTA.CredentialVault` ephemeral store, and the first-ever
`HSM.generate_cvv/3`), and A2 (real OIDC operator login — a self-hosted
mock IdP with genuine RS256 signatures/JWKS since no real corporate IdP
exists in this environment, deliberately no JIT auto-provisioning of
operator roles from SSO claims). **9 real bugs found and fixed live
across these phases** (2 HCS enforcement gaps, 1 Party unique-constraint
gap, 1 `CompanyOnboarding` `.id`-vs-`.account_id` bug, 1 Ecto `dynamic/2`
placement error, 1 "UTC"-vs-"Etc/UTC" mismatch also latent in
`ConsolidatedStatementGenerator`, 1 LiveView notice-clobbering bug, 2
`Party.Registry.create_new/2` crash/transaction-nesting bugs, and 1
pre-existing, session-predating `Auth.audit/4` silent-failure bug — a
`varchar(20)` column silently truncation-rejecting any outcome string
over 20 chars, swallowed by its own `rescue` clause, never caught before
because no pre-existing outcome string was ever long enough to trigger
it) — every one found via live verification against real Postgres or
real HTTP calls, none via code reading alone. **Track 1 (vmu_core-only
work) is fully complete; Track 2 is 6/8.** The full
`test/vmu_core_web/live/admin/` suite passes 23/23, zero regressions.

**2026-07-13, Track 3 started:** W-UI1 (WPS upload/pre-flight/batch
status) done in the wallet-app repo — see that repo's own
`docs/wps-ui-screen-flow-tracker.md` for the full design + phase detail
(this tracker only summarizes). Real end-to-end verification: file
upload → parse → pre-flight report → post → **real ledger credit landing
in a real account** → exception correctly queued for an employee with no
wallet link → re-run proven idempotent. 4 more real bugs found and fixed
(a missing cross-app dependency, a ledger sign-convention mismatch in the
first-ever real caller of `ApplyCredit`, a missing MFA test-claim option
across the whole codebase's test infra, a fragile relative upload path).

**2026-07-13, W-UI2 done:** exception queue + wallet-app's first-ever
maker-checker pattern (employer refund requests), both live-verified —
see above. 1 more real bug found and fixed (W-UI1's beneficiary-link
table was silently never reaching MySQL due to a missing DB column).

**2026-07-13, W-UI3 done:** Employer roster — `Employer`/`EmployerStore`
(canonical employer record, keyed by the same free-text `employer_id`
string every other WPS record already uses, not a new generated ID),
`EmployersLive` (list/create, employee roster add/revoke/bulk-CSV-import,
inline funding-check status), and an additive `<datalist>` autocomplete
on `FilesLive`'s employer field (not a breaking dropdown — still
accepts any employer_id, matching every existing test/flow). Live-
verified end-to-end including the actual point of the feature: after
building a roster via the UI, a subsequently-uploaded WPS file for that
employer posts with **zero exceptions and zero manual "Link
beneficiary" steps**. Also confirmed (while migrating this phase's own
new table) that W-UI2's `wallet_wps_refund_requests` migration had never
actually been applied to the dev DB either — same latent-bug pattern as
W-UI1's, fixed by just running it; no code change needed. 3/3 new tests,
zero regressions (WPS+Policy 71/71, full suite 832 tests/126 pre-existing
unrelated failures, same baseline as W-UI1/W-UI2).

**2026-07-13, W-UI4 parked per user direction; moving to Prepaid
(P-UI1..4) next** — per the ops-plan's own priority list, Prepaid is the
correct next Track 3 item regardless (item #10, right after WPS in the
plan's own sequencing — "unblocks WPS fully; also the direct precedent
Debit builds on"). See the "Parked / To-Do" list below for W-UI4's
resumption criteria.

**2026-07-13/14, P-UI1 (Prepaid program management + load flow) done** —
see the Phase P-UI1..4 section above for full detail: user answered 3
open design questions before build (negative-balance-policy config now,
load-channel tagging now, escheatment left to builder judgment); found
`wallet_ledger` already depends on `wallet_accounts` (avoided a circular
dependency by placing `ApplyCredit` orchestration in `wallet_web`
instead); found `WalletProductType.min_kyc_tier` is never actually
enforced anywhere, so real tier limits key off `Account.tier` instead;
found and fixed 2 more pre-existing bugs live-testing (an admin
user-search `KeyError` crash, a fragile `String.to_existing_atom/1`
pattern). Live-verified: real program with tiered limits → real load
within limits posts a real ledger credit → over-max and cumulative
daily-cap breaches both rejected with the specific limit named → a
wallet with no program attached loads unlimited with an explicit
banner. 6/6 new tests, zero regressions — full suite actually improved
to 124 pre-existing failures (down from 126, the `UserData` crash fix
incidentally fixed 2 unrelated tests too).

**2026-07-14, P-UI2 (load-channel recon + exception queue) done** — see
the Phase P-UI1..4 section above for full detail: confirmed no real
payment-gateway/bank-rail integration exists anywhere, so built the real,
useful mechanism (CSV recon ingestion + matching + a human-reviewed
exception queue) rather than faking a live channel; added
`external_reference` to P-UI1's `PrepaidLoad` as the real key recon
matching needs. Live-verified: real channel-tagged load with an external
reference → real recon file with one matching and one unmatched row →
unmatched row confirmed as a real "failed load" exception → marked
reviewed by a real actor → a malformed CSV row tolerated, not fatal to
the batch. 4/4 new tests, zero regressions, same 124-failure baseline.

**2026-07-14, P-UI3 (expiry/dormancy dashboard) done** — see the Phase
P-UI1..4 section above for full detail: real last-activity data comes
from `LedgerStore`'s ETS entries (the only testable source — the DB-only
transaction table has no ETS wrapper); dropped the outline's "sweep job"
since nothing exists yet to act on a dormancy status (no fee-deduction
command anywhere) — computed on demand instead. Live-verified the same
real wallet transitioning not-dormant → dormant → escheatment candidate
purely by advancing the report's clock past the program's real
thresholds. 8/8 new tests, zero regressions, same 124-failure baseline.

**2026-07-14, new KYC module requested and designed — placement reversed
from vmu_core to wallet-app same day.** Not in the original ops-plan:
user asked for a dynamic KYC form/method builder (admin-defined fields,
16 field types, conditional logic, per-product configurable), modeled
after a real working Laravel reference app (`MerchantManagementSystem`)
— researched thoroughly before designing (real `kyc_methods` JSON-field
template, real `kyc_requests` frozen-field-snapshot submissions, real
weakness noted: the reference forks a whole separate table+controller
per product instead of reusing one mechanism). Initially designed for
vmu_core (API-first, `Party.KycAttainment` integration point already
existed) — **reversed after the user directly challenged the placement**
("the users are in my wallet-app side not in vmu_core"). Re-verified via
router grep: vmu_core's entire web surface is `/visionplus/admin/*`
(operator console) + machine APIs — **zero customer- or merchant-facing
UI exists in vmu_core**, so wallet-app is the only repo that can actually
render a form for this. Final design: new `apps/wallet_kyc` app in
wallet-app, one shared `kyc_requests` table (the deliberate improvement
over the reference), driving wallet-app's existing (confirmed real but
bare) `WalletCompliance.KycCase` state machine underneath rather than
replacing it, real OCR integration against the user's already-running
local OCR server (`localhost:4000/api/detect_text`). vmu_core's original
design doc marked SUPERSEDED (kept, not deleted) pointing to the new one
at `wallet-app/docs/kyc-module-design-tracker.md`. A3.4/A3.5's original
scope (config-driven recognition rules, market-gated provider adapters)
remains separate and still parked. Design/planning only this session —
KYC-P1 (schema + method builder admin UI) not yet started, awaiting
explicit go-ahead.

**2026-07-14/16, KYC-P1 through KYC-P4 all built and live-verified**
(KYC-P1/P2/P2b/P3 completed 2026-07-14/15; KYC-P4 completed 2026-07-16)
— see `wallet-app/docs/kyc-module-design-tracker.md` §10 for full detail
on each phase. Headline results: a genuine dynamic form/method builder
(`apps/wallet_kyc`, 16 field types, repeatable groups, multi-step
wizard forms, conditional field visibility, real OCR execution against
the user's OCR server at `78.47.213.212:4000`) driving wallet-app's
existing `WalletCompliance.KycCase` state machine underneath rather
than replacing it. **KYC-P4 (per-product method assignment)** closed
the phase by finding and fixing a real gap uncovered mid-design: the
customer's own self-deposit screen never enforced Prepaid tier caps at
all (only the *admin* manual-load screen did) — wired real enforcement
there via the existing `LoadFundsOrchestrator`, added a
`:customer_self_load` load channel, and built a full "load rejected for
breaching a tier cap → step-up KYC → admin approves → account tier
bumped `standard→premium→business` → the same load succeeds" flow, real
end-to-end verified against dev MySQL (9/9 checks). Several real
pre-existing bugs found and fixed across the whole KYC-P1..P4 arc,
including three instances of this session's recurring "write silently
failed, ETS masked it" pattern (a missing DB column, a DB CHECK
constraint that never matched the domain, and a stores-never-warm-up-
from-DB-on-restart gap) — see the wallet-app doc for the complete list.
One more instance of that same bug class was found during KYC-P4's
verification but is **out of scope, flagged not fixed**: the
`WalletDatabase.Schemas.Accounts.Account` Ecto schema declares columns
that don't exist in the real `accounts` table, so any plain
`Repo.all/Repo.get` against that schema crashes — `AccountStore`'s own
narrower schema is unaffected, which is why nothing else has hit this.
**The KYC module (KYC-P1..P4) is now complete** — remaining open items
are exactly the ones flagged in the design doc's §9 (Party Registry
bridge, LSEG/screening, merchant portal, vmu_core API consumer, WPS
worker onboarding), none blocking, all deferred pending a real
requirement.

**2026-07-16, Debit design complete + D-UI1 (hold lifecycle + real-time
FAS↔wallet-app bridge) done** — see `wallet-app/docs/debit-ui-screen-flow-
tracker.md` for full detail. Four scope decisions made via AskUserQuestion
before designing: build the real-time authorization bridge for real on
both sides (not mocked, since both services already run in this
environment); a separate Debit-specific negative-balance policy (not a
reuse of Prepaid's, which has never been enforced against any real debit
path); overdraft in scope for v1; funding internal-transfer-only for v1.
Real findings from research, not assumed: no balance-sufficiency check
existed anywhere in `wallet_ledger` (a hold could drive balance negative
with zero checks); no hold-lifecycle model existed (a hold was
indistinguishable from a completed transfer); `LogoParameter.product_type`
was genuinely dead metadata, confirmed via grep, never read by FAS's
authorization pipeline; `GetSubWalletBalance`'s `available` field is
unconditionally floored at zero (fine for every prior product, which
never went negative — Debit is the first that can, so its own check reads
`total` instead). Built: `WalletLedger.AuthHold`/`AuthHoldStore` (hold
lifecycle), `CheckDebitAuthorization` (the missing sufficiency+overdraft
check), `AuthorizeCardDebit`/`CaptureDebitHold`/`ReleaseDebitHold`/
`ExpireOrphanHolds` (all wrapping the existing `AuthorizeDebit` without
modifying it, so its 3 existing unrelated callers — P2A transfers,
withdraw requests, customer transfers — are untouched), a new
`POST /api/v1/debit/authorize` bridge on wallet-app's side (single
shared-secret caller, decline is always `200` never 4xx/5xx), and on
vmu_core's side a new `VmuCore.CMS.WalletDebitAdapter` + a routing branch
in `VmuCore.FAS.Authorization.run_authorization/1` that reads
`product_type` and routes DEBIT-tagged transactions to the adapter
instead of the internal credit-line check — the credit-card path is
byte-for-byte unchanged. **Live-verified against two genuinely separate
real running processes** (a real `mix phx.server` wallet-app instance +
a separate vmu_core script): real fund → real over-limit decline (200,
RC 51, never a 4xx) → real approval + real hold + real balance debit
(confirmed via direct MySQL query) → real 401 on a missing shared secret.
**A real, valuable finding from that live test:** a client-side timeout
does not mean the server didn't complete the hold — one call that the
vmu_core-side client reported as "declined (timeout)" had, in fact,
succeeded on the wallet-app side (confirmed `active` in the DB). This is
retuned (300ms → 500ms) and explicitly documented as a genuine,
irreducible distributed-systems risk — exactly what the D4 orphan-hold
sweep/cross-check report exists to catch, not something a timeout value
alone can solve. **Flagged, not solved in this phase:** `resolve_account/1`
's PAN→account_id lookup is hardwired to `VmuCore.CMS.Account` (requires
`credit_limit`, structurally credit-shaped) — a real debit card's PAN
can't resolve through it without a fake CMS.Account row; full card-level
routing is a follow-up paired with actual debit card issuance. 13 new
tests (9 `wallet_ledger` domain + 4 `AuthHoldsLive`), zero regressions.
All smoke-test data cleaned up, confirmed 0 residual rows. D-UI2
(negative-balance policy + overdraft config), D-UI3 (dispute handoff),
D-UI4 (overdraft management screen) remain, each with their own task
table to be written at phase start per the design doc's own discipline.
