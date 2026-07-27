# Way4 Parity Plan — Phase 1: Card Portfolio Expansion — Tracker

> Companion to [`Way4_Parity_Implementation_Plan.md`](Way4_Parity_Implementation_Plan.md)
> §2 "Phase 1 — Card portfolio expansion". Namespaced separately from
> `docs/phase1-implementation-spec.md` (the *original* Phase 1 of the
> unrelated 8-phase build tracker in `docs/phase-tracker.md`) — same
> "don't collide with the other Phase 1-8" discipline `docs/fas/
> FAS_Implementation_Tracker.md` already established for FAS-P1..P8.
> Statuses: `✅ Done` · `🔄 In Progress` · `⬜ Pending` · `🔴 Blocked`

Detailed per-file build logs live in each owning module's own tracker
(`docs/cta/CTA_Gap_Implementation_Tracker.md`, a new `docs/hcs/
HCS_Gap_Implementation_Tracker.md`, etc.) — this doc is the cross-cutting
status/sequencing overview for the whole phase, matching how the parent
Way4 plan points at each module's own tracker for Phase 0.

---

## Sequencing decision (2026-07-25)

Before starting, checked whether any of the 7 items already had real work
sitting lost in `Avenza` — the same discovery that found COL/LMS/ASM-SSO
lost the same way in Phase 0 (7 confirmed instances by the end of that
phase). Findings changed the sequencing:

| Item | Real Avenza work? | Verdict |
|---|---|---|
| Virtual Cards | ✅ Yes — complete, self-contained vertical slice (PAN gen, credential vault, issue+reveal API), no `wallet_*` dependency | **Port** |
| Corporate Cards | ✅ Yes — facility-limit maker-checker + daily-cap/cash-access controls, additive to vmu_core's already-solid HCS baseline | **Port** |
| Fleet Cards | ✅ Yes — complete v1 slice (vehicle/driver/fleet-card/onboarding/report), vmu_core already has the migration | **Port** |
| Debit | ⚠️ Yes, but dead/stubbed — Avenza's own code comments (2026-07-22) call it unexercised, self-flagged as superseded, with known unfixed bugs | **Build native, don't port** |
| Prepaid | ⚠️ Yes, but depends on the `wallet_*` apps (`WalletLedger`, `wallet_accounts`) that don't exist in standalone vmu_core — contradicts this very phase's own "native FAS→TRAMS→GL, no product bypasses this pipeline" principle | **Build native, don't port** |
| BNPL (merchant) | ❌ No — genuine gap in both repos | Blocked on `MerchantManagementSystem` integration contract |
| Tokenization/Apple/Google Pay | ❌ No — genuine gap in both repos | Blocked on vendor decision (Way4 plan §3 Decision 1) |

**Confirmed sequencing with user**: Virtual Cards → Corporate Cards →
Fleet Cards → Debit (native) → Prepaid (native) → BNPL/Tokenization last
(both externally blocked, not started until their respective decisions
land).

---

## 1. Virtual Cards — finish the issuance flow

**Status: ✅ Done (2026-07-25)**

Port from Avenza (`apps/vmu_cta`), re-verified against vmu_core's own
current schema/conventions before trusting any of it, same discipline as
every prior re-port this session.

**Scope correction found before building the API layer**: Avenza's
`VirtualCardController`/`/api/v1` existed specifically for `wallet-app`
to call remotely (service-account bearer auth) — that layer doesn't
exist in vmu_core at all, and there's no external caller for it here.
Confirmed with user: expose issuance/reveal through the admin console
instead (`AccountComponent`'s existing Cards tab, which already hosts
every other card-lifecycle action), not a new REST API with no consumer.

