defmodule VmuCoreWeb.Live.Admin.AuditLogComponent do
  @moduledoc """
  Operator audit trail search (ASM-P4.3, FR-ASM-016).

  Read-only compliance view over `cms_operator_audit`: filter by operator,
  action (prefix), subject, and date range. Visible to COMPLIANCE /
  SUPERVISOR / ADMIN via the `audit_log` matrix module.
  """

  use Phoenix.LiveComponent
  import VmuCoreWeb.AdminUI

  alias VmuCore.ASM.AuditLog

  @per_page 50

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       filters: %{operator_id: "", action: "", subject: "", date_from: "", date_to: ""},
       entries: [],
       total: 0,
       page: 1,
       actions: []
     )}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(actions: AuditLog.distinct_actions())
     |> run_search()}
  end

  @impl true
  def handle_event("search", %{"filters" => params}, socket) do
    filters = %{
      operator_id: String.trim(params["operator_id"] || ""),
      action:      params["action"] || "",
      subject:     String.trim(params["subject"] || ""),
      date_from:   params["date_from"] || "",
      date_to:     params["date_to"] || ""
    }

    {:noreply, socket |> assign(filters: filters, page: 1) |> run_search()}
  end

  def handle_event("clear", _, socket) do
    {:noreply,
     socket
     |> assign(filters: %{operator_id: "", action: "", subject: "", date_from: "", date_to: ""}, page: 1)
     |> run_search()}
  end

  def handle_event("next_page", _, socket) do
    {:noreply, socket |> assign(page: socket.assigns.page + 1) |> run_search()}
  end

  def handle_event("prev_page", _, socket) do
    {:noreply, socket |> assign(page: max(1, socket.assigns.page - 1)) |> run_search()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="component-panel">
      <.page_header title="Audit Trail"
                    subtitle="Operator actions and PII access — append-only, compliance view" />

      <form phx-submit="search" phx-target={@myself} class="search-form" style="margin-bottom:1.25rem">
        <div class="form-row">
          <div class="form-group">
            <label>Operator</label>
            <input type="text" name="filters[operator_id]" value={@filters.operator_id}
                   placeholder="username"/>
          </div>
          <div class="form-group">
            <label>Action</label>
            <select name="filters[action]">
              <option value="">Any</option>
              <%= for a <- @actions do %>
                <option value={a} selected={@filters.action == a}><%= a %></option>
              <% end %>
            </select>
          </div>
          <div class="form-group">
            <label>Subject (ID)</label>
            <input type="text" name="filters[subject]" value={@filters.subject}
                   placeholder="account / customer ID"/>
          </div>
          <div class="form-group">
            <label>From</label>
            <input type="date" name="filters[date_from]" value={@filters.date_from}/>
          </div>
          <div class="form-group">
            <label>To</label>
            <input type="date" name="filters[date_to]" value={@filters.date_to}/>
          </div>
          <div class="form-group" style="align-self:flex-end">
            <button type="submit" class="btn-primary">Search</button>
            <button type="button" class="btn-sm" phx-click="clear" phx-target={@myself}>Clear</button>
          </div>
        </div>
      </form>

      <p class="text-muted" style="margin-bottom:0.5rem"><%= @total %> entr<%= if @total == 1, do: "y", else: "ies" %></p>

      <div class="table-wrapper" style="overflow-x:auto">
        <table class="data-table" style="min-width:820px">
          <thead>
            <tr>
              <th>When</th><th>Operator</th><th>Role</th><th>Action</th>
              <th>Subject</th><th>Details</th>
            </tr>
          </thead>
          <tbody>
            <%= if @entries == [] do %>
              <tr><td colspan="6" style="text-align:center;color:#888">No audit entries.</td></tr>
            <% end %>
            <%= for e <- @entries do %>
              <tr>
                <td style="white-space:nowrap"><%= Calendar.strftime(e.performed_at, "%Y-%m-%d %H:%M:%S") %></td>
                <td><code><%= e.operator_id %></code></td>
                <td><%= e.operator_role %></td>
                <td><span class={"badge badge-#{action_class(e.action)}"}><%= e.action %></span></td>
                <td><code style="font-size:0.75em"><%= String.slice(e.subject || "", 0, 24) %></code></td>
                <td style="font-size:0.8em; max-width:280px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap">
                  <%= e.details %>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <div class="pagination" style="margin-top:0.75rem">
        <button class="btn-sm" phx-click="prev_page" phx-target={@myself}
                disabled={@page <= 1}>← Prev</button>
        <span style="margin:0 0.5rem">Page <%= @page %> · <%= @total %> total</span>
        <button class="btn-sm" phx-click="next_page" phx-target={@myself}
                disabled={@page * 50 >= @total}>Next →</button>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp run_search(socket) do
    %{filters: f, page: page} = socket.assigns

    %{entries: entries, total: total} =
      AuditLog.search(%{
        operator_id: f.operator_id,
        action:      f.action,
        subject:     f.subject,
        date_from:   parse_date(f.date_from),
        date_to:     parse_date(f.date_to)
      }, page: page, per_page: @per_page)

    assign(socket, entries: entries, total: total)
  end

  defp parse_date(""), do: nil
  defp parse_date(nil), do: nil
  defp parse_date(str) do
    case Date.from_iso8601(str) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp action_class("customer_pii_view"),    do: "warning"
  defp action_class("account_detail_view"),  do: "warning"
  defp action_class(a) do
    cond do
      String.contains?(a, "waiver") or String.contains?(a, "adjust") -> "error"
      true -> "info"
    end
  end
end
