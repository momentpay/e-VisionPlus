# Admin Menu, Sections & Permissions — Standard

| Property | Value |
|---|---|
| Date | 2026-08-03 |
| Status | **Adopted.** The sidebar is now generated from the registry; hand-listing is no longer possible without reverting the change. |
| Applies to | `VmuCoreWeb.Live.Admin.AdminLive`, `VmuCore.ASM.RolePermission`, every admin LiveComponent |

---

## 1. Why this exists

Adding the General Ledger screen exposed the problem. A module had to be registered in **four** places, and the sidebar was a hand-written list that duplicated labels and icons already declared elsewhere:

| # | Place | Was GL registered? |
|---|---|---|
| 1 | `AdminLive.@modules` — label, icon, section | yes |
| 2 | `AdminLive` sidebar template — a literal `<.sidebar_nav_item>` line | **no** |
| 3 | `AdminLive` render branch — the `<% "gl" -> %>` case | yes |
| 4 | `RolePermission.@modules` + `default_matrix` | **no** |

Missing either 2 or 4 produces the same symptom — **the module exists and works but is invisible** — with no error anywhere. With 25 modules and more coming, that is not a mistake anyone will make once.

There was already a workaround for the same class of bug: `expand_module_config_visibility/1` exists purely because `module_config` has no permission rows of its own.

---

## 2. The rule

**`AdminLive.@modules` is the single source of truth for navigation. The sidebar is generated from it.**

As of 2026-08-20 the registry has three levels, not two: **nav module** (top-level business domain — shown in the top dock once Phase 2 of the UI modernization lands, see the `snoopy-seeking-goose` plan) → **group** (sidebar sub-heading) → **item** (a leaf screen, i.e. a row in `@modules`). This replaced the old flat 5-section grouping (`:hierarchy/:operations/:financial/:fas/:security`), which was an ASM permission heuristic — "who touches this during a shift" — rather than a business-domain IA. The new 13 nav modules are derived from `docs/compare/Kosa_Handbook_Alignment_Assessment.md`'s domain rings and standard card-platform taxonomy (Way4/VisionPlus); see `AdminLive.nav_modules/0`.

Adding a live module is still **two** edits, not four:

```elixir
# 1. Register it — nav_module, group and order decide where it appears.
"gl" => %{label: "General Ledger", icon: "📒", nav_module: "finance", group: "Ledger", order: 10},

# 2. Add its render branch.
<% "gl" -> %>
  <.live_component module={GlComponent} id="gl-component" current_operator={@current_operator} />
```

`order` is a single integer per nav module, spaced by 10s and increasing continuously across all of that nav module's groups (not reset per group). The sidebar clusters items into groups by adjacency after sorting by `order` — see `AdminLive.grouped_items_for_nav_module/2` — so there is no separate "group order" field to keep in sync.

### 2.1 Coming-soon placeholders

`AdminLive.@coming_soon` holds real, already-identified gaps (from the Kosa alignment assessment) given a home in the nav ahead of being built — e.g. Chargeback Cases, Party 360, Accounting Periods. Each entry has `id, label, icon, nav_module, group, order`, uses `order >= 900` so it always sorts after any live item in the same group, and needs **no `RolePermission` rows** — there is nothing behind it yet to protect. These are not yet rendered (that starts in Phase 2, as inert greyed-out "Soon" items); Phase 1 only defines the data.

Plus **one** permission edit, which is a deliberate business decision rather than boilerplate:

```elixir
# lib/vmu_core/asm/role_permission.ex
@modules ~w[... gl]                       # whitelist
{"SUPERVISOR", "gl", ~w[view edit]},      # who may see and act
```

A module absent from `RolePermission.@modules`, or granted to no role, **will not appear for anyone except ADMIN**. That is intended — the menu should never advertise something the operator cannot open — but it is also the failure mode to check first when a new screen does not show up.

---

## 3. Nav modules

Thirteen, in display order (`AdminLive.nav_modules/0`). A nav module renders in the sidebar only when the operator can see at least one live item in it — but note it will still render once Phase 2 adds the top dock, since coming-soon items are not permission-gated (§2.1).