| # | Task | Avenza source | Status |
|---|---|---|---|
| V1.1 | `CTA.PanGenerator` — BIN + random digits + Luhn check digit, SHA-256 pan_token | `vmu_cta/lib/vmu_core/cta/pan_generator.ex` | ✅ |
| V1.2 | `CardLifecycle.issue_new/2` — general new-card issuance (PRIMARY/SUPPLEMENTARY/VIRTUAL) | `vmu_cta/lib/vmu_core/cta/card_lifecycle.ex` | ✅ |
| V1.3 | `CTA.CredentialVault` — ETS-backed, exactly-once reveal, TTL sweep; registered in `VmuCore.Application`'s supervision tree | `vmu_cta/lib/vmu_core/cta/credential_vault.ex` | ✅ |
| V1.4 | `CardLifecycle.issue_virtual_with_credentials/2` — issue + auto-activate + CVV + vault stash | `vmu_cta/lib/vmu_core/cta/card_lifecycle.ex` | ✅ |
| V1.4a | `HSM.generate_cvv/3` (`CW` command) — did **not** exist in vmu_core's `VmuCore.FAS.HSM` behaviour at all (only `verify_cvv/4`); added to the behaviour + `SoftHSM` (reuses the existing private `compute_cvv/4`) + `ProductionHSM` (real `CW` REST call, built from the manual, mirrors `CY`'s shape) + `SocketHSM` stub | new, not in Avenza's scope either | ✅ |
| V1.5 | Admin UI — "Issue New Card" action + exactly-once "Reveal" button on VIRTUAL cards, added to the existing `AccountComponent` Cards tab (not a new component) | new (replaces Avenza's `VirtualCardController`) | ✅ |
| V1.6 | Real tests | new | ✅ 21/21 (5 `pan_generator_test.exs`, 3 `credential_vault_test.exs`, 8 `card_lifecycle_issue_test.exs`, 2 `account_component_card_issue_test.exs`, + coverage from fixing the bug below) |

**Real pre-existing bug found and fixed**: `AccountComponent`'s
top-level `<%= if @active_action != :none do %>` block rendered
`render_action_panel/1` for **every** action, including all `card_*`
ones — which `tab_cards/1` **also** renders in its own gated block. Every
existing card action (`card_activate`/`card_block`/`card_unblock`/
`card_replace`/`card_renew`/`card_channels`) has been double-rendering
its panel since this file was written; never caught because it had zero
tests before this item's own test suite (the first for this 2900+-line
component) hit it via the new `:card_issue` action. Fixed by excluding
card-level actions from the top-level condition — they render once,
correctly, inside the Cards tab.

Full CTA/CMS/FAS/ASM/COL/admin regression before and after: same 10
pre-existing, already-documented failures, zero regressions.

---

## 2. Corporate Cards

**Status: ✅ Done (2026-07-25)**

vmu_core's baseline (`HCS.Company`, `EmployeeCard`, `SpendingControl`,
`LimitController`, `ConsolidatedStatementGenerator`, `PaymentSweep`,
`CompanyOnboarding`) already matched Avenza closely — this item ported
the **additive** pieces.

**Found already-staged, untracked migrations**: `20260712000001` (adds
`daily_spend`/`daily_spend_date` to `hcs_employee_cards`) and
`20260712000005` (creates `hcs_facility_limit_changes`) already existed
in the working tree, already applied to both dev and test DBs — from an
earlier, never-finished attempt to re-port this same 2026-07-12 Avenza
work. No new migrations needed; the Ecto schemas just hadn't been
updated to use the columns yet.

| # | Task | Avenza source | Status |
|---|---|---|---|
| C1.1 | `HCS.FacilityLimitChange` schema (PENDING_APPROVAL/APPROVED/REJECTED) | `vmu_hcs/lib/vmu_core/hcs/facility_limit_change.ex` | ✅ |
| C1.2 | `HCS.FacilityLimitCommand` — `request/3`/`approve/2`/`reject/2`/`pending/1`, maker≠checker via `ModuleConfigEngine`, mirrors `COL.WorkoutCommand`'s pattern | `vmu_hcs/lib/vmu_core/hcs/facility_limit_command.ex` | ✅ |
| C1.3 | `LimitController`/`SpendingControl` — DAILY_CAP control type + per-transaction `daily_spend` tracking, cash-access check. Ported the Corporate-only slice of Avenza's diff (~235 lines total); the fleet-card generalization half is deferred to item 3, same file gets a second pass then | diff vs. vmu_core's current `limit_controller.ex` | ✅ |
| C1.4 | Admin UI — new `HcsComponent` (company list/create/detail, employee card + spending control read-only rosters, facility-limit-change request), ported from Avenza's 959-line `hcs_component.ex` (Corporate-only slice — its fleet vehicle/driver/report sections are deferred to item 3, same file gets a second pass then). Wired into `RolePermission`/`AdminLive`/`ApprovalInboxComponent` | `vmu_core_web/live/admin/hcs_component.ex` | ✅ |
| C1.5 | Real tests | new | ✅ 20/20 (9 `facility_limit_command_test.exs`, 8 `limit_controller_test.exs`, 3 `hcs_component_test.exs`) |

**Real pre-existing bugs found and fixed**:
- `CompanyOnboarding.onboard_company/1` and `add_employee_card/3` both
  referenced `parent_account.id`/`employee_account.id` — but `CMS.
  Account`'s real primary key field is `account_id`, not `id`. This
  function has never actually succeeded until this fix (no test existed
  to catch it, in either repo).
