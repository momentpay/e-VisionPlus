# ASM — Implementation Tracker

> Source: `ASM_Module_Requirements.md` (gap: admin UI unauthenticated; all
> 4-eyes flows honor-system). Phases `ASM-P1`..`ASM-P4`.
> Statuses: `✅ Done` · `🔄 In Progress` · `⬜ Pending`
> Created: 2026-07-04

---

## Design decisions (proposed — confirm during P1 review)

- **ADR-A1: Local credentials first.** Operator accounts with PBKDF2-SHA256
  password hashes (same primitive as `cms_card_pins`), lockout after N
  failures. SSO/LDAP (§6 Q1 of requirements doc) deferred to an adapter
  behind the same `ASM.Auth` context, so it's additive later.
- **ADR-A2: Session via Phoenix session cookie + LiveView mount hook.** One
  `on_mount {VmuCoreWeb.OperatorAuth, :require_operator}` hook gates every
  admin LiveView; the login page is the only unauthenticated admin route.
- **ADR-A3: Role→permission matrix as data, not code.** `asm_role_permissions`
  (role × module × action) seeded with a default matrix; checked by a single
  `ASM.Authz.can?(operator, module, action)` — components call it, no
  per-component role logic.
- **ADR-A4: Existing 4-eyes flows keep their signatures** — they already take
  operator IDs (temp limits, fee waivers, adjustments, TRAM maintenance).
  P3 replaces the free-form IDs at the UI layer with the authenticated
  operator's ID and enforces role authority; the command modules stay as-is.

## ASM-P1 — Operator Identity Core ✅ (2026-07-04)

| # | Task | File(s) | Status |
|---|---|---|---|
| P1.1 | Migration — `asm_operators` (username unique, PBKDF2 hash+salt, role, status ACTIVE/LOCKED/DISABLED, bank_scope, failed_attempts, locked_at, last_login_at, password_changed_at) + `asm_login_audit` (every attempt, success or failure, known user or not) | migration `20260704000002` | ✅ |
| P1.2 | `Operator` schema (`redact: true` on credentials) + `ASM.Auth`: `authenticate/3` (PBKDF2-SHA256 100k, constant-shape hashing for unknown users, lockout at 5 fails), `create_operator/1`, `change_password/3`, `reset_password/2`, `unlock/1`, `disable/1`, policy ≥10 chars + letter + digit | `asm/operator.ex` · `asm/auth.ex` | ✅ |
| P1.3 | Login page + session controller — plain controller (only Plug can write the session cookie), self-contained HTML per admin-UI convention, CSRF-protected, session renewed on login | `controllers/operator_session_controller.ex` | ✅ |
| P1.4 | `OperatorAuth` — dual-face module: `on_mount :require_operator` for the admin `live_session` (DB revalidation on every mount + idle timeout `operator_session_timeout_minutes`, default 30) AND a plug gating LiveDashboard + legacy terminal; logout drops the session; topbar shows operator + role + sign-out | `vmu_core_web/operator_auth.ex` · `router.ex` · `admin_live.ex` | ✅ |
| P1.5 | Seed script (idempotent, credentials via `VMU_ADMIN_USERNAME`/`VMU_ADMIN_PASSWORD` env) — default admin seeded in dev | `priv/repo/seed_operators.exs` | ✅ |

**Verification (2026-07-04):** smoke-tested 8/8 against `vmu_core_dev` — weak
password rejected; create + authenticate; wrong-password and unknown-user both
return `invalid_credentials`; lockout at 5 failures; admin unlock resets the
counter; `get_active_operator/1` cuts off DISABLED operators (next-mount
revocation); password change invalidates the old credential; login audit
recorded 10 rows with correct outcome breakdown (6 bad_password, 1 locked,
3 success).

## ASM-P2 — Roles & Permissions 🔄 (core done 2026-07-04)

