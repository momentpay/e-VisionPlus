# HCS — Gap Implementation Tracker

> Source: `HCS_Module_Requirements.md`. First HCS-specific tracker — prior
> HCS work (Company/EmployeeCard/SpendingControl/LimitController/
> ConsolidatedStatementGenerator/PaymentSweep/CompanyOnboarding baseline)
> predates this doc and has no phase log of its own.
> Statuses: `✅ Done` · `🔄 In Progress` · `⬜ Pending`

---

## HCS-P1 — Facility Limit Maker-Checker + Admin UI (Way4 parity plan Phase 1 item 2) ✅ (2026-07-25)

Ported from `Avenza/apps/vmu_hcs`/`apps/vmu_core_web` (real, complete,
self-contained work — see `docs/compare/Way4_Phase1_Card_Portfolio_Tracker.md`
for the port-vs-build sequencing decision across all 7 Phase 1 items),
re-verified against this repo's own current schema/conventions, not a
clean copy-paste — adapted from `WalletWeb.Authorization.Policy.evaluate/2`
to this app's real `ASM.Authz.can?/3`.

Scoped to Corporate only — Avenza's source files bundle Fleet (vehicle/
driver/report) in the same modules; those sections are deliberately not
ported yet (Way4 parity plan Phase 1 item 3), and both `LimitController`
and `HcsComponent` will get a second pass when that item lands, not new
separate files.