- `HcsComponent`'s `create_company_save` handler used `params["registration_no"]
  || "PENDING"` — `||` only catches `nil`, not the empty string an
  untouched HTML form field actually submits, so a blank field produced
  `registration_number: ""` and failed CORPORATE-tier validation. Found
  live by this item's own admin-UI test (a bug Avenza's zero-test version
  also has).
- `DAILY_CAP` was a schema-valid, documented `SpendingControl` type with
  no enforcement clause at all (silent no-op); `can_withdraw_cash`
  existed on `EmployeeCard` but was never read anywhere — every card
  could take cash regardless of the field.

Full HCS/CTA/CMS/FAS/ASM/COL/admin regression before and after: same 10
pre-existing, already-documented failures, zero regressions.

---

## 3. Fleet Cards

**Status: ✅ Done (2026-07-26)**

Confirmed all three fleet tables (`hcs_vehicles`, `hcs_driver_assignments`,
`hcs_fleet_cards`) plus the `hcs_spending_controls.fleet_card_id` FK were
already fully migrated and applied to both dev and test DBs — leftover
from the same earlier, never-finished re-port attempt that also left
item 2's migrations sitting untracked. Zero new migrations needed for
this item.

| # | Task | Avenza source | Status |
|---|---|---|---|
| F1.1 | Confirmed `hcs_vehicles`/`hcs_driver_assignments`/`hcs_fleet_cards` migration columns match Avenza's schema field-for-field (direct `\d` comparison against dev DB) | n/a — direct comparison | ✅ |
| F1.2 | `HCS.Vehicle`, `HCS.FleetCard` schemas | `vmu_hcs/lib/vmu_core/hcs/vehicle.ex`, `fleet_card.ex` | ✅ |
| F1.3 | `HCS.DriverAssignment` + `HCS.DriverAssignmentCommand` — current/history tracking, transactional close-then-open; `@repo Application.compile_env(...)` adapted to a plain alias, `DateTime.utc_now()` truncated to `:second` at both write sites (this app's non-usec `:utc_datetime` convention) | `vmu_hcs/lib/vmu_core/hcs/driver_assignment.ex`, `driver_assignment_command.ex` | ✅ |
| F1.4 | `HCS.FleetOnboarding` — `add_vehicle/2`, `add_fleet_card/3` (validates against shared company credit pool across employee+fleet allocations via `allocated_pool/1`, creates a synthetic `CMS.Account` per vehicle reusing the company's own parent customer_id) | `vmu_hcs/lib/vmu_core/hcs/fleet_onboarding.ex` | ✅ |
| F1.5 | `HCS.FleetReport` — `spend_by_vehicle/3`, `spend_by_driver/3`, `total_spend/3`, off the same `cms_ledger_entries` ledger `ConsolidatedStatementGenerator` already uses (same `inserted_at`-range convention). v1 scope explicitly: no fuel-line-item detail, doesn't split spend across mid-period driver reassignment — 100% attributed to the vehicle's *current* assignment (documented in the moduledoc, not silently dropped) | `vmu_hcs/lib/vmu_core/hcs/fleet_report.ex` | ✅ |
| F1.6 | `LimitController` generalized: `get_employee_card/1` → `get_active_card/1` returning `{:employee, card} \| {:fleet, card} \| nil`; `debit_limits/2`/`credit_limits/2`/`check_spending_controls/6` branch on a `card_schema/1`/`card_match` dynamic per kind. `SpendingControl` gained a `fleet_card_id` field + `"FLEET"` scope (DB column already existed via the same untracked migration) | shares item 2's `limit_controller.ex` diff | ✅ |
| F1.7 | Admin UI — `HcsComponent` second pass: Fleet Vehicles roster + "+ Add Vehicle" in company detail, new `:vehicle_detail` mode (fleet card issuance, driver assignment/history), Fleet Spend Report generator | `vmu_core_web/live/admin/hcs_component.ex` | ✅ |
| F1.8 | Real tests | new | ✅ 22/22 (7 `fleet_onboarding_test.exs`, 5 `driver_assignment_command_test.exs`, 4 `fleet_report_test.exs`, 4 fleet cases added to `limit_controller_test.exs`, 2 fleet cases added to `hcs_component_test.exs`) |

**Real bugs found and fixed while building this item**:
- `Ecto.Query`'s `dynamic/2` cannot be interpolated with `^` alongside
  plain `and`-joined conditions inside the same `where:` — the fix was to
  fold everything (including the kind-specific card-match clause) into a
  single combined `dynamic/2` before interpolating it once.
- `SpendingControl.changeset/2`'s `unique_constraint`-style test
  expectation was written against the wrong field: Ecto's
  `unique_constraint/2` attaches a composite constraint's error to the
  **first** field in the list (`:company_id` for `[:company_id, :vin]`
  on `Vehicle`), not the semantically "interesting" one — a test-authoring
  gotcha, not a code bug.
- A `FleetReport` test initially tried to "backdate" a ledger entry by
  setting `posting_date` alone; `inserted_at` (what period-range queries
  actually filter on, matching `ConsolidatedStatementGenerator`'s own
  convention) is set to real wall-clock time by `timestamps()` regardless
  — fixed by directly `Repo.update_all`-ing `inserted_at` for the
  out-of-window fixture row, the same technique `limit_controller_test.exs`
  already uses to backdate `daily_spend_date`.

Full-suite regression (230 tests, one pre-existing broken compile file
in `test/vmu_core/lms/points_lifecycle_test.exs` excluded — unrelated to
HCS, a stale `:entry_type` field reference predating this session):
same 10 pre-existing, already-documented failures (2 `FAS.
AuthorizationIntegrationTest`, 4 `CMS.InterestIntegrationTest`, 4 `COL.
WriteOffRecoveryTest`), zero regressions.

---

## 4. Debit Card Issuing (native build, not ported)

**Status: 🔄 In Progress — D1 (schema) done 2026-07-26, D2-D5 next**

Confirmed directly against Avenza's current code (not just the memory
of the earlier research pass) that `run_debit_authorization/1` really is
dead/unexercised — its own comments (CU-2, 2026-07-22) state zero
`logo_parameters` rows are tagged `"DEBIT"` anywhere, and it carries two
documented, never-fixed bugs (a Decimal-major/integer-minor unit
mismatch, a stale pre-CU-1 `wallet_product_id` assumption) plus a hard
dependency on `WalletLedger`/`WalletAccounts`, neither of which exist in
standalone vmu_core. "Build native" stands, confirmed not assumed.

Full design + 4 confirmed product/architecture decisions in
`docs/debit/DEBIT_Module_Requirements.md` §7-9: no overdraft in v1;
funding supports internal transfer **and** external bank transfer/cash
deposit, modeled as real records with a channel tag + reference but no
live rail call (no bank-rail integration exists in either repo); market
config reads the existing `BankParameter.regulatory_regime`/
`credit_reporting_format` cascade instead of hardcoding UAE, so an
RBI-regulated bank_id can coexist with a CBUAE one without code changes;
account model is a fully **separate schema** (`cms_debit_accounts`), not
a `cms_accounts` discriminator — `credit_limit` stays `NOT NULL` for
credit accounts, no shared-table nullable-field risk introduced.

| # | Task | Status |
|---|---|---|
| D1.1 | `CMS.DebitAccount` schema (own identity fields for the parameter cascade, `available_balance`, no credit_limit/OTB) | ✅ |
| D1.2 | `CMS.DebitFunding` schema (INTERNAL_TRANSFER/ADMIN_MANUAL/EXTERNAL_BANK_TRANSFER/CASH_DEPOSIT channels, external channels require a reference) | ✅ |
| D1.3 | `cta_cards.debit_account_id` — new nullable FK; `account_id` relaxed from NOT NULL. Found live: `cta_cards.account_id` has a real DB-level FK to `cms_accounts`, so a debit card can't reuse it — needed a parallel nullable FK, same pattern as `hcs_spending_controls.fleet_card_id`/`employee_card_id` (item 3). `CTA.Card.changeset/2` enforces "exactly one of account_id/debit_account_id" at the application layer | ✅ |
| D1.4 | `ParameterEngine.load_logo_parameters/0` — found `product_type` (CREDIT/DEBIT/PREPAID/...) was pure reference metadata, never cached/read by any business logic anywhere in standalone vmu_core (same finding the original 2026-07-11 requirements doc made, still true today) — fixed so `FAS.Authorization` can route by it without a DB round-trip | ✅ |
| D1.5 | Real tests | ✅ 15/15 (`debit_account_test.exs`, `debit_funding_test.exs`, `card_account_ref_test.exs`) |

| D2.1 | `CMS.DebitAccountOpening.open/1` | ✅ |
| D2.2 | `CMS.DebitFundingCommand.fund/1` — posts a real `cms_ledger_entries` DEPOSIT row (new liability-direction GL codes 1006/5001) + increments `available_balance`, same transaction. `LedgerEntry.transaction_code` gained `"DEPOSIT"` | ✅ |
| D2.3 | Real tests | ✅ 6/6 `debit_funding_command_test.exs` (internal transfer, accumulation across deposits, external-reference required+recorded, suspended-account rejection, duplicate-reference rejection, real balanced dr==cr ledger row with the right GL codes) |

**Reused, not reinvented**: `FAS.PendingHold` (the existing generic
credit-authorization hold table) has **no DB-level FK on `account_id`**
— confirmed before assuming it — so Debit's holds (D3) reuse it directly
rather than a new `DebitHold` schema.

## 4a. Foundational fix before D3 could work at all: PAN resolution (2026-07-26)

Found while investigating a real user-reported gap ("does the TRAMS
chargeback lookup handle debit transactions?"): standalone vmu_core's
**entire PAN→account resolution surface** was still on the pre-CU-1
model — every site resolved a PAN by querying `CMS.Account.pan_token`
directly, never `cta_cards` (the "unified card master" CU-1 made
canonical in the merged Avenza umbrella, 2026-07-22). That work never
carried back after the 2026-07-23 platform-of-record reversal — the same
"real work built once, lost on the reversal" pattern this session has
now hit 9 times (COL, LMS, ASM-SSO, Virtual/Corporate/Fleet Cards,
Debit's dead-code confirmation, and now CU-1 itself).

This directly blocked D3: `FAS.Authorization.resolve_account/1` returning
`{:error, :account_not_found}` for anything without a `cms_accounts` row
meant a debit card's PAN could never resolve during authorization at all.

**Fixed (re-ported CU-1's actual change, adapted for `Card` carrying
`account_id` OR `debit_account_id`, never both)**:
- `FAS.Authorization.resolve_account/1` — the auth hot path itself
- `TRAMS.VisaBaseII.handle_chargeback/1` — the literal gap that surfaced this

**Deliberately NOT fixed today — different shape of problem, own design
question, not a PAN-lookup swap**:
- `FAS.HotCardCache` — sources the lost/stolen/fraud blocklist from
  `cms_accounts.block_code`; `DebitAccount` has no block_code concept at
  all yet (only `status`). Extending hot-card blocking to Debit needs its
  own design pass, not a quick swap.
- `CTA.CardActivation` — `do_activate/2`'s entire body mutates
  `cms_accounts.account_status`/`cta_embossing_orders`/calls
  `AccountStateCoordinator.refresh/1` — a whole credit-account-status
  workflow, not just a PAN lookup. Debit card activation is its own
  future design question (likely D5).

## 4b. D3 — Authorization

| # | Task | Status |
|---|---|---|
| D3.1 | `CMS.DebitAuthorization.authorize/2` — atomic `available_balance` decrement (`UPDATE ... WHERE available_balance >= amount`, Postgres MVCC handles the race, no Horde GenServer needed — no OTB cascade to protect, unlike credit) | ✅ |
| D3.2 | `FAS.Authorization` — added `product_type` dispatch (`run_authorization/1` → `run_credit_authorization/1` \| `run_debit_authorization/1`); `run_debit_authorization/1` returns the same `{:approved,...}`/`{:declined,...}`/`{:error,...}` shape ASC returns, so `handle_asc_result/2` and everything downstream (risk check, `persist_async`, `PendingHold`, TRAM feed) work unchanged for Debit — confirmed by reading that code before writing this branch, not assumed | ✅ |
| D3.3 | `TRAMS.Oban.AuthExpirySweepJob.do_reverse/3` + `FAS.ReversalHandler.restore_otb/1` — both unconditionally called `AccountStateCoordinator.credit_open_to_buy/2`/`.reverse/3` on every released hold; branch on `DebitAuthorization.debit_account?/1` first | ✅ |
| D3.4 | Real tests | ✅ 10/10 (8 `debit_authorization_test.exs` incl. a real concurrent-authorization oversell test, 2 new `authorization_integration_test.exs` Debit cases) |

**Real bug caught before shipping, not after**: `DebitAuthorization.
authorize/2`'s first draft did `Decimal.sub(new_balance, amount)` on the
value `Repo.update_all`'s `select:` returned — but Ecto's `select:` on an
`UPDATE` compiles to Postgres `RETURNING`, which reflects the row
**after** the `inc:` already applied. Would have silently double-
subtracted every real authorization. Caught by reasoning through Postgres
semantics before running it, confirmed by the concurrency test's exact
expected final balance.

**Real regression caught by running the suite, not assumed clean**:
`resolve_account/1`'s fix broke 2 previously-passing `FAS.
AuthorizationIntegrationTest` cases — its own `seed_account/3` fixture
predates the unified card master and never issued a matching `cta_cards`
row. Fixed the fixture (issues a real card, matching how a real account
actually gets one now), confirmed the 2 already-known-broken baseline
failures in that file are a separate, unrelated, pre-existing bug
(`AccountStateCoordinator.authorize/3` returns a 4-tuple; `handle_asc_result/2`
only matches 3-tuples) — not something this fix touched or caused.

Full-suite regression: 261 tests, same 10 pre-existing failures, zero
regressions (one pre-existing broken compile file in `test/vmu_core/lms/
points_lifecycle_test.exs` excluded, unrelated, predates this session).

## 4c. D4 — Settlement posting

**Status: ✅ Done (2026-07-26)**

Fixed the exact gap flagged above. `SettlementPostingAdapter.confirm_one/1`
was 100% credit-shaped — `post_ledger/3` hardcoded credit GL codes,
`post_bucket/4`'s `PurchasePosting.post/1` does `Repo.get(Account, ...)`
which always returns `nil` for a `debit_account_id`, rolling back every
debit settlement confirmation.

| # | Task | Status |
|---|---|---|
| D4.1 | `do_confirm/3` now dispatches on `DebitAuthorization.debit_account?/1` first — `do_confirm_credit/3` (renamed, unchanged body) vs. new `do_confirm_debit/3` | ✅ |
| D4.2 | `InternalGlPoster.post_debit_purchase/5` — the exact reverse direction of D2's `post_debit_deposit/5` (DR 5001 deposit liability decreases / CR 1006 bank cash pays out). No new GL codes needed | ✅ |
| D4.3 | Debit's settlement confirmation does **not** touch `available_balance` or any balance-bucket equivalent — it was already decremented in real time at authorization (no OTB-then-settle two-phase model for this product, confirmed by a dedicated test). Settlement only makes the journal entry permanent and clears the hold | ✅ |
| D4.4 | Real tests | ✅ 4/4 `settlement_posting_adapter_debit_test.exs` — first-ever test coverage for `SettlementPostingAdapter` at all (ledger entry posts with correct GL direction, balance untouched at settlement, idempotent retry, `:not_found` for no match) |

Full-suite regression: 265 tests, same 10 pre-existing failures, zero
regressions.

## 4d. D5 — Card issuance + ops UI

**Status: ✅ Done (2026-07-26) — item 4 (Debit Card Issuing) now fully complete, D1-D5**

| # | Task | Status |
|---|---|---|
| D5.1 | `CTA.CardLifecycle.issue_new_debit/2` — mirrors `issue_new/2` exactly, issues against `debit_account_id` instead of `account_id`. Kept as its own function rather than made polymorphic since `DebitAccount` has no `emboss_name` denormal to default from (no embossing-order workflow exists for Debit yet) | ✅ |
| D5.2 | `CTA.Cards.by_debit_account/1` — parallel to `by_account/1`, needed for the admin UI's card roster | ✅ |
| D5.3 | Admin UI — new `DebitComponent` (account list/search/create, detail view with balance/funding-history/card-roster, fund action, issue-card action, activate/block/unblock reusing `CardLifecycle` directly). Wired into `RolePermission` (`debit` module, view/edit for SUPERVISOR/OPS/RISK/COMPLIANCE) and `AdminLive` (sidebar + routing) | ✅ |
| D5.4 | Real tests | ✅ 11/11 (8 `card_lifecycle_issue_debit_test.exs`, 3 `debit_component_test.exs` — account creation, full fund→issue→activate→block→unblock flow, external-channel reference validation) |

**2 real bugs found and fixed, confirming `activate/2`/`block/3`/
`unblock/2` "already work unchanged for debit" was asserted too early in
D3/D4's notes** — writing the actual first real test for debit card
activation caught what reasoning-by-analogy missed: `Cards.
sync_account_denormals/2` (called from every `transition/3`) and
`CardLifecycle.maybe_set_account_block/2`/`clear_account_block/1`
(called from `block/3`/`unblock/2`) all did `where: a.account_id ==
^card.account_id` — for a debit-issued card, `card.account_id` is `nil`,
and **Ecto forbids `field == ^nil` comparisons outright** (raises
`ArgumentError`, doesn't silently no-op as reasoned). All four functions
now have an explicit `%Card{account_id: nil} -> :ok` guard clause.
`Cards.sync_account_from_card/1` (used by `replace/3`/`renew/2`, not yet
extended to Debit) got the same guard preventively, since it has the
identical pattern.

Full-suite regression: 276 tests, same 10 pre-existing failures, zero
regressions.

## 4e. Item 4 (Debit Card Issuing) — summary

**All of D1-D5 done, 2026-07-26.** A real, network-issued debit account
can be opened, funded (internal or external channel), issued a card,
activated, authorize a real-time balance-checked transaction, clear-match
against an inbound Base II/IPM record, settle with the correct
liability-direction GL posting, and be blocked/unblocked — all verified
against real Postgres, not stubbed.

**Deliberately still open, each flagged with its own reasoning above,
not silently skipped**:
- `FAS.HotCardCache` (lost/stolen/fraud blocklist) has no Debit
  equivalent — `DebitAccount` has no `block_code` concept yet (§4a)
- `CTA.CardActivation` (IVR/first-use activation) is not debit-aware —
  its whole body mutates `cms_accounts`-specific state (§4a)
- `CardLifecycle.replace/3`/`renew/2` are not debit-aware — both read
  `CMS.Account` internally (§4a, §4d)

Full HCS/CTA/CMS/FAS/ASM/COL/admin regression before and after D1: same
10 pre-existing failures, zero regressions.

---

## 5. Prepaid Cards (native build, not ported)

**Status: 🔄 In Progress — P1 (ledger + account model) done 2026-07-27, P2-P5 next**

Avenza's prepaid auth path is real and live but resolves through
`WalletLedger.Commands.AuthorizeCardDebit` — a `wallet_*`-app dependency
that doesn't exist here (same "build native" call as Debit — confirmed,
not assumed, given Debit's item 4 already proved this exact dependency
gap is real). Building this natively means the actual "prepaid program"
layer (funding, load, dormancy, reconciliation) needs an in-house
equivalent inside vmu_core's own CMS/CTA, closed-loop clearing through
TRAMS, consistent with this repo's "no product bypasses FAS→TRAMS→GL"
principle.

Full design + 4 confirmed product/architecture decisions in `docs/
prepaid/PREPAID_Module_Requirements.md` §7-9: full-KYC reloadable only
in v1 (no anonymous/gift-card tier — avoids building a second, lighter
identity model before there's a concrete need); funding supports
internal transfer **and** external bank transfer/cash deposit, same
data-model-only pattern as Debit's D2; market config reads the existing
`BankParameter.regulatory_regime` cascade, same as Debit; **deliberately
NOT sharing Debit's account model** — Debit's `available_balance` is a
simple mutated counter (correct for it: no per-unit expiry, real-time-
critical, proven race-safe), but Prepaid needs **per-load expiry/
dormancy** (FR-005) — you can't expire "part of a flat counter," only a
specific load's remaining value — so it uses a genuine ledger instead,
the same "ledger row itself reflects partial consumption, never a
separately mutated balance" shape `LMS.PointsLedger` already proved out
(and whose *absence* was the real LMS-P1 bug this session found).

| # | Task | Status |
|---|---|---|
| P1.1 | `CMS.PrepaidAccount` schema — own identity fields for the parameter cascade, deliberately **no** `available_balance` field at all (unlike `DebitAccount`) | ✅ |
| P1.2 | `CMS.PrepaidLedgerEntry` schema — LOAD/SPEND/FEE/EXPIRE/REFUND/ADJUSTMENT types; LOAD rows carry their own `remaining_amount` + `expiry_date`; SPEND rows carry a `consumed_from` JSONB-array breakdown of exactly which load(s) they drew from | ✅ |
| P1.3 | `CMS.PrepaidLedger.balance/1` — always derived (`sum(remaining_amount)` over ACTIVE LOAD rows), never stored | ✅ |
| P1.4 | `CMS.PrepaidLedger.load/1` — posts the funding-side GL entry (new 1006/5002 codes) in the same transaction as the LOAD row, same real-time-GL convention as Debit's D2 | ✅ |
| P1.5 | `CMS.PrepaidLedger.spend/3` — consumes ACTIVE, unexpired loads soonest-expiring-first (`ORDER BY expiry_date ASC NULLS LAST`), `FOR UPDATE`-locked, spanning multiple loads if one isn't enough; declines `:insufficient_funds` and touches nothing if the total available is short | ✅ |
| P1.6 | `CMS.PrepaidLedger.credit/1` — reversal restores exactly the load(s) a given SPEND drew from via its own recorded breakdown, never guesses | ✅ |
| P1.7 | `CMS.PrepaidAccountOpening.open/1` | ✅ |
| P1.8 | Real tests | ✅ 13/13 (`prepaid_ledger_test.exs` — derived balance, multi-load accumulation, external-reference validation, single-load spend, FIFO-by-expiry consumption, multi-load-spanning spend, insufficient-funds decline leaves state untouched, an EXPIRED load is never consumed, suspended-account rejection, exact-restoration reversal, `:not_found`/`:not_a_spend_entry` reversal errors, and a real concurrent-spend oversell test with `FOR UPDATE` locking) |

Full-suite regression: CMS suite same 4 pre-existing `InterestIntegrationTest`
failures, zero regressions.

## 5a. P2 — Card issuance

**Status: ✅ Done (2026-07-27)**

| # | Task | Status |
|---|---|---|
| P2.1 | `cta_cards.prepaid_account_id` — third nullable FK alongside `account_id`/`debit_account_id` | ✅ |
| P2.2 | `CTA.Card.changeset/2`'s "exactly one" invariant generalized from a 2-way to an N-way check (`Enum.reject(&is_nil/1)` over all three ref fields, error if 0 or >1 set) | ✅ |
| P2.3 | `CTA.CardLifecycle.issue_new_prepaid/2` — mirrors `issue_new_debit/2` exactly | ✅ |
| P2.4 | `CTA.Cards.by_prepaid_account/1` | ✅ |
| P2.5 | Real tests | ✅ 8/8 `card_lifecycle_issue_prepaid_test.exs` (issuance, opts, invalid card_type, activate/block/unblock work unchanged, roster lookup, 3-way invariant) |

Full-suite regression: CTA/FAS suites same 2 pre-existing
`AuthorizationIntegrationTest` failures, zero regressions.

## 5b. P3 — Authorization

**Status: ✅ Done (2026-07-27)**

| # | Task | Status |
|---|---|---|
| P3.1 | `FAS.Authorization` — added a `"PREPAID"` branch to the existing `product_type` dispatch alongside `"DEBIT"`; `run_prepaid_authorization/1` translates `PrepaidLedger.spend/3`'s result into the same shape `handle_asc_result/2` already expects, so risk check/persist/hold/TRAM feed all work unchanged | ✅ |
| P3.2 | `resolve_account/1` — added the Prepaid clause. **Found and fixed live before it shipped**: the existing Debit clause (`%Card{debit_account_id: debit_account_id} -> ...`) was an unguarded catch-all that would have also matched a prepaid card (whose `debit_account_id` is nil too), silently resolving it to a nil account_id. Added `when not is_nil(debit_account_id)` to that clause before adding the new prepaid one | ✅ |
| P3.3 | `CMS.PrepaidLedger.refund/2` — a generic amount-based restore (inserts a `REFUND` LOAD-like row) for touchpoints (`AuthExpirySweepJob`, `ReversalHandler`) that only have `account_id`+`amount`, not a specific `SPEND` entry's `consumed_from` breakdown to reverse precisely via `credit/1`. `balance/1`/`spend/3` both treat `REFUND` rows as consumable value alongside `LOAD` rows | ✅ |
| P3.4 | `CMS.PrepaidLedger.prepaid_account?/1` — mirrors `DebitAuthorization.debit_account?/1`; `AuthExpirySweepJob.do_reverse/3` and `ReversalHandler.restore_otb/1` both now branch credit/debit/prepaid three ways instead of two | ✅ |
| P3.5 | Real tests | ✅ 2/2 new `authorization_integration_test.exs` cases (approve within balance + decrement, decline over balance + balance untouched) |

Full-suite regression: 299 tests, same 10 pre-existing failures, zero
regressions.

**Next**: P4 (settlement posting, same shape as Debit's D4 — a
`SettlementPostingAdapter` branch posting via `InternalGlPoster.
post_prepaid_spend/5`), P5 (expiry/dormancy sweep + ops UI).

---

## 6. BNPL (merchant) — blocked

**Status: 🔴 Blocked — no work until the integration contract exists**

Confirmed genuinely unbuilt in both repos (checked `vmu_mbs`,
`wallet_loans`, `wallet_transfers` — nothing merchant-checkout-BNPL
shaped anywhere). Real dependency is an integration contract with
`MerchantManagementSystem` (merchant eligibility/participation data),
not anything inside this repo — scoping that integration is the actual
first step, not vmu_core code.

## 7. Tokenization / Apple Pay / Google Pay — blocked

**Status: 🔴 Blocked — no work until a vendor is chosen**

Confirmed genuinely unbuilt in both repos. Blocked on Way4 parity plan
§3 Decision 1 (Visa Token Service vs. Mastercard MDES, and whether
Apple/Google Pay are in scope for this phase or a later one).