| # | Task | Status |
|---|---|---|
| P2.1 | `asm_role_permissions` (role × module × action, unique) + `RolePermission.default_matrix/0` (51 grants across 6 roles; ADMIN = code short-circuit, deliberately row-less — which is what makes `operators` ADMIN-only) + idempotent seed | ✅ migration `20260704000003` · `asm/role_permission.ex` · `priv/repo/seed_role_permissions.exs` |
| P2.2 | `ASM.Authz`: `can?/3`, `permitted_modules/1`, `bank_scope/1`, per-role `:persistent_term` cache + `refresh/0`, `seed_default_matrix/0`; AdminLive filters sidebar by permitted modules AND blocks deep-linked unpermitted modules server-side ("Access denied" panel) | ✅ `asm/authz.ex` · `admin_live.ex` |
| P2.3 | Action-level gating pattern established in ExceptionQueueComponent: AdminLive passes `can_approve` from `Authz.can?`, buttons hidden without it, `handle_event` re-checks server-side. Remaining CRUD components get the same treatment as part of P3.1 (when operator identity is wired into their 4-eyes forms) | 🔄 exemplar done |
| P2.4 | `Authz.bank_scope/1` helper implemented (ADMIN = nil/unrestricted); applying it inside Customer/Account component queries lands with P3.1's component pass | 🔄 helper done |
| P2.5 | Operator admin UI: list, create (policy-validated), unlock, disable/reactivate, role change; self-disable and self-role-change blocked; every mutation re-checks ADMIN server-side | ✅ `live/admin/operator_component.ex` |

**Verification (2026-07-04):** smoke-tested 7/7 — seed 51 grants + idempotent
re-seed; ADMIN short-circuit incl. `operators`; TELLER limited to
customer/account view; approve split (SUPERVISOR yes / OPS no); sidebar sets
(TELLER 2 modules, ADMIN 10); bank scope (ADMIN nil, TELLER "MMBD"); runtime
revoke + cache refresh takes effect without redeploy.

## ASM-P3 — Maker-Checker Centralization ✅ (2026-07-04)

| # | Task | Status |
|---|---|---|
| P3.1 | Real identity in 4-eyes flows: CMS temp limit / fee waiver / financial adjustment handlers now take **maker = authenticated session operator** (hardcoded `"AGENT001"`/`"SUP001"` fallbacks removed) and the supervisor field is validated via `Authz.validate_checker/4` — must be a real ACTIVE operator, ≠ maker, holding `account:approve`, within authority for the amount. TRAMS flows record the authenticated username via the inbox (P3.3). Command-module signatures untouched (ADR-A4). *Remaining: `bank_scope` query filtering in Customer/Account components → P4 pass.* | ✅ `account_component.ex` · `admin_live.ex` |
| P3.2 | Authority limits: `Authz.authority_limit/1` + `within_authority?/2` — config `:asm_authority_limits` (SUPERVISOR 10000 / RISK 5000 / OPS 1000; ADMIN unlimited; unlisted roles zero); enforced in `validate_checker` and at inbox approval | ✅ `asm/authz.ex` · `config/config.exs` |
| P3.3 | Approval Inbox — unified queue for `AdjustmentCommand.pending` + `MaintenanceCommand.pending`; approve/reject records the authenticated username; adjustment approval pre-checks the checker's authority against the delta; visible to `approvals:view` (SUPERVISOR/RISK/ADMIN — 4 new matrix grants), action buttons + server-side re-check on `approvals:approve`; sidebar "Security & Control" section | ✅ `live/admin/approval_inbox_component.ex` · `role_permission.ex` · `admin_live.ex` |

**Verification (2026-07-04):** smoke-tested 7/7 — matrix reseed added exactly
the 4 `approvals` grants; authority tiers (ADMIN unlimited / SUPERVISOR
10000 / TELLER 0); boundary checks at 9999/10001; all four
`validate_checker` rejection paths (unknown, self, unauthorized role,
over-authority) + success; full inbox cycle: OPS operator parked an
above-threshold TRAM adjustment, self-approval blocked, SUPERVISOR approved →
POSTED with `approved_by: "sup.checker"`, queue drained.

## ASM-P4 — Audit ✅ core (2026-07-04; MFA deferred)

