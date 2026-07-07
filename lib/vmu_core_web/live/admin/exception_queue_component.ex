defmodule VmuCoreWeb.Live.Admin.ExceptionQueueComponent do
  @moduledoc """
  Admin LiveComponent: FAS exception queue viewer (FAS-P8 8D).

  Displays unmatched reversals, and surfaced STAN duplicates or GL variance
  records from `fas_reversal_exceptions`. Operators can resolve or escalate
  individual exceptions and monitor the hold aging alert from `HoldAgingMonitor`.

  Subscribes to:
    - `"fas:hold_alerts"` — {:hold_aging_alert, %{expired_count, oldest_minutes}}
    - `"fas:risk_alerts"` — {:fas_risk_alert, payload}
  """

  use Phoenix.LiveComponent
  import Ecto.Query
  import VmuCoreWeb.AdminUI

  alias VmuCore.{Repo, FAS.ExceptionQueue}

  @per_page 25

  @impl true
  def mount(socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(VmuCore.PubSub, "fas:hold_alerts")
      Phoenix.PubSub.subscribe(VmuCore.PubSub, "fas:risk_alerts")
    end

    {:ok,
     socket
     |> assign(
       filter_status: "pending",
       exceptions: [],
       total: 0,
       page: 1,
       hold_alert: nil,
       risk_alerts: [],
       notice: nil,
       # Overridden by AdminLive from Authz.can?(op, "exceptions", "approve")
       can_approve: false
     )
     |> load_exceptions()}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    {:noreply,
     socket
     |> assign(filter_status: status, page: 1)
     |> load_exceptions()}
  end

  def handle_event("resolve", %{"id" => id}, socket) do
    if socket.assigns.can_approve do
      update_exception(id, "resolved", socket)
    else
      {:noreply, assign(socket, notice: "Your role cannot approve exception actions.")}
    end
  end

  def handle_event("escalate", %{"id" => id}, socket) do
    if socket.assigns.can_approve do
      update_exception(id, "escalated", socket)
    else
      {:noreply, assign(socket, notice: "Your role cannot approve exception actions.")}
    end
  end

  def handle_event("next_page", _, socket) do
    {:noreply,
     socket
     |> assign(page: socket.assigns.page + 1)
     |> load_exceptions()}
  end

  def handle_event("prev_page", _, socket) do
    page = max(1, socket.assigns.page - 1)

    {:noreply,
     socket
     |> assign(page: page)
     |> load_exceptions()}
  end

  @impl true
  def handle_info({:hold_aging_alert, payload}, socket) do
    {:noreply, assign(socket, hold_alert: payload)}
  end

  def handle_info({:fas_risk_alert, payload}, socket) do
    alerts = [payload | Enum.take(socket.assigns.risk_alerts, 9)]
    {:noreply, assign(socket, risk_alerts: alerts)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="component-panel">
      <.page_header title="FAS Exception Queue"
                    subtitle="Unmatched reversals, hold aging alerts, and risk declines" />

      <%# Hold aging alert banner %>
      <%= if @hold_alert do %>
        <.alert kind={:warning}
                message={"#{@hold_alert.expired_count} expired uncleaned hold(s) — oldest #{@hold_alert.oldest_minutes}m past expiry."} />
      <% end %>

      <%# Live risk decline feed %>
      <%= if @risk_alerts != [] do %>
        <div class="alert alert-info" style="margin-bottom:1rem">
          <strong>Live Risk Alerts</strong>
          <ul style="margin:0.5rem 0 0 1rem">
            <%= for alert <- @risk_alerts do %>
              <li>
                Score <%= Float.round(alert[:score] || 0.0, 2) %> —
                <%= inspect(alert[:fired_rules] || []) %>
              </li>
            <% end %>
          </ul>
        </div>
      <% end %>

      <%# Action notice %>
      <%= if @notice do %>
        <.alert kind={:success} message={@notice} />
      <% end %>

      <%# Status filter tabs %>
      <div class="filter-tabs" style="margin-bottom:1rem">
        <%= for status <- ["pending", "escalated", "resolved"] do %>
          <button
            class={"btn-sm#{if @filter_status == status, do: " active", else: ""}"}
            phx-click="filter"
            phx-value-status={status}
            phx-target={@myself}
          >
            <%= String.capitalize(status) %>
          </button>
        <% end %>
      </div>

      <%# Exceptions table %>
      <div class="table-wrapper">
        <table class="data-table">
          <thead>
            <tr>
              <th>Pan (last 4)</th>
              <th>MTI</th>
              <th>STAN</th>
              <th>RRN</th>
              <th>Terminal</th>
              <th>Status</th>
              <th>Received</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= if @exceptions == [] do %>
              <tr><td colspan="8" style="text-align:center;color:#888">No exceptions found.</td></tr>
            <% end %>
            <%= for exc <- @exceptions do %>
              <tr>
                <td><%= pan_last4(exc.pan_token) %></td>
                <td><%= exc.mti %></td>
                <td><%= exc.stan || "—" %></td>
                <td><%= exc.rrn  || "—" %></td>
                <td><%= exc.terminal_id || "—" %></td>
                <td><span class={"badge badge-#{badge_class(exc.status)}"}><%= exc.status %></span></td>
                <td><%= format_dt(exc.inserted_at) %></td>
                <td>
                  <%= if exc.status == "pending" and @can_approve do %>
                    <button class="btn-sm btn-success"
                            phx-click="resolve"
                            phx-value-id={exc.id}
                            phx-target={@myself}>Resolve</button>
                    <button class="btn-sm btn-warning"
                            phx-click="escalate"
                            phx-value-id={exc.id}
                            phx-target={@myself}>Escalate</button>
                  <% else %>
                    <span class="text-muted">—</span>
                  <% end %>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <%# Pagination %>
      <div class="pagination" style="margin-top:0.75rem">
        <button class="btn-sm" phx-click="prev_page" phx-target={@myself}
                disabled={@page <= 1}>← Prev</button>
        <span style="margin:0 0.5rem">Page <%= @page %> · <%= @total %> total</span>
        <button class="btn-sm" phx-click="next_page" phx-target={@myself}
                disabled={@page * 25 >= @total}>Next →</button>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp load_exceptions(socket) do
    %{filter_status: status, page: page} = socket.assigns
    offset = (page - 1) * @per_page

    total =
      from(e in ExceptionQueue, where: e.status == ^status, select: count(e.id))
      |> Repo.one()

    exceptions =
      from(e in ExceptionQueue,
        where: e.status == ^status,
        order_by: [desc: e.inserted_at],
        limit: @per_page,
        offset: ^offset
      )
      |> Repo.all()

    assign(socket, exceptions: exceptions, total: total || 0)
  end

  defp update_exception(id, new_status, socket) do
    case Repo.get(ExceptionQueue, id) do
      nil ->
        {:noreply, assign(socket, notice: "Exception not found.")}

      exc ->
        exc
        |> ExceptionQueue.changeset(%{status: new_status})
        |> Repo.update()

        {:noreply,
         socket
         |> assign(notice: "Exception marked #{new_status}.")
         |> load_exceptions()}
    end
  end

  defp pan_last4(nil), do: "****"
  defp pan_last4(token) when byte_size(token) >= 4, do: "****" <> String.slice(token, -4, 4)
  defp pan_last4(_), do: "****"

  defp badge_class("pending"),   do: "warning"
  defp badge_class("escalated"), do: "error"
  defp badge_class("resolved"),  do: "success"
  defp badge_class(_),           do: "info"

  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end
  defp format_dt(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end
end
