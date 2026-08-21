defmodule VmuCoreWeb.Components.AgGrid do
  @moduledoc """
  The `<.ag_grid>` / `<.ag_chart>` components — the one reusable contract
  every admin table/dashboard conversion follows, established here rather
  than re-derived per screen. See `docs/shared/Admin_Menu_Standard.md` §5.

  ## `<.ag_grid>`

  Renders a `phx-update="ignore"` div; `assets/js/hooks/ag_grid_hook.js`
  owns everything inside it from mount onward. `columns` and `rows` are
  plain JSON-safe data — no functions, so they survive `Jason.encode!/1`
  and a DOM attribute round-trip unchanged:

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

  `type` (optional, default plain text): `"number"` right-aligns without
  forcing decimals (counts); `"money"` right-aligns and formats two
  decimals (currency); `"date"` reformats an ISO-ish string; `"badge"`
  renders the existing `.badge-*` classes via the same status vocabulary
  as `VmuCoreWeb.AdminUI.status_badge/1` by default, or `classField: "..."`
  to supply a row field holding the real class name for a screen with its
  own status vocabulary; `"mono"` renders the value as an inline `.mono`
  chip (never apply `.mono` to a `<td>` directly — see the design-system
  test); `"actions"` renders one `.btn-ghost.btn-xs` per entry in
  `actions: [%{label:, event:, param:, whenField:, whenValue:, danger:,
  confirm:}]`, each pushing `event` to the owning LiveComponent with
  `%{"id" => row[param]}` — the payload key is always literally `"id"`,
  only the value comes from `param`. `whenField`/`whenValue` hide an
  action unless `row[whenField] === whenValue` (conditional actions).
  `confirm: "Delete block {block_id}?"` shows a native confirm dialog
  before dispatching, with `{field}` filled from the row — the
  `<.ag_grid>` equivalent of `data-confirm`, required for any
  irreversible action (see "Irreversible actions" in
  `docs/shared/Admin_Menu_Standard.md` §4.4 — the same rule, just a
  different mechanism to satisfy it here). Always name an actions-only
  column `field: "actions"` — a literal data field name there collides
  with a real display column pulling from the same field.

  Sorting, filtering, pagination and column resize are AG Grid Community
  features and need no server round-trip. When `rows` changes on
  re-render (a search, a filter, a create), the hook's `updated/0`
  re-reads the `data-rows` attribute and calls `setGridOption` — no full
  re-mount.

  ## The one hard limitation

  An `actions` cell is built by JavaScript inside this component's
  `phx-update="ignore"` container. `Phoenix.LiveViewTest` never executes
  JS, so `element("button[phx-click=...]") |> render_click()` cannot find
  it. **Before converting a table, check whether an existing test drives
  one of its buttons that way** — `grep -oE 'phx-click=[a-z_]+'` over the
  relevant test file(s), including tests in *other* components that may
  exercise this one's events cross-component. If a button is driven
  directly, leave that table as plain HTML. See
  `docs/shared/Admin_Menu_Standard.md` §5.1 for the real conversions this
  reverted.

  ## `<.ag_chart>`

  Same shape, for `assets/js/hooks/ag_chart_hook.js`:

      <.ag_chart id="collections-mi-trend" type="line" title="30-Day Recovery Trend"
        data={@trend} category="date" series={[%{field: "recovered", name: "Recovered"}]} />
  """

  use Phoenix.Component

  attr :id, :string, required: true
  attr :columns, :list, required: true
  attr :rows, :list, required: true
  attr :empty_message, :string, default: "No rows to show."
  attr :paginate, :boolean, default: true, doc: "false for a screen that already paginates server-side"
  attr :rest, :global

  def ag_grid(assigns) do
    assigns =
      assigns
      |> assign(:columns_json, Jason.encode!(assigns.columns))
      |> assign(:rows_json, Jason.encode!(assigns.rows))

    ~H"""
    <div
      id={@id}
      phx-hook="AgGrid"
      phx-update="ignore"
      class="ag-theme-quartz ag-grid-panel"
      data-columns={@columns_json}
      data-rows={@rows_json}
      data-empty-message={@empty_message}
      data-paginate={to_string(@paginate)}
      {@rest}
    />
    """
  end

  attr :id, :string, required: true
  attr :type, :string, default: "bar", values: ~w(bar line donut)
  attr :title, :string, default: nil
  attr :data, :list, required: true
  attr :category, :string, default: "label"
  attr :series, :list, default: [%{field: "value", name: "Value"}]
  attr :rest, :global

  def ag_chart(assigns) do
    assigns =
      assigns
      |> assign(:data_json, Jason.encode!(assigns.data))
      |> assign(:series_json, Jason.encode!(assigns.series))

    ~H"""
    <div
      id={@id}
      phx-hook="AgChart"
      phx-update="ignore"
      class="ag-chart-panel"
      data-chart-type={@type}
      data-chart-title={@title}
      data-chart-data={@data_json}
      data-category={@category}
      data-series={@series_json}
      {@rest}
    />
    """
  end
end