| # | Nav module | Live groups today | Test for "does it belong here?" |
|---|---|---|---|
| 1 | Overview | — (coming soon) | Portfolio-level KPIs, not any one product's data |
| 2 | Party & Customer | Customer Management, Onboarding & KYC | It's about *who* the customer is, before any product |
| 3 | Cards & Accounts | Accounts, Card Products, Product Configuration | A specific card/account product and its configuration |
| 4 | Platform Configuration | Hierarchy, Framework | System-wide config, not any one product |
| 5 | Authorization & Switching | Live Authorization | It answers "what did the switch do?" |
| 6 | Transactions & Settlement | Inquiry | Post-authorization transaction lifecycle (clearing/settlement) |
| 7 | Collections & Recovery | Servicing, Management Information | Delinquency servicing and its MI |
| 8 | Disputes & Chargebacks | Disputes | Customer- or network-facing case work over a transaction |
| 9 | Risk, Fraud & Compliance | — (coming soon) | Detection/decisioning, not day-to-day servicing |
| 10 | Finance & General Ledger | Ledger, Period Control | An accountant or finance controller cares about it |
| 11 | Merchant & Acquiring | — (coming soon) | MBS has no admin UI yet |
| 12 | Loyalty & Rewards | — (coming soon) | LMS has no admin UI yet |
| 13 | Security & Access | Approvals & Audit, Identity & Access | It governs *who may act*, not what the business does |

This supersedes the old flat 5-section grouping (`:hierarchy/:operations/:financial/:fas/:security`), which was an ASM permission heuristic rather than a business-domain IA — see §2 for why and when that changed.

`order` is spaced by 10s and increases continuously across a nav module's groups, so a module (or a whole group) can be inserted without renumbering everything after it.

---

## 4. Permissions

### 4.1 Model

`asm_role_permissions` is a `{role, module, action}` matrix, checked by `ASM.Authz.can?/3`. Actions are `view`, `create`, `edit`, `approve`.

`view` is what controls menu visibility. The other three gate actions inside the screen.

### 4.2 Roles

| Role | Intent |
|---|---|
| `ADMIN` | Everything. `permitted_modules/1` short-circuits to the full list |
| `SUPERVISOR` | Sees everything operational, edits, and approves 4-eyes requests |
| `OPS` | Runs day-to-day processing — EOD, collections, settlement |
| `CS_AGENT` | Customer-facing servicing; read-heavy |
| `TELLER` | Narrow transactional subset |
| `RISK` | Authorization, exceptions, risk decisions |
| `COMPLIANCE` | Read + audit across the estate |

### 4.3 Granting a new module

Ask two questions, in this order:

1. **Who needs to *see* it?** Grant `view` narrowly. Menu clutter is a real cost — an operator who cannot use a screen should not be shown it.
2. **Who may *change* things?** `edit` and `approve` are separate grants. Do not bundle them with `view` out of convenience.

GL as the worked example:

| Role | Grant | Reasoning |
|---|---|---|
| SUPERVISOR | `view edit` | Closes and locks accounting periods — a supervisory act with permanent consequences |
| OPS | `view` | Runs EOD and settlement, so must read the ledger; must not close periods |
| COMPLIANCE | `view` | Audit and review |
| CS_AGENT, TELLER, RISK | none | No part of their job |

### 4.4 Irreversible actions

Anything that cannot be undone needs `edit` **and** a confirmation in the UI. GL period locking is the current example: `Periods.lock_period/1` refuses to reopen afterwards, and the button carries a `data-confirm`. Treat that as the pattern, not an exception.

---

## 5. Checklist for a new admin screen

- [ ] Row in `AdminLive.@modules` with `label`, `icon`, `nav_module`, `group`, `order`
- [ ] Render branch in `AdminLive`
- [ ] Component aliased in the `alias VmuCoreWeb.Live.Admin.{...}` block
- [ ] Module added to `RolePermission.@modules`
- [ ] Grants added to `default_matrix` for each role that needs it
- [ ] Permissions seeded (`mix run priv/repo/seed_role_permissions.exs`)
- [ ] Component accepts an `embedded` assign and skips its own page header when true, so it can be embedded in a Party 360-style tab
- [ ] Irreversible actions carry `data-confirm`

---

## 6. Known remaining debt

**`expand_module_config_visibility/1`** is still a special case: `module_config` piggybacks on the `system` permission instead of having its own rows. It should get real permission rows and the workaround should be deleted. Left alone here because changing it alters who can reach Module Configuration, which is a permission decision rather than a refactor.

**Resolved.** `test/admin/menu_registry_test.exs` now guards registry/permission consistency (every `@modules` key present in `RolePermission.modules()` and granted to at least one role, or explicitly declared `admin_only`) plus the new nav-module/group shape — the class of bug that shipped GL invisible would now fail at `mix test`, not in the browser.
