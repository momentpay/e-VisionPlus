defmodule VmuCoreWeb.Live.Admin.CmsEodComponent do
  @moduledoc """
  Admin LiveComponent: EOD job status visibility + rerun controls
  (CMS FR-057 — `CMS_Feature_Status.md`'s "most operationally significant"
  open gap). Two panels: a per-run, per-stage completion overview, and a
  "needs attention" list (retryable/discarded, plus jobs stuck `executing`
  past a real-time threshold — see `VmuCore.CMS.EodMonitor`) with a retry
  action gated to genuinely failed states only, never a stuck-executing
  row (retrying a job that may still legitimately be running risks a
  duplicate GL post).
  """

  use Phoenix.LiveComponent
  import VmuCoreWeb.AdminUI
  import VmuCoreWeb.Components.AgGrid

  alias VmuCore.CMS.EodMonitor

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(runs: [], attention: [], notice: nil, can_edit: false)
     |> load()}
  end

  @impl true
  def update(assigns, socket) do
    operator = assigns[:current_operator]
    socket = assign(socket, assigns)

    socket =
      if operator do
        assign(socket, can_edit: VmuCore.ASM.Authz.can?(operator, "cms_eod", "edit"))
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("refresh", _, socket) do
    {:noreply, load(socket)}
  end

  def handle_event("retry", %{"id" => id}, socket) do
    if socket.assigns.can_edit do
      case EodMonitor.retry_job(String.to_integer(id)) do
        :ok -> {:noreply, socket |> assign(notice: "Job ##{id} queued for retry.") |> load()}
        {:error, :not_found} -> {:noreply, assign(socket, notice: "Job ##{id} not found.")}
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot retry EOD jobs.")}
    end
  end

  defp load(socket) do
    assign(socket, runs: EodMonitor.list_runs(), attention: EodMonitor.list_failed_jobs())
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="component-panel">
      <.page_header title="EOD Job Status" subtitle="Per-run stage completion + jobs needing attention (FR-057)">
        <:actions>
          <button class="btn-sm" phx-click="refresh" phx-target={@myself}>Refresh</button>
        </:actions>
      </.page_header>

      <.alert :if={@notice} kind={:info} message={@notice} />

      <.form_card title="Runs (last 14 dates with EOD activity)">
        <.empty_state :if={@runs == []} icon="🌙" title="No EOD runs found" />

        <%!-- Columns are per-worker and therefore dynamic; the per-cell
             state badges collapse to text ("3 completed, 1 retryable"),
             the same trade-off already made for multi-badge cells in
             block_component. --%>
        <.ag_grid
          :if={@runs != []}
          id="eod-runs-grid"
          paginate={false}
          empty_message="No EOD runs found."
          columns={eod_run_columns()}
          rows={Enum.map(@runs, &eod_run_row/1)}
        />
      </.form_card>

      <.form_card title="Needs Attention">
        <.empty_state :if={@attention == []} icon="✅" title="Nothing needs attention" message="No retryable, discarded, or stuck jobs in the eod queue." />

        <.ag_grid
          :if={@attention != []}
          id="eod-attention-grid"
          paginate={false}
          empty_message="Nothing needs attention."
          columns={[
            %{field: "id", header: "ID", type: "mono", width: 90},
            %{field: "worker", header: "Worker", width: 160},
            %{field: "state", header: "State", type: "badge", classField: "state_class", width: 120},
            %{field: "attempt", header: "Attempt", width: 100},
            %{field: "target", header: "Account/Cycle", flex: 1},
            %{field: "error", header: "Error", flex: 1},
            %{field: "since", header: "Since", width: 150},
            # The "stuck" warning is a per-row note, not an action, so it
            # rides as its own column rather than being lost with the old
            # <span> that shared the actions cell.
            %{field: "note", header: "", width: 200},
            %{field: "actions", header: "", type: "actions", width: 100,
              actions: [%{label: "Retry", event: "retry", param: "row_id",
                          whenField: "can_retry", whenValue: true}]}
          ]}
          rows={Enum.map(@attention, &attention_row(&1, @can_edit))}
        />
      </.form_card>
    </div>
    """
  end

  defp eod_run_columns do
    [%{field: "eod_date", header: "EOD Date", width: 130}] ++
      Enum.map(EodMonitor.eod_workers(), fn w ->
        %{field: "w_#{w}", header: EodMonitor.short_worker(w), flex: 1}
      end)
  end

  defp eod_run_row(run) do
    EodMonitor.eod_workers()
    |> Enum.into(%{eod_date: to_string(run.eod_date)}, fn w ->
      counts = Map.get(run.workers, w, %{})
      text =
        if counts == %{},
          do: "—",
          else: Enum.map_join(counts, ", ", fn {state, n} -> "#{n} #{state}" end)

      {:"w_#{w}", text}
    end)
  end

  defp attention_row(job, can_edit) do
    %{
      row_id: to_string(job.id),
      id: job.id,
      worker: EodMonitor.short_worker(job.worker),
      state: job.state,
      state_class: state_cls(job.state),
      attempt: "#{job.attempt}/#{job.max_attempts}",
      target: job_target(job),
      error: last_error(job),
      since: format_dt(job.attempted_at || job.inserted_at),
      note: if(job.state == "executing", do: "stuck — verify before acting", else: ""),
      can_retry: can_edit and job.state in ["retryable", "discarded"]
    }
  end

  defp state_cls("completed"), do: "badge-green"
  defp state_cls("executing"), do: "badge-yellow"
  defp state_cls("retryable"), do: "badge-yellow"
  defp state_cls("discarded"), do: "badge-red"
  defp state_cls("cancelled"), do: "badge-red"
  defp state_cls(_), do: "badge-gray"

  defp job_target(%{args: %{"account_id" => id}}), do: "acct " <> String.slice(to_string(id), 0, 8)
  defp job_target(%{args: %{"cycle_code" => cc}}), do: "cycle " <> cc
  defp job_target(_), do: "—"

  defp last_error(%{errors: []}), do: "—"
  defp last_error(%{errors: errors}) do
    errors
    |> List.last()
    |> case do
      %{"error" => msg} -> String.slice(to_string(msg), 0, 80)
      other -> String.slice(inspect(other), 0, 80)
    end
  end

  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_dt(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
end
