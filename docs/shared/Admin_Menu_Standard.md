# Admin Menu, Sections & Permissions — Standard

| Property | Value |
|---|---|
| Date | 2026-08-03, revised 2026-08-21 |
| Status | **Adopted.** Navigation is generated from `VmuCoreWeb.Admin.Nav`; hand-listing is no longer possible without reverting the change. |
| Applies to | `VmuCoreWeb.Admin.Nav`, `VmuCoreWeb.Live.Admin.AdminLive`, `VmuCoreWeb.Icons`, `VmuCore.ASM.RolePermission`, every admin LiveComponent |

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

**`VmuCoreWeb.Admin.Nav` is the single source of truth for navigation. The dock and the sidebar are generated from it.**

As of 2026-08-21 the taxonomy has three levels, not two:

```
nav module   (top dock — a business domain of a card issuer)
  └─ group   (sidebar heading)
       └─ item  (a leaf screen)
```

This replaced the old flat five-section grouping (`:hierarchy/:operations/:financial/:fas/:security`), which was an ASM permission heuristic — "who touches this during a shift" — rather than an information architecture. It put Debit Cards, KYC Requests and Collections in one undifferentiated "Operations" bucket, which is fine at ten screens and unusable at sixty.

The thirteen nav modules are the domains of an **issuing** platform, in the shape VisionPlus and Way4 organise them, cross-checked against `docs/compare/Kosa_Handbook_Alignment_Assessment.md`'s domain rings. Note this is deliberately *not* the taxonomy of the acquiring backoffice whose visual design this console follows: an issuer's spine runs Customer → Account → Card → Authorization → Billing → Collections, where an acquirer's runs Merchant → Terminal → Payments → Clearing → Settlement.

Adding a live screen is still **two** edits, not four:

```elixir
# 1. Register it in VmuCoreWeb.Admin.Nav's @items.
%{id: "gl", label: "General Ledger", icon: "book-open",
  nav_module: "finance", group: "Ledger", group_order: 10, order: 10, status: :live},

# 2. Add its render branch in AdminLive.
<% "gl" -> %>
  <.live_component module={GlComponent} id="gl-component" current_operator={@current_operator} />
```

`group_order` positions the group within its module; `order` positions the item within its group. Both are spaced by 10s so anything can be inserted without renumbering its neighbours.

An item's `id` is simultaneously its permission key, its URL segment and its render-branch key — the three must agree, and the guard test checks that they do.

Plus **one** permission edit, which is a deliberate business decision rather than boilerplate:

```elixir
# lib/vmu_core/asm/role_permission.ex
@modules ~w[... gl]                       # whitelist
{"SUPERVISOR", "gl", ~w[view edit]},      # who may see and act
```

A screen absent from `RolePermission.@modules`, or granted to no role, **will not appear for anyone except ADMIN**. That is intended — the menu should never advertise something the operator cannot open — but it is also the failure mode to check first when a new screen does not show up.

### 2.1 Planned items

An item with `status: :planned` is a real, already-identified gap given a home in the navigation ahead of being built — Chargeback representment, Party 360, Accounting Periods, and so on, mostly named in the Koṣa assessment. They render greyed out with a "Soon" badge and are not clickable.

Showing them is the point: the navigation doubles as the roadmap, and an operator can see that representment is coming rather than concluding it does not exist.

Planned items need **no `RolePermission` rows** — there is nothing behind them to protect — and so are not permission-filtered. A nav module whose items are all planned (Overview, Risk, Loyalty) renders a placeholder page listing them, rather than an access-denied panel.

### 2.2 Icons

Icons come from `VmuCoreWeb.Icons`, an inline SVG `<symbol>` sprite. Emoji were the previous answer; they render differently on every platform and cannot take the surrounding text colour, which makes accent-tinted navigation impossible.

Reference one by name (`icon: "book-open"`). A name with no symbol behind it renders a dash rather than raising — and the guard test fails, so it does not reach a browser.

### 2.3 Accents

Each nav module owns one hue, defined in `priv/static/assets/admin.css` as `[data-accent="…"]`, so it reads as the same colour in its dock tile, its sidebar identity block and its active sidebar item. Accents must be unique across modules — two domains sharing a hue defeats the purpose, and the guard test enforces it.

---

## 3. Nav modules

Thirteen, in dock order (`VmuCoreWeb.Admin.Nav.nav_modules/0`). Every one is always shown in the dock, including modules with nothing built yet, so the dock reads as the platform's shape rather than only its finished parts.

