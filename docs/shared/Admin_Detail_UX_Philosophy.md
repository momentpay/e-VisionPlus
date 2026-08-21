# Admin Detail UX Philosophy — AG Grid Scope & the Detail Drawer

Written 2026-08-21 in response to real feedback on the admin console redesign:
Customers (CIF), Accounts, and other primary lists were left as plain HTML
instead of AG Grid specifically to avoid breaking `Phoenix.LiveViewTest`
coverage (see `Admin_Menu_Standard.md` §5.1) — but those are exactly the
tables that most need AG Grid's scale features, and the tables that *did*
get AG Grid in a few places (Tram Inquiry's Identifiers/Event Timeline) are
single-record, fixed-size displays that never needed it. Both are corrected
here, with a proven fix for the test problem rather than a workaround.

**Before extending this pattern, do the research first** — this document
exists because "we already do this in backoffice" turned out to be only
half true (§3) and needed verifying, not assuming, before being copied.

---

## 1. When AG Grid, when a plain list

**Use `<.ag_grid>` for anything that grows with platform activity** —
customers, accounts, transactions, disputes, audit entries, cards. These
are searchable/sortable/potentially-paginated collections today or will be
once the system has real usage, and AG Grid's chrome (sort, filter,
resize, pagination) earns its place.

**Do not use `<.ag_grid>` for a single record's own fixed-shape fields**
— a transaction's Identifiers (1 row, capped at 4 ever), a transaction's
own Event Timeline (grows only with that one transaction's lifecycle, a
handful of rows). These are a record's fields laid out as a table, not a
dataset. AG Grid's filter icons and column-menu affordances on a table
that will never have more than a few rows misleads the operator into
thinking there's something to search, and is visual noise the small
table doesn't need. Rule of thumb: **if the row count is bounded by one
parent record's own structure, it's a plain list; if it's bounded by
platform-wide activity, it's AG Grid.**

Concrete correction: `TramInquiryComponent`'s Identifiers and Event
Timeline tables (added in Phase 6 alongside the real Results grid) should
never have been AG Grid — revert them to plain `<table>` markup. The
Results grid at the bottom of that screen (paginated, searchable,
platform-wide) is correctly AG Grid and stays.

---

## 2. The right-side detail drawer

Replaces two patterns at once, consistently, everywhere a row has a
View/Edit/Detail action:

- **The same-page mode-swap** (`account_component.ex` / `customer_component.ex`
  setting `@mode = :detail`, replacing the entire list with the detail view)
