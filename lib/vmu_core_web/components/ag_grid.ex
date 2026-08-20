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
          %{field: "id", header: "", type: "actions",
            actions: [%{label: "View", event: "view_account", param: "id"}]}
        ]}
        rows={Enum.map(@accounts, &account_row/1)}
      />

  `type` (optional, default plain text): `"money"` right-aligns and formats
  two decimals; `"date"` reformats an ISO-ish string; `"badge"` renders the
  existing `.badge-*` classes via the same status vocabulary as
  `VmuCoreWeb.AdminUI.status_badge/1`; `"mono"` renders the value as an
  inline `.mono` chip (never apply `.mono` to a `<td>` directly — see the
  design-system test); `"actions"` renders one `.btn-ghost.btn-xs` per
  entry in `actions`, each pushing `event` to the owning LiveComponent
  with `%{"id" => row[param]}`.

  Sorting, filtering, pagination and column resize are AG Grid Community
  features and need no server round-trip. When `rows` changes on
  re-render (a search, a filter, a create), the hook's `updated/0`
  re-reads the `data-rows` attribute and calls `setGridOption` — no full
  re-mount.

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