| # | Nav module | Accent | Live groups today | Test for "does it belong here?" |
|---|---|---|---|---|
| 1 | Overview | indigo | — | Portfolio-level KPIs, not any one product's data |
| 2 | Customer & Party | violet | Customer Management, Onboarding & KYC | *Who* the customer is, before any product |
| 3 | Cards & Accounts | sky | Accounts, Card Products | A card/account product instance and its lifecycle |
| 4 | Authorization & Switching | emerald | Live Authorization | It answers "what did the switch do, in real time?" |
| 5 | Transactions & Clearing | teal | Inquiry | Post-authorization lifecycle — clearing, settlement, recon |
| 6 | Billing & Statements | amber | Cycle Processing | Cycle, statement, interest, fee and payment processing |
| 7 | Collections & Recovery | orange | Servicing, Management Information | Delinquency servicing and recovery |
| 8 | Disputes & Chargebacks | rose | Case Management | Case work contesting a transaction |
| 9 | Risk, Fraud & Compliance | fuchsia | — | Detection and decisioning, not day-to-day servicing |
| 10 | Finance & General Ledger | blue | Ledger | An accountant or finance controller cares about it |
| 11 | Loyalty & Rewards | cyan | — | LMS has no admin UI yet |
| 12 | Platform Configuration | purple | Parameter Hierarchy, Framework | System-wide config, not any one product |
| 13 | Security & Access | slate | Approvals & Audit, Identity & Access | It governs *who may act*, not what the business does |

Two placement calls worth recording, because both are the kind that get re-litigated:

**All four levels of the SYS → BANK → LOGO → BLOCK cascade live in Platform Configuration**, not split with LOGO/BLOCK under Cards. They are two rungs of one parameter-resolution ladder and every downstream module reads them that way; splitting them would read as "card product setup" and hide the cascade.

**EOD and Cycle Resegmentation live in Billing, not Finance.** EOD is the nightly batch that accrues interest, assesses fees, generates statements and ages delinquency — it is billing-period processing. Finance is the ledger the results post *to*, and its audience is the person closing an accounting period, not the person running the cycle.

### 3.1 What is deliberately absent

**There is no Merchant or Acquiring module.** vmu_core carries MBS code (`mbs_merchants`, `mbs_terminals`, `mdr_engine`) with no admin UI, so a Merchant module would have been all placeholders — and the acquiring side of this estate has its own platform, `Acuiring-Switch/backoffice`, whose console already owns Merchant, Terminal, Payments, Clearing and Settlement as first-class modules. Adding a competing merchant taxonomy here would invite two answers to "where do I onboard a merchant?".

Revisit this if MBS grows a real servicing UI in vmu_core, or if the two consoles merge. Loyalty's `merchant_funding` screen is a deliberate exception: it is loyalty-programme configuration that happens to reference merchants, not merchant management.

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

## 5. AG Grid — the `<.ag_grid>` contract

`VmuCoreWeb.Components.AgGrid` (`lib/vmu_core_web/components/ag_grid.ex`) is the one reusable pattern every table conversion follows, established on three pilot screens (Phase 5 of the top-nav/AG-Grid plan) and then rolled out further (Phase 6). Do not re-derive it per screen.

```elixir
import VmuCoreWeb.Components.AgGrid

<.ag_grid
  id="debit-accounts-grid"
  columns={[
    %{field: "customer_name", header: "Customer"},
    %{field: "available_balance", header: "Available Balance", type: "money"},
    %{field: "status", header: "Status", type: "badge"},
    %{field: "actions", header: "", type: "actions",
      actions: [%{label: "View", event: "view_account", param: "id"}]}
  ]}
  rows={Enum.map(@accounts, &account_row/1)}
/>
```

`columns` and `rows` are plain JSON-safe data — no functions — passed as `data-columns`/`data-rows` attributes to a `phx-update="ignore"` div that `assets/js/hooks/ag_grid_hook.js` owns from mount onward. Sorting, filtering, pagination and column resize are AG Grid Community features and need no server round-trip.

Column `type` (optional, default plain text): `"number"` (right-aligned, tabular-nums, no forced decimals — counts), `"money"` (right-aligned, 2 decimals — currency), `"date"` (reformats an ISO-ish string — Elixir's `Date`/`DateTime`/`NaiveDateTime` all encode to one via Jason natively, no server-side formatting needed), `"badge"` (`.badge-*` pill; give it `classField: "some_row_field"` when the screen has its own status vocabulary rather than the generic ACTIVE/PENDING/etc one — see `docs/shared/Admin_Menu_Standard.md`'s badge-success/warning/error/info note below), `"mono"` (inline code-style chip — never apply `.mono` to a `<td>` directly, that renders the whole cell as a chip).

