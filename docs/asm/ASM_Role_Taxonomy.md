# ASM Role Taxonomy — 3 Bank-Size Org Design

**Status:** ✅ Resolved 2026-07-09 — answers `ASM_Module_Requirements.md` §6 open
question 2 ("Take a bank's - 3 size example Large, Medium and small, create a org
design... Create the Role and permission accordingly").

---

## 1. Approach

The system already has 7 roles (`VmuCore.ASM.Operator.roles/0`) and one flat
permission matrix (`VmuCore.ASM.RolePermission.default_matrix/0`) — see the table
below. This design **reuses that taxonomy unchanged** as the "Large Bank" tier rather
than inventing new blended role names (e.g. a merged "RISK_COMPLIANCE" role) with new
permission grants to design and get right.

Medium and Small tiers are expressed as a **staffing recommendation**: which subset
of the existing 7 roles a bank of that size should actually populate with real
operators. A small institution doesn't need a *different* permission system — it
just doesn't hire a dedicated fraud analyst or a dedicated teller; those job
functions fold into roles that already exist and already have appropriate grants.

This is deliberately the lower-risk option: zero changes to `Authz.can?/3`,
`RolePermission`, or the seed script. `BankParameter.org_size` (added alongside this
doc) is advisory metadata for onboarding guidance, not an enforcement mechanism — an
operator can still be assigned any of the 7 roles regardless of their bank's size.

## 2. Large Bank — all 7 roles staffed

Regional/national bank, dozens+ branches, dedicated specialist teams for each
function. This is exactly what's built today — no changes.

| Role | Who | Grants |
|---|---|---|
| `TELLER` | Branch tellers | view-only: customer, account |
| `CS_AGENT` | Call center / customer service | customer edit; account/auth_history/tram_inquiry view |
| `OPS` | Back-office processing | logo/block/customer/account/exceptions edit, no approve |
| `SUPERVISOR` | Team leads / branch managers | broad view/edit/approve: customer/account/exceptions/tram_inquiry/approvals/audit_log |
| `RISK` | Dedicated fraud/risk analysts | exceptions view/edit/approve; auth_history/tram_inquiry view; approvals view/approve |
| `COMPLIANCE` | Dedicated compliance officers | view-only everywhere — segregation of duties, audit without edit power |
| `ADMIN` | Platform/IT administrators | full access (code short-circuit in `Authz.can?/3`) |

## 3. Medium Bank — 5 of 7 roles staffed

Regional bank or credit union, tens of branches, functions consolidated but still
separated where it matters most (compliance stays independent).

**Recommend not creating `TELLER` or `RISK` operators.**

| Real job function | Assign role | Why |
|---|---|---|
| Front-line staff (branch + phone, cross-trained) | `CS_AGENT` | Absorbs `TELLER`'s narrower lookup-only duties — a medium bank's front-line staff are cross-trained, not siloed into teller-only vs. service-only. |
| Back-office processing | `OPS` | Unchanged. |
| Branch/ops managers | `SUPERVISOR` | Also absorbs `RISK`'s fraud/exception review duties — `SUPERVISOR` already holds `exceptions: view/edit/approve`, so no new grant is needed. |
| Compliance/audit officer | `COMPLIANCE` | **Unchanged, deliberately kept view-only** — see tradeoff note below. |
| IT/platform admin | `ADMIN` | Unchanged. |

## 4. Small Bank — 3-4 of 7 roles staffed

Community bank, small credit union, or neobank — one or two people wear most hats.

**Recommend not creating `TELLER`, `OPS`, or `RISK` operators.**

| Real job function | Assign role | Why |
|---|---|---|
| Front-line staff | `CS_AGENT` | Does everything front-line. |
| Branch/ops manager (often 1-2 people; does ops + fraud review + light oversight) | `SUPERVISOR` | The only remaining role with both edit *and* approve authority — the closest single-role fit for a blended job. |
| Compliance function, if any exists — even part-time or shared/outsourced | `COMPLIANCE` | **Recommended whenever any independent compliance function exists**, unlike `TELLER`/`OPS`/`RISK` which are skipped by default. Segregation of duties for audit purposes is frequently a regulatory expectation regardless of institution size. |
| IT/platform admin | `ADMIN` | Unchanged. |

## 5. The tradeoff, stated plainly

At Medium and Small tiers, `SUPERVISOR` ends up both *doing* exception work and
*approving* it, and holding `audit_log: view` — the Large-bank separation between
doer (`RISK`) and independent reviewer (`COMPLIANCE`) is reduced for that role. This
is a real, common tradeoff smaller institutions accept in practice — the usual
compensating control is external audit / examiner review rather than an internal
second reviewer. It's stated here explicitly so it's a conscious choice an
institution makes when onboarding at a given size, not a silent gap discovered later.
`COMPLIANCE` is kept view-only at every tier specifically because that segregation is
the one worth protecting even under headcount pressure.

## 6. Technical support (advisory only)

- `BankParameter.org_size` (`SMALL`/`MEDIUM`/`LARGE`, nullable) — set per organization
  in the admin console (`/visionplus/admin/organization`), alongside the existing
  `org_type` field.
- The operator-creation screen (`/visionplus/admin/operators`) shows the recommended
  role set for the target bank's size as a hint, sourced from `VmuCore.ASM.RoleTaxonomy`
  (`lib/vmu_core/asm/role_taxonomy.ex`) — **advisory only**; every role remains
  selectable regardless of the bank's `org_size`, and existing operators/banks with no
  `org_size` set are entirely unaffected.
- No changes to `Authz`, `RolePermission`, `RolePermission.default_matrix/0`, or
  `priv/repo/seed_role_permissions.exs`.