| # | Task | File(s) | Status |
|---|---|---|---|
| P1.1 | `EmployeeCard` schema — added `daily_spend`/`daily_spend_date` fields (columns already existed via an untracked, already-applied migration from an earlier unfinished re-port attempt) | `hcs/employee_card.ex` | ✅ |
| P1.2 | `HCS.FacilityLimitChange` schema (PENDING_APPROVAL/APPROVED/REJECTED) | `hcs/facility_limit_change.ex` | ✅ |
| P1.3 | `HCS.FacilityLimitCommand` — `request/3`/`approve/2`/`reject/2`/`pending/1`, maker≠checker + role-list gate via `hcs.facility_limit_approval_matrix`, mirrors `COL.WorkoutCommand` | `hcs/facility_limit_command.ex` | ✅ |
| P1.4 | `HCS.ConfigCatalog` — `facility_limit_approval_matrix` (bank-scoped role list, default `[SUPERVISOR, RISK]`), registered in `ModuleConfigCatalog.all/0` | `hcs/config_catalog.ex`, `shared/module_config_catalog.ex` | ✅ |
| P1.5 | `LimitController` — `check_cash_access/2` (real `can_withdraw_cash` enforcement, was schema-only) + `DAILY_CAP` control-type enforcement (was schema-valid, documented, zero enforcement — a silent no-op) + `daily_spend` maintenance in `debit_limits/2`. `check_hcs_limits/5` gained a `cash_txn` param — `AccountStateCoordinator.do_authorize/6` already computed this for its own account-level cash-OTB check, now passed through instead of recomputed, so HCS's cash gate can never drift from that definition | `hcs/limit_controller.ex`, `cms/account_state_coordinator.ex` | ✅ |
| P1.6 | `HcsComponent` — company list/search/create, detail view (facility, pending limit requests, employee card roster, spending controls — all read-only except facility-limit-change requests), wired into `RolePermission` (`hcs` module, view/edit) and `AdminLive` (sidebar + routing) | `vmu_core_web/live/admin/hcs_component.ex`, `asm/role_permission.ex`, `vmu_core_web/live/admin/admin_live.ex` | ✅ |
| P1.7 | `ApprovalInboxComponent` — added the HCS facility-limit-changes queue (same "one action surface" pattern as COL's write-offs/workout plans/settlement offers) | `vmu_core_web/live/admin/approval_inbox_component.ex` | ✅ |
| P1.8 | `ModuleConfigComponent`'s hardcoded module list — found `col`/`fas` were already registered in `ModuleConfigCatalog` but still inaccessible via the admin config screen (same hardcoded-list bug already fixed once for `cms`, evidently never swept for every module); added `col`/`fas`/`hcs` together, and de-duplicated the list into a single `@modules` reference instead of two independently hardcoded copies | `vmu_core_web/live/admin/module_config_component.ex` | ✅ |

**Real pre-existing bugs found and fixed, neither previously caught (zero
tests in either repo)**:
- `CompanyOnboarding.onboard_company/1` and `add_employee_card/3` both
  referenced `.id` on a `CMS.Account` struct — but `Account`'s real
  primary key field is `account_id`. This function has never actually
  succeeded until this fix.
- `HcsComponent`'s company-creation handler used `params["registration_no"]
  || "PENDING"` — `||` only catches `nil`, not the empty string an
  untouched HTML form field actually submits, so a blank field produced
  `registration_number: ""` and failed CORPORATE-tier customer
  validation. Found live by this item's own admin-UI test.

**Verification (2026-07-25)**: 20/20 new tests — `facility_limit_command_test.exs`
(9 — request/approve/reject/pending, maker≠checker, role-matrix gate,
ADMIN-always-qualifies, available_limit delta math), `limit_controller_test.exs`
(8 — cash-access block/allow/non-cash-unaffected/default-false, DAILY_CAP
decline/allow/rollover-to-a-fresh-day/no-control-means-no-cap,
`debit_limits/2` daily_spend accumulation), `hcs_component_test.exs` (3 —
create company end-to-end, view detail, request→approve facility limit
change as two distinct operators through the real Approval Inbox). Full
HCS/CTA/CMS/FAS/ASM/COL/admin regression before and after: same 10
pre-existing, already-documented failures, zero regressions.

**Deliberately not in this pass**: Fleet vehicle/driver/report sections
of both `LimitController` and `HcsComponent` (Way4 parity plan Phase 1
item 3, next); full employee-card CRUD (Avenza's own comment calls this
"F-UI2 scope," i.e. its own next increment, not built there either).

---

## HCS-P2 — Fleet Cards (Way4 parity plan Phase 1 item 3) ✅ (2026-07-26)

Ported from the same `Avenza/apps/vmu_core_web`/`hcs_component.ex`
source as P1, this time the vehicle/driver/report sections that were
deliberately deferred out of that pass. All three fleet DB tables
(`hcs_vehicles`, `hcs_driver_assignments`, `hcs_fleet_cards`) plus the
`hcs_spending_controls.fleet_card_id` FK were already fully migrated and
applied to both dev and test DBs — leftover from the same earlier,
never-finished re-port attempt that also left P1's migrations sitting
untracked. Zero new migrations needed.

| # | Task | File(s) | Status |
|---|---|---|---|
| P2.1 | `HCS.Vehicle`, `HCS.FleetCard` schemas — verbatim field match against the already-applied migration | `hcs/vehicle.ex`, `hcs/fleet_card.ex` | ✅ |
| P2.2 | `HCS.DriverAssignment` + `HCS.DriverAssignmentCommand` — current/history tracking; "current" assignment = the single row with `unassigned_at == nil`, enforced by a transactional close-then-open, same invariant style as `FacilityLimitChange`'s status transitions. `@repo Application.compile_env(...)` adapted to a plain alias; `DateTime.utc_now()` truncated to `:second` at both write sites | `hcs/driver_assignment.ex`, `hcs/driver_assignment_command.ex` | ✅ |
| P2.3 | `HCS.FleetOnboarding` — `add_vehicle/2`; `add_fleet_card/3` validates the proposed limit against the remaining company pool via `allocated_pool/1`, which sums **both** `EmployeeCard` and `FleetCard` allocations (unlike `CompanyOnboarding.add_employee_card/3`'s employee-only equivalent), since both draw from the same `Company.credit_limit` pool. Fleet card accounts reuse the company's own parent `CMS.Account`'s `customer_id` — a vehicle isn't a separate KYC/legal entity | `hcs/fleet_onboarding.ex` | ✅ |
| P2.4 | `HCS.FleetReport` — `spend_by_vehicle/3`, `spend_by_driver/3`, `total_spend/3` off `cms_ledger_entries`, same `inserted_at`-range convention `ConsolidatedStatementGenerator` already uses. v1-scoped deliberately: no fuel-line-item detail, and `spend_by_driver/3` attributes 100% of a vehicle's period spend to whichever driver is *currently* assigned — not split across a mid-period reassignment (documented in the moduledoc, not silently dropped) | `hcs/fleet_report.ex` | ✅ |
| P2.5 | `LimitController` generalized: `get_employee_card/1` → `get_active_card/1` returning `{:employee, card} \| {:fleet, card} \| nil` (checks `EmployeeCard` by `employee_account_id` first, falls back to `FleetCard` by `account_id`); `debit_limits/2`/`credit_limits/2`/`check_spending_controls/6` branch on the returned kind via a `card_schema/1` helper and a per-kind `dynamic/2` card-match clause. Works because `EmployeeCard`/`FleetCard` deliberately share identical field names (`available_individual`, `can_withdraw_cash`, `daily_spend`, `daily_spend_date`, `company_id`, `id`), so every check function pattern-matches generically via a bare `%{field: ...}` pattern | `hcs/limit_controller.ex` | ✅ |
| P2.6 | `SpendingControl` — added `fleet_card_id` field + `"FLEET"` scope value (DB column already existed via the same untracked migration; Ecto schema just hadn't caught up) | `hcs/spending_control.ex` | ✅ |
| P2.7 | `HcsComponent` second pass — Fleet Vehicles roster + "+ Add Vehicle" in company detail; new `:vehicle_detail` mode (fleet card issuance, driver assignment/unassignment + history); Fleet Spend Report generator (group by vehicle or by current driver) | `vmu_core_web/live/admin/hcs_component.ex` | ✅ |

**Real bugs found and fixed while building this item**:
- `Ecto.Query`'s `dynamic/2` cannot be interpolated with `^` alongside
  plain `and`-joined literal conditions inside the same `where:` —
  raises "dynamic expressions can only be interpolated at the top level."
  Fixed by folding the kind-specific card-match clause into one combined
  `dynamic/2` and interpolating that once, rather than mixing `^dynamic`
  with `and` at the call site.
- A `FleetReport` test initially tried to "backdate" a ledger entry by
  setting only `posting_date`; `inserted_at` (what period-range queries
  actually filter on, matching `ConsolidatedStatementGenerator`'s own
  convention) is set to real wall-clock time by `timestamps()` regardless
  of what `posting_date` is passed — fixed by directly
  `Repo.update_all`-ing `inserted_at` for the out-of-window fixture row,
  the same technique `limit_controller_test.exs` already uses to backdate
  `daily_spend_date`.

**Verification (2026-07-26)**: 22/22 new tests — `fleet_onboarding_test.exs`
(7 — add vehicle, duplicate-VIN rejection, fleet card issuance, inactive-
vehicle rejection, pool-exceeded rejection, employee+fleet pool summed
together), `driver_assignment_command_test.exs` (5 — open/close/history/
no-active-assignment-error/never-two-concurrently-open), `fleet_report_test.exs`
(4 — per-vehicle sum with out-of-window exclusion, cross-card total,
spend-by-driver current-assignment attribution, UNASSIGNED grouping), plus
4 fleet cases added to `limit_controller_test.exs` and 2 added to
`hcs_component_test.exs` (full add-vehicle→issue-card→assign-driver→
unassign UI flow, and a report-generation flow). Full-suite regression
(230 tests, one pre-existing broken compile file in `test/vmu_core/lms/
points_lifecycle_test.exs` excluded — unrelated, predates this session):
same 10 pre-existing, already-documented failures (2 `FAS.
AuthorizationIntegrationTest`, 4 `CMS.InterestIntegrationTest`, 4 `COL.
WriteOffRecoveryTest`), zero regressions.
