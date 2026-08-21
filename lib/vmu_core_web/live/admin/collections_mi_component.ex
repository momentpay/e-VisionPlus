defmodule VmuCoreWeb.Live.Admin.CollectionsMiComponent do
  @moduledoc """
  Admin LiveComponent: Collections MI dashboard (FR-COL-025) — roll rates,
  cure rates, promise-kept %, recovery %, all for an operator-chosen date
  range. Read-only reporting, no mutations — `col:view` is the only gate
  needed (mirrors `col:edit`'s pattern for consistency, but nothing here
  actually requires it).

  See `VmuCore.COL.CollectionsMi` for the metric definitions, and its
  moduledoc's note that roll/cure rate only has data from whenever
  `col_dpd_bucket_history` started recording (this phase) — an empty
  result for an older date range is the honest answer.
  """

  use Phoenix.LiveComponent
  import VmuCoreWeb.AdminUI
  import VmuCoreWeb.Components.AgGrid

  alias VmuCore.COL.CollectionsMi

  @impl true
  def mount(socket) do
    today = Date.utc_today()

    {:ok,
     socket
     |> assign(
       from_date: Date.add(today, -90), to_date: today,
       promise: nil, recovery: nil, roll_cure: []
     )
     |> load()}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("filter", %{"from_date" => from, "to_date" => to}, socket) do
    with {:ok, from_date} <- Date.from_iso8601(from),
         {:ok, to_date} <- Date.from_iso8601(to) do
      {:noreply, socket |> assign(from_date: from_date, to_date: to_date) |> load()}
    else
      _ -> {:noreply, socket}
    end
  end

  defp load(socket) do
    %{from_date: from_date, to_date: to_date} = socket.assigns

    assign(socket,
      promise: CollectionsMi.promise_kept_rate(from_date, to_date),
      recovery: CollectionsMi.recovery_rate(from_date, to_date),
      roll_cure: CollectionsMi.roll_cure_rates(from_date, to_date)
    )
  end

  defp fmt_pct(nil), do: "—"
  defp fmt_pct(d), do: "#{d}%"

  defp roll_cure_row(r) do
    %{
      bucket: r.bucket,
      cohort_size: r.cohort_size,
      rolled: r.rolled,
      roll_rate: fmt_pct(r.roll_rate),
      cured: r.cured,
      cure_rate: fmt_pct(r.cure_rate)
    }
  end

  defp roll_cure_chart_row(r) do
    %{
      bucket: "#{r.bucket}",
      roll_rate: r.roll_rate || 0,
      cure_rate: r.cure_rate || 0
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="component-panel">
      <.page_header title="Collections MI" subtitle="Roll rates, cure rates, promise-kept %, recovery % (FR-COL-025)" />

      <form phx-change="filter" phx-target={@myself} style="display:flex; gap:0.5rem; align-items:end; margin-bottom:1rem">
        <div class="field" style="margin:0">
          <label>From</label>
          <input type="date" name="from_date" value={Date.to_iso8601(@from_date)} />
        </div>
        <div class="field" style="margin:0">
          <label>To</label>
          <input type="date" name="to_date" value={Date.to_iso8601(@to_date)} />
        </div>
      </form>

      <div style="display:flex; gap:1rem; flex-wrap:wrap; margin-bottom:1rem">
        <.form_card title="Promise-kept %">
          <.kv_detail rows={[
            {"Kept", @promise.kept},
            {"Broken", @promise.broken},
            {"Still pending", @promise.pending},
            {"Rate", fmt_pct(@promise.rate)}
          ]} />
        </.form_card>

        <.form_card title="Recovery %">
          <.kv_detail rows={[
            {"Written off in period", @recovery.cohort_size},
            {"Written-off total", @recovery.written_off_total},
            {"Recovered total", @recovery.recovered_total},
            {"Rate", fmt_pct(@recovery.rate)}
          ]} />
        </.form_card>
      </div>

      <.form_card :if={@roll_cure != []} title="Roll rate / cure rate trend">
        <.ag_chart
          id="collections-mi-roll-cure-chart"
          type="bar"
          data={Enum.map(@roll_cure, &roll_cure_chart_row/1)}
          category="bucket"
          series={[
            %{field: "roll_rate", name: "Roll rate %"},
            %{field: "cure_rate", name: "Cure rate %"}
          ]}
        />
      </.form_card>

      <.form_card title="Roll rate / cure rate by DPD bucket"
                  subtitle="Cohort = accounts that transitioned INTO the bucket during the period. Roll = later reached a higher bucket. Cure = later reached 0.">
        <.ag_grid
          id="collections-mi-roll-cure-grid"
          paginate={false}
          empty_message="No bucket transitions in this date range."
          columns={[
            %{field: "bucket", header: "Bucket", width: 140},
            %{field: "cohort_size", header: "Cohort", type: "number", width: 110},
            %{field: "rolled", header: "Rolled", type: "number", width: 110},
            %{field: "roll_rate", header: "Roll rate", width: 110},
            %{field: "cured", header: "Cured", type: "number", width: 110},
            %{field: "cure_rate", header: "Cure rate", width: 110}
          ]}
          rows={Enum.map(@roll_cure, &roll_cure_row/1)}
        />
        <p class="text-muted" style="margin-top:0.5rem; font-size:0.85em">
          A cohort of 0 for an older date range is expected, not a bug — bucket-transition history (col_dpd_bucket_history) only started recording 2026-07-24.
        </p>
      </.form_card>
    </div>
    """
  end
end
