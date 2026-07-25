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
