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

        <div :if={@runs != []} class="table-wrapper">
          <table class="data-table">
            <thead>
              <tr>
                <th>EOD Date</th>
                <th :for={w <- EodMonitor.eod_workers()}><%= EodMonitor.short_worker(w) %></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={run <- @runs}>
                <td><%= run.eod_date %></td>
                <td :for={w <- EodMonitor.eod_workers()}>
                  <.state_counts counts={Map.get(run.workers, w, %{})} />
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.form_card>

      <.form_card title="Needs Attention">
        <.empty_state :if={@attention == []} icon="✅" title="Nothing needs attention" message="No retryable, discarded, or stuck jobs in the eod queue." />

        <%!-- Plain HTML, deliberately — Retry is exercised directly by
            cms_eod_component_test.exs via `element("button", "Retry")
            |> render_click()`, and the "stuck" hint text is asserted on
            directly too. AG Grid's actions cells are built entirely
            client-side (phx-update="ignore") and are invisible to
            Phoenix.LiveViewTest, which never executes JS — so this table
            has to stay real server-rendered HTML. See
            docs/shared/Admin_Menu_Standard.md §5. --%>
        <table :if={@attention != []} class="data-table">
          <thead>
            <tr><th>ID</th><th>Worker</th><th>State</th><th>Attempt</th><th>Account/Cycle</th><th>Error</th><th>Since</th><th></th></tr>
          </thead>
          <tbody>
            <tr :for={job <- @attention}>
              <td><%= job.id %></td>
              <td><%= EodMonitor.short_worker(job.worker) %></td>
              <td><.job_state_badge state={job.state} /></td>
              <td><%= job.attempt %>/<%= job.max_attempts %></td>
              <td><%= job_target(job) %></td>
              <td><%= last_error(job) %></td>
              <td><%= format_dt(job.attempted_at || job.inserted_at) %></td>
              <td>
                <button :if={@can_edit and job.state in ["retryable", "discarded"]}
                        class="btn-sm btn-warning" phx-click="retry" phx-value-id={job.id} phx-target={@myself}>
                  Retry
                </button>
                <span :if={job.state == "executing"} class="text-muted">stuck — verify before acting</span>
              </td>
            </tr>
          </tbody>
        </table>
      </.form_card>
    </div>
    """
  end

  attr :counts, :map, required: true

  defp state_counts(assigns) do
    ~H"""
    <span :if={@counts == %{}} class="text-muted">—</span>
    <span :for={{state, n} <- @counts} class={"badge #{state_cls(state)}"} style="margin-right:0.25rem">
      <%= n %> <%= state %>
    </span>
    """
  end

  attr :state, :string, required: true

  defp job_state_badge(assigns) do
    ~H"""
    <span class={"badge #{state_cls(@state)}"}><%= @state %></span>
    """
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