- **The in-page detail block** (`tram_inquiry_component.ex` rendering the
  selected transaction's detail above its own results table)

Both make the operator lose their place — the list disappears and has to
be re-searched/re-scrolled back to. A drawer keeps the list visible
(dimmed under a backdrop) and returns exactly where the operator left off
on close.

**One reusable component**, not a copy-pasted block per screen (see §3 for
why that specifically was backoffice's mistake to avoid repeating):
`VmuCoreWeb.Components.Drawer.detail_drawer/1`, sibling to
`VmuCoreWeb.Components.AgGrid`.

Contract:
```heex
<.detail_drawer id="customer-detail-drawer" open={@mode == :detail} title={@viewing && full_name(@viewing)} on_close="cust_back">
  <%= render_detail_body(assigns) %>
</.detail_drawer>
```
- `open` toggles a CSS class (`.drawer-open`), not a `:if` — the drawer's
  DOM stays mounted so the slide-in transition has something to animate
  from/to. A real `transform: translateX(100%) → translateX(0)` transition
  plus a fading backdrop opacity, not backoffice's instant snap
  (`docs/shared/Admin_Detail_UX_Philosophy.md` §3 — theirs has none).
- Backdrop click, an `×` button, and Esc (`phx-window-keydown` scoped to
  `open`) all fire `on_close`.
- Deep-linkable: pair with `push_patch(socket, to: ~p"/visionplus/admin/#{mod}?view=#{id}")`
  the same way `account_component.ex`'s `deep_link_id` /
  `AdminLive.handle_params/3`'s `?view=` param already work for Koṣa
  cross-product links — a drawer opened this way should be shareable via
  URL and survive a refresh, not just live in a transient assign.
- Width: `max-width: 640px` (roughly backoffice's `max-w-xl`, a reasonable
  precedent) but token-driven (`--drawer-width` in `admin.css`) so a screen
  with wider detail content (e.g. Account's tabbed detail view) can override
  it rather than fighting a hardcoded value.

---

## 3. Testing: the real fix, verified in this codebase

**What backoffice actually did — checked before assuming otherwise.** The
user pointed to backoffice as proof this is solvable. Research confirmed
the *runtime* mechanism is identical to what `ag_grid_hook.js` already
does (a JS-built button calling `pushEvent`/`pushEventTo`) — but
backoffice's answer to the LiveViewTest-can't-see-client-rendered-buttons
problem was **not writing test coverage for any AG-Grid-backed screen**.
Zero test files reference their AG Grid hooks or mount those LiveViews.
Their slide-over drawer is similarly real and working at runtime, but
copy-pasted per-screen (no shared component) and also untested. Copying
backoffice here would mean trading vmu_core's test coverage away — not
something to do silently.

**The actual fix**, proven against `customer_component.ex` in this
session (760/760 tests green after conversion):

`Phoenix.LiveViewTest.with_target/2` sends an event straight to a named
LiveComponent's `handle_event/3`, without requiring the triggering element
to exist in server-rendered HTML at all — exactly the gap `element(selector)
|> render_click()` can't cross for a JS-built AG Grid button.

```elixir
# Old — breaks the moment the button is JS-rendered instead of server-rendered:
view |> element("button[phx-click=cust_view][phx-value-id='#{id}']") |> render_click()

# New — targets the LiveComponent directly, works regardless of how the
# triggering element was rendered:
view |> with_target("#customer-component") |> render_click("cust_view", %{"id" => id})
```

**One precondition, and it's currently missing on every admin
component**: `with_target("#some-id")` resolves via a real CSS selector
against the rendered DOM tree (`Phoenix.LiveViewTest.DOM.targets_from_selector/2`
— confirmed by reading the dependency source directly, not assumed), so
the LiveComponent's root element must actually carry that `id` as an HTML
attribute. Phoenix does **not** stamp this automatically just because
`<.live_component id="customer-component" .../>` was called with that id —
it only appears if the component's own template writes `id={@id}` on its
root. As of this writing every `lib/vmu_core_web/live/admin/*_component.ex`
is missing it (confirmed by grep; `customer_component.ex` was the first
fixed). **Add `id={@id}` to a component's root `<div>` as step 0 before
using `with_target` against it** — a one-line, behavior-neutral change
(verified: adding it to `customer_component.ex` didn't change rendered
output, only made the root element addressable).

For a JS-hook-originated push (not a plain button click — e.g. a future
custom cell renderer that calls `pushEventTo` directly rather than through
the `actions` contract), the equivalent is `render_hook/3` instead of
`render_click/3`, same `with_target` targeting.

### 3.1 Always `to_string/1` the row id — a real production crash

`phx-value-id` is an HTML attribute, so a handler reached that way **always**
receives a string; handlers written against it routinely call
`String.to_integer/1`. AG Grid's payload does not come from an attribute —
it comes from `data-rows` JSON, which preserves the integer as an integer.
Converting a table whose records have integer primary keys therefore hands
`String.to_integer/1` an integer and raises `ArgumentError: not a binary`
on click.

This is silent at compile time and invisible to any test that passes an
integer id (the test crashes the same way the browser would, so it does at
least fail loudly once written). It was hit for real on the EOD retry
action during this rollout, and would equally have broken HCS
(company/employee/vehicle), GL periods, and the approval inbox — every
screen whose ids are integers rather than UUIDs.

**Rule: every `row_id:` in a row-mapping function is wrapped in
`to_string/1`**, so the AG Grid payload is byte-identical to what
`phx-value-id` would have produced and the handler's existing contract is
untouched. Tests should pass `to_string(record.id)` for the same reason —
a test passing a bare integer is testing something the browser never does.

---

## 4. Rollout checklist, per screen

1. Add `id={@id}` to the component's root element, if missing (§3).
2. Convert the primary list to `<.ag_grid>`, including its View/Edit/Delete
   actions via the `actions` cell type — no longer excluded just because a
   test drives them (per `Admin_Menu_Standard.md` §5.1's now-superseded
   default of "leave it plain HTML").
3. Rewrite any test that drove those buttons via `element(...) |>
   render_click()` to `with_target("#<component-id>") |> render_click(event,
   payload)` instead (§3's before/after).
4. Replace the screen's same-page detail swap (or in-page detail block)
   with `<.detail_drawer>` (§2), wiring `open`/`on_close` to the existing
   mode/selection assigns rather than inventing new state.
5. Audit every table on the screen against §1's rule before touching it —
   a screen can have both AG-Grid-worthy tables (its main list) and
   plain-list tables (a selected record's own small fixed sub-table) at
   the same time; converting everything on a screen uniformly is the
   Tram Inquiry mistake this document exists to correct.
6. `mix test` (scoped, then full suite) + `mix assets.build` if
   `assets/js/` changed, same verification discipline as every other
   conversion this rollout has done.

---

## Status

**Done** (763 tests green throughout):

- §3's `with_target` technique, proven and now used across every converted
  screen. Precondition `id={@id}` applied to all 26 components — *and to
  every `render/1` clause*, not just the first: components with `:list` /
  `:detail` clauses kept an un-addressable root in their other modes, which
  made `with_target` silently fall through to `AdminLive`.
- `<.detail_drawer>` built (§2) and in use on Tram Inquiry.
- §1's rule applied. Converted (grow with platform activity): Customers,
  Accounts + Cards + wizard search, Debit/Prepaid/Wallet account lists and
  wizard searches, HCS companies/employee-cards/vehicles, DPS disputes, GL
  shadow-diff/posting-rules/periods/exceptions, Approval Inbox facility
  limits, EOD runs + needs-attention, Cycle Resegmentation pending changes.
  Reverted to plain (bounded by one parent record): Tram Inquiry's
  Identifiers and Event Timeline.
- Contract gaps closed along the way: `params:` for handlers keyed on more
  than an id; `row_class_field` so row-level highlighting (a GL shadow
  mismatch) survives the move off hand-written `<tr>`; and §3.1's
  `to_string/1` rule, which was a real crash.

**Remaining:**

- **Collections case list** — the one list that should be a grid and is
  not. Each row carries a bound checkbox feeding a bulk "Place selected"
  form; no cell type hosts a bound control, and AG Grid's own row selection
  would need a new selection→LiveView bridge in the contract. Deliberately
  deferred rather than bodged: doing it half-way breaks the bulk action.
- **Operators list** — same class of block (`<select phx-change>` per row),
  but a much smaller list, so lower value.
- **Drawer rollout beyond Tram Inquiry.** Customers, Accounts, Debit,
  Prepaid, Wallet and HCS still swap the whole page for their detail view
  (`@mode = :detail`). The drawer exists and is proven; moving each screen
  onto it is mechanical but touches their detail markup and the tests that
  assert on it, so it is its own pass rather than a rider on this one.