| # | Task | Status |
|---|---|---|
| P4.1 | `ASM.AuditLog.record/4` — single write path into the adopted append-only `cms_operator_audit` table (legacy OperatorPortal sink reused — one trail, not two); fail-safe (audit failure never breaks the audited operation); oversize inputs truncated; nil operator → "system"/"SYSTEM" | ✅ `asm/audit_log.ex` · `asm/audit_entry.ex` |
| P4.2 | PII view audit (FR-ASM-015): `customer_pii_view` on customer detail open, `account_detail_view` on account detail open — recorded against the authenticated operator. **Carried-over P2.4 also closed here:** `bank_scope` now forced onto Customer + Account list queries (scoped operator's UI filter cannot widen it) | ✅ `customer_component.ex` · `account_component.ex` · `admin_live.ex` |
| P4.3 | Audit Trail search UI — filter by operator / action (dropdown of distinct actions, prefix match) / subject / date range, paginated; `audit_log` matrix module (COMPLIANCE + SUPERVISOR view; ADMIN short-circuit); "Security & Control" sidebar | ✅ `live/admin/audit_log_component.ex` · `role_permission.ex` · `admin_live.ex` |
| P4.4 | MFA (TOTP) for SUPERVISOR/ADMIN — **deferred**: decision pends the SSO/LDAP question (ADR-A1); if corporate SSO lands, MFA comes with the IdP rather than local TOTP | ⬜ deferred |

**Verification (2026-07-04):** smoke-tested 8/8 — reseed added exactly the 2
`audit_log` grants (COMPLIANCE/SUPERVISOR yes, OPS no); write + PII-view +
system-context entries recorded; searches by operator, action prefix,
subject + date window, and negative date window all correct; distinct-actions
dropdown source; oversize action/subject truncated fail-safe.

---

## ASM-P5 — Action-Level Gating Rollout ✅ (2026-07-07)

Closes the gap flagged during the post-CTA-P3 plan review: P2.2 gated which
*modules* appear in the sidebar (and blocks deep-linking), and P3.1 wired
real operator identity into the CMS 4-eyes financial forms — but the plain
CRUD screens (System, Organization, Logo, Block, Customer) never got
`Authz.can?`-based **action**-level gating. Until this phase, any operator
who could *see* Logo/Block (e.g. OPS, COMPLIANCE — `view`-only per the
matrix) could still submit an edit, since nothing checked the matrix's
view/edit/create distinction below the module level — a real authorization
bypass, not a cosmetic gap.

| # | Task | File(s) | Status |
|---|---|---|---|
| P5.1 | `SystemComponent` — `can_edit` computed in `update/2` from `Authz.can?(operator, "system", "edit")`; Edit button hidden + `sys_edit`/`sys_save` re-check server-side | `live/admin/system_component.ex` | ✅ |
| P5.2 | `OrganizationComponent` — same pattern; gates `org_new`/`org_edit`/`org_save`/`org_delete` (both toolbar and empty-state create buttons) | `live/admin/organization_component.ex` | ✅ |
| P5.3 | `LogoComponent` — gates `logo_new`/`logo_edit`/`logo_save`/`logo_delete` **and** the inline PLAN segment CRUD (`plan_new`/`plan_edit`/`plan_save`/`plan_delete`) on the same `logo:edit` grant, since plans are logo-scoped and the matrix has no separate plan permission. *(Note: while surveying this component, found that Roadmap Phase 4C.2 "PLAN segment create/edit" — previously reported as an open gap — was already implemented here; the account-detail Plans tab's "manage from Products/Logos" pointer was accurate, just unverified until now.)* | `live/admin/logo_component.ex` | ✅ |
| P5.4 | `BlockComponent` — gates `block_new`/`block_edit`/`block_save`/`block_delete` (toolbar + empty-state + row actions) | `live/admin/block_component.ex` | ✅ |
| P5.5 | `CustomerComponent` — **two-permission model**: `can_edit` (`customer:edit`) gates edit/delete; `can_create` (`customer:create`) separately gates new-customer entry points, since the matrix grants OPS/CS_AGENT edit but not create. `cust_save` branches on `is_nil(editing)` to apply the correct one | `live/admin/customer_component.ex` | ✅ |

**Verification (2026-07-07):** smoke-tested 9/9 — confirmed the exact
`Authz.can?` decisions each component's `update/2` now relies on: `system:edit`
and `organization:edit` → ADMIN only; `logo:edit`/`block:edit` → SUPERVISOR +
ADMIN (OPS/COMPLIANCE correctly excluded); `customer:edit` → SUPERVISOR/OPS/
CS_AGENT + ADMIN; `customer:create` → SUPERVISOR + ADMIN only (OPS/CS_AGENT can
edit existing customers but not create new ones); view access unaffected
(COMPLIANCE keeps `system:view`); ADMIN short-circuits every check regardless
of matrix content. All 5 components compile clean with the new `can_edit`/
`can_create` assigns driving both template button visibility (`:if={@can_edit}`)
and server-side handler re-checks — defense in depth against a crafted event
bypassing a hidden button.

---

## ASM-P6 — Module Configuration (AuthN/PII-masking/Audit-retention) ✅ (2026-07-08)

Resolves 3 of the 4 open questions in `ASM_Module_Requirements.md` §6 — AuthN source,
PII masking, and audit retention were all answered as "make it configurable," so this
phase folds ASM's settings into the shared, reusable configuration framework rather
than one-off ASM-specific plumbing. Full design and verification:
`docs/shared/Module_Configuration_Framework.md`. (Question 2 — role taxonomy — is a
design task, not a config key; not part of this phase.)

| # | Task | File(s) | Status |
|---|---|---|---|
| P6.1 | ASM config catalog — 4 keys: `authn_source` + `authn_provider_config` (SSO/AD/LDAP/local), `pii_masking_rules` (role-wise), `audit_retention_days` (default 2555 = 7yr) | `lib/vmu_core/asm/config_catalog.ex` | ✅ |
| P6.2 | Registered in the shared `ModuleConfigCatalog` + rendered by the generic Module Configuration admin screen (built in CTA-P4, reused here — no ASM-specific UI code) | `lib/vmu_core/shared/module_config_catalog.ex`, `lib/vmu_core_web/live/admin/module_config_component.ex` | ✅ |

**Verification (2026-07-08):** covered by the shared framework's smoke test (default
fallback, cascade, validation, audit trail — see
`docs/shared/Module_Configuration_Framework.md` §7); `audit_retention_days` write
specifically exercised (2555 → 3650) and confirmed both the ETS cascade and the
`config_update` audit row.

## ASM-P6.3 — Wire config keys into real business logic ✅ (2026-07-08, same day)

P6.1 only registered the catalog keys — `pii_masking_rules` and `audit_retention_days`
had no consumer at all (config existed, but zero behavioral effect: every customer PII
field was rendered in full to any operator, and there was no retention/purge job for
`cms_operator_audit` at all). `authn_source`/`authn_provider_config` are **not**
wired — a real SSO/AD/LDAP integration is a full feature, deliberately out of scope
here (see `docs/shared/Module_Configuration_Framework.md` §6/§8).

| # | Task | File(s) | Status |
|---|---|---|---|
| P6.3.1 | `pii_masking_rules` — new masking applied at render time in the customer admin list and detail views for `cif.id_number` and `cif.date_of_birth`. Operators whose role is in a field's configured `unmasked_roles` (or ADMIN, always unmasked) see the raw value; everyone else sees all but the last 4 characters masked. Empty rules map (default) = unmasked, matching prior behavior exactly — non-breaking by default. | `lib/vmu_core_web/live/admin/customer_component.ex` | ✅ |
| P6.3.2 | `audit_retention_days` — new weekly Oban job deletes `cms_operator_audit` rows older than the configured window (default 2555 days). No purge job existed at all before this. Multi-tenant safe: uses the longest configured retention across all SYS records as the cutoff, since the audit table has no `sys_id` column (single global trail). | `lib/vmu_core/asm/oban/audit_retention_sweep_job.ex`, `config/config.exs` (cron: Sunday 03:00) | ✅ |

**Verification (2026-07-08):** live end-to-end test via the running admin console: with
`pii_masking_rules` unset (default), a customer's ID number rendered in full to every
operator. After configuring `cif.id_number`/`cif.date_of_birth` with
`unmasked_roles: ["COMPLIANCE"/"SUPERVISOR"]`, logging in as a throwaway CS_AGENT
operator showed masked values (e.g. `***********0001`) in both the list and detail
views, while ADMIN continued to see raw values (bypass confirmed still correct with a
rule active). Test operator and rule reverted after. `AuditRetentionSweepJob.perform/1`
ran cleanly against the real `cms_operator_audit` table (21 rows, all recent — none
purged, as expected).

---

## ASM-P7 — Role Taxonomy Org Design (Large/Medium/Small) ✅ (2026-07-09)

Resolves `ASM_Module_Requirements.md` §6 open question 2 (a design task deferred
during the Module Configuration Framework work). Chosen approach (confirmed with
user): reuse the existing 7 roles and their current `RolePermission` grants
unchanged as the "Large Bank" tier, rather than inventing new blended role names with
new merged permission semantics — Medium/Small tiers are a staffing recommendation
(which subset of the existing roles a bank of that size should populate), advisory
only, not a new enforcement mechanism.

| # | Task | File(s) | Status |
|---|---|---|---|
| P7.1 | Design doc: Large (7/7 roles, unchanged), Medium (5/7, skips `TELLER`/`RISK`), Small (3-4/7, skips `TELLER`/`OPS`/`RISK`) — with the segregation-of-duties tradeoff at Medium/Small stated explicitly (SUPERVISOR both does and approves exception work at those tiers) rather than hidden | `docs/asm/ASM_Role_Taxonomy.md` | ✅ |
| P7.2 | `BankParameter.org_size` — new nullable field (`SMALL`/`MEDIUM`/`LARGE`), mirrors the existing `org_type` pattern; `org_size_options/0` helper; empty-string→nil normalization in the changeset | migration `20260709000000_add_org_size_to_bank_parameters.exs`, `lib/vmu_core/shared/bank_parameter.ex` | ✅ |
| P7.3 | `VmuCore.ASM.RoleTaxonomy` — pure lookup module (`recommended_roles/1`, `hint/1`) mapping org_size → recommended role list; no dependency on `Authz`/`RolePermission` | `lib/vmu_core/asm/role_taxonomy.ex` | ✅ |
| P7.4 | Admin UI: Organisation Size select + list-view badge in `OrganizationComponent` (same edit pattern as `org_type`); recommended-roles hint (live, via `phx-change`) on the operator-creation form in `OperatorComponent`, looked up from the entered `bank_scope`'s `BankParameter.org_size` — advisory text only, role dropdown unrestricted | `lib/vmu_core_web/live/admin/organization_component.ex`, `lib/vmu_core_web/live/admin/operator_component.ex` | ✅ |

**Verification (2026-07-09):** `mix compile --force` clean (no new warnings/errors).
Live: set a real bank's `org_size` to `SMALL`, confirmed the badge renders on
`/visionplus/admin/organization`'s list view; confirmed `RoleTaxonomy.hint/1` produces
the exact recommended-role text for all three tiers (`SMALL`/`MEDIUM`/`LARGE`) and
`nil` for unset; confirmed the empty-string→nil changeset normalization round-trips
correctly (set then cleared via the same changeset path the UI form uses). Test
`org_size` reverted to `nil` after — existing banks/operators are completely
unaffected by default, matching the additive, non-enforcing design.

No changes to `Authz.can?/3`, `RolePermission`, `RolePermission.default_matrix/0`, or
`priv/repo/seed_role_permissions.exs` — the permission engine itself is untouched.

---

*Recommended start: immediately after CMS-G1 — ASM-P1 gates production use of every admin screen.*