`"actions"` renders one `.btn-ghost.btn-xs` per entry in `actions: [%{label:, event:, param:, whenField:, whenValue:, danger:}]`. Clicking always pushes `%{"id" => row[param]}` — the payload key is literally `"id"`, only the value comes from `param`. `whenField`/`whenValue` hide an action unless `row[whenField] === whenValue` (conditional actions, e.g. "Revoke" only when status is ACTIVE). `danger: true` renders it in red. Always name an actions-only column `field: "actions"` (that literal string), never a real data field, or it collides with a genuine display column pulling from the same field.

### 5.1 Client-rendered buttons and `Phoenix.LiveViewTest` — superseded, see `Admin_Detail_UX_Philosophy.md`

**This section's original advice ("leave it plain HTML") is no longer the default — read `Admin_Detail_UX_Philosophy.md` §3 first.** An `actions` cell is built by JavaScript inside a `phx-update="ignore"` container, so `element("button[phx-click=...]") |> render_click()` can't find it. The fix is not to avoid converting the table — it's `Phoenix.LiveViewTest.with_target/2`, which sends the event straight to the LiveComponent by DOM id, bypassing the need for the button to exist in server-rendered HTML at all. Proven against `customer_component.ex` (760/760 tests green). One precondition: the component's root element needs `id={@id}` on it, which is missing on every admin component as of this writing — add it as step 0 for any component you're bringing under this fix.

Tables actually left as plain HTML for a **structural** reason (not test coverage) stay excluded regardless: Operators' table embeds a live `<select phx-change="change_role">` per row, and no ag_grid cell type hosts a bound form control — only display types and `phx-click` actions.

The tables listed as reverted in earlier phases (HCS's companies/employee-cards/vehicles lists, Approval Inbox's HCS-facility-limits table, KYC Methods' method list, CMS EOD's "Needs Attention" table, account_component.ex's main Credit Accounts/customer-search/Cards-issued tables, Cycle Resegmentation's Pending Changes table) were excluded under the old default and are candidates for conversion under the new one — apply `Admin_Detail_UX_Philosophy.md` §4's rollout checklist to each rather than treating this list as permanent.

### 5.2 AG Charts

`<.ag_chart>` in the same module is the equivalent for `assets/js/hooks/ag_chart_hook.js` (bar/line/donut). Built in Phase 4; wired to real screens in Phase 7: `CollectionsMiComponent`'s roll/cure-rate-by-bucket bar chart, `GlComponent`'s net-balance-by-account-class donut on the trial balance tab, and the new `PortfolioDashboardComponent` (the Overview module's first live screen — `portfolio_dashboard`, flipped from `:planned`), whose account-status donut and delinquency-bucket bar chart are genuinely global aggregates, not per-scope like the other two. Same test caveat as `actions` cells: a chart's `data-chart-data` attribute is what LiveViewTest can see (`has_element?(view, "#chart-id[data-chart-data*='...']")`) — the chart itself is client-rendered.

---

## 6. Checklist for a new admin screen

- [ ] Row in `VmuCoreWeb.Admin.Nav`'s `@items` with `id`, `label`, `icon`, `nav_module`, `group`, `group_order`, `order`, `status: :live` (or flip an existing `:planned` row to `:live`)
- [ ] `icon` names a symbol that exists in `VmuCoreWeb.Icons`
- [ ] Render branch in `AdminLive`, keyed by the same `id`
- [ ] Component aliased in the `alias VmuCoreWeb.Live.Admin.{...}` block
- [ ] Module added to `RolePermission.@modules`
- [ ] Grants added to `default_matrix` for each role that needs it
- [ ] Permissions seeded (`mix run priv/repo/seed_role_permissions.exs`)
- [ ] Component accepts an `embedded` assign and skips its own page header when true, so it can be embedded in a Party 360-style tab
- [ ] Irreversible actions carry `data-confirm`

---

## 7. Known remaining debt

**`expand_module_config_visibility/1`** is still a special case: `module_config` piggybacks on the `system` permission instead of having its own rows. It should get real permission rows and the workaround should be deleted. Left alone here because changing it alters who can reach Module Configuration, which is a permission decision rather than a refactor.

**Resolved.** `test/admin/menu_registry_test.exs` guards the whole contract: every live item is permissionable and granted (or explicitly `admin_only`); ids are unique and never shadow a nav module id; group orders are consistent; accents are unique; and every icon referenced by the taxonomy exists in the sprite. The class of bug that shipped GL invisible now fails at `mix test`, not in the browser.

`test/vmu_core_web/live/admin/admin_live_nav_test.exs` covers the rendered shell end-to-end against a real Postgres sandbox — dock, sidebar, breadcrumb, placeholder page and permission filtering.

`test/vmu_core_web/live/admin/dump_shell_html_test.exs` is a `:dump`-tagged utility (excluded from the default run) that writes the real rendered HTML plus the stylesheet to `tmp/shell-dump/` for review in a browser: `mix test --only dump`.
