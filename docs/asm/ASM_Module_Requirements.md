# ASM — Access & Security Management (Operator Portal): Module Requirements

**Status:** 📝 Draft for review — drafted from VisionPlus operator-security domain knowledge, cross-checked against `lib/vmu_core/asm/` and the admin UI. **This is the thinnest module today and gates production readiness of every admin screen** (currently unauthenticated).

---

## 1. Purpose & Scope

ASM owns **who can do what in the back office**: operator identities, roles/permissions, authentication, maker-checker policy, session management, and the audit trail of operator activity. Every admin LiveView (parameter, customer, account, TRAM inquiry, exception queues) and every 4-eyes flow (temp limits, fee waivers, adjustments, maintenance) depends on ASM for *real* operator identity — today those flows take operator IDs as free-form input.

## 2. Where ASM Sits

| Direction | Module | Contract |
|---|---|---|
| → All admin UI | AuthN/AuthZ | Login, session, role-gated navigation + actions |
| → CMS/TRAMS/DPS/COL 4-eyes | Identity | Maker/checker IDs must be authenticated operators with the right role |
| → CIF | PII gating | Field-level visibility by role (spec 04 §2.4 internal views) |
| → Audit | Trail | Operator action + view logging (operator_audit table exists) |

## 3. VisionPlus Feature Inventory

### 3.1 Identity & Access (FR-ASM-001 … 010)

| FR | Feature | Notes |
|---|---|---|
| 001 | Operator accounts: create/disable, profile, branch/team attribution | |
| 002 | Authentication: password policy, lockout, expiry; SSO/LDAP option | |
| 003 | MFA for privileged roles | |
| 004 | Roles: TELLER / CS_AGENT / OPS / SUPERVISOR / RISK / COMPLIANCE / ADMIN (configurable) | |
| 005 | Permission matrix: module × action (view/create/edit/approve) per role | |
| 006 | Data-scope restriction (operator sees only own BANK/branch) | |
| 007 | Session management: timeout, concurrent-session policy, forced logout | |
| 008 | Login/attempt audit | |
| 009 | Password reset workflow (self-service + admin) | |
| 010 | Emergency break-glass access with mandatory review | |

### 3.2 Authority & Audit (FR-ASM-011 … 018)

| FR | Feature | Notes |
|---|---|---|
| 011 | Maker-checker policy engine: which actions need approval, thresholds per role | today hardcoded per module |
| 012 | Authority limits (max adjustment amount per role level) | |
| 013 | Approval queues: unified inbox of pending 4-eyes items across modules | adjustments + maintenance queues exist per-module |
| 014 | Operator action audit: every write with before/after (exists per-module) | `operator_audit` migration exists |
| 015 | PII view audit (who opened which customer) | CIF FR-020 |
| 016 | Audit search/export for compliance | |
| 017 | Dual-control config changes (role/permission edits themselves need approval) | |
| 018 | Periodic access recertification report | |

## 4. Current Implementation Map

| File | Covers |
|---|---|
| `asm/operator_portal.ex` | Single module — operator portal skeleton |
| migration `20260614000000_create_operator_audit.exs` | Operator audit table |
| Admin UI (`/visionplus/admin`) | **No authentication** — open route |
| 4-eyes in CMS/TRAMS (temp limit, waiver, adjustment, maintenance) | Enforce maker ≠ checker on free-form operator IDs — no identity verification |

## 5. Gap Analysis (initial — verify during planning)

| Area | Assessment |
|---|---|
| Operator identity, login, sessions (FR-001–003, 007–009) | ⬜ **Missing entirely** — admin is unauthenticated |
| Roles/permissions + route gating (FR-004–006) | ⬜ Missing |
| Maker-checker policy centralization (FR-011–012) | 🔄 Enforcement exists per-module; identity + policy config missing |
| Unified approval inbox (FR-013) | ⬜ Per-module `pending/1` functions exist; no UI |
| Audit (FR-014) | 🔄 Table exists; coverage unverified; no view-audit, no search UI |

> **Priority note:** ASM is the single biggest production-readiness gap in the admin stack. Every 4-eyes control built so far is honor-system until operators authenticate.

## 6. Open Questions

1. AuthN source: local credentials vs corporate SSO/LDAP (bank IT constraint).
Answer: Configurable, SSO, AD, LDAP and local credential
2. Role taxonomy + permission matrix — needs an ops org-design input.
Answer: Take a bank's - 3 size example Large, Medium and small, create a org design with your own intelligence and knowledge. Create the Role and permission accordingly
3. Is field-level PII masking by role required for v1, or module-level gating enough?
Answer:PII masking role wise
4. Regulatory audit retention period for operator logs.
Answer: Configurable and by default 7yrs

**Resolved 2026-07-08 — questions 1, 3, and 4 implemented as configurable**, via the
new `VmuCore.Shared.ModuleConfig*` framework — see
`docs/shared/Module_Configuration_Framework.md`. Catalog:
`lib/vmu_core/asm/config_catalog.ex`.

| Question | Config key | Default |
|---|---|---|
| 1. AuthN source (SSO/AD/LDAP/local) | `authn_source`, `authn_provider_config` | `[local]` / `{}` |
| 3. PII masking, role-wise | `pii_masking_rules` | `{}` |
| 4. Audit retention period | `audit_retention_days` | `2555` (7yr) |

Editable via the admin console's **Module Configuration** screen. Question 2 (role
taxonomy — 3 bank-size org design) is **not** a config key; it's a design task, tracked
separately (see `docs/shared/Module_Configuration_Framework.md` §6).
