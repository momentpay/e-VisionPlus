defmodule VmuCoreWeb.Live.Admin.TramInquiryComponent do
  @moduledoc """
  Admin LiveComponent: TRAM transaction inquiry (TRAM-P6 6C, spec 04).

  Search over the TRAM transaction repository (RRN / STAN / auth code /
  merchant / state / date range) with a detail drawer showing the full
  aggregate: authorization, identifiers, clearing linkage, adjustments,
  statement lines, dispute case, and the complete event timeline.

  Read-only — maintenance and adjustment actions go through their command
  modules (ops tooling for those is driven by the approval queues:
  `AdjustmentCommand.pending/1`, `MaintenanceCommand.pending/1`).
  """

  use Phoenix.LiveComponent
  import VmuCoreWeb.AdminUI

  alias VmuCore.TRAMS.{TransactionSearch, TransactionView, StateMachine}

  @per_page 25

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       filters: %{rrn: "", stan: "", auth_code: "", merchant: "", state: "",
                  date_from: "", date_to: ""},
       results: [],
       total: 0,
       page: 1,
       detail: nil
     )
     |> run_search()}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("search", %{"filters" => params}, socket) do
    filters = %{
      rrn:       String.trim(params["rrn"] || ""),
      stan:      String.trim(params["stan"] || ""),
      auth_code: String.trim(params["auth_code"] || ""),
      merchant:  String.trim(params["merchant"] || ""),
      state:     params["state"] || "",
      date_from: params["date_from"] || "",
      date_to:   params["date_to"] || ""
    }

    {:noreply, socket |> assign(filters: filters, page: 1, detail: nil) |> run_search()}
  end

  def handle_event("clear", _, socket) do
    {:noreply,
     socket
     |> assign(filters: %{rrn: "", stan: "", auth_code: "", merchant: "", state: "",
                          date_from: "", date_to: ""},
               page: 1, detail: nil)
     |> run_search()}
  end

  def handle_event("show_detail", %{"id" => transaction_id}, socket) do
    case TransactionView.detail(transaction_id) do
      {:ok, detail} -> {:noreply, assign(socket, detail: detail)}
      {:error, _}   -> {:noreply, socket}
    end
  end

  def handle_event("close_detail", _, socket) do
    {:noreply, assign(socket, detail: nil)}
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
      <.page_header title="TRAM Transaction Inquiry"
                    subtitle="Lifecycle search across the transaction repository" />

      <%# Search form %>
      <form phx-submit="search" phx-target={@myself} class="search-form" style="margin-bottom:1.25rem">
        <div class="form-row">
          <div class="form-group">
            <label>RRN</label>
            <input type="text" name="filters[rrn]" value={@filters.rrn} maxlength="12" />
          </div>
          <div class="form-group">
            <label>STAN</label>
            <input type="text" name="filters[stan]" value={@filters.stan} maxlength="12" />
          </div>
          <div class="form-group">
            <label>Auth Code</label>
            <input type="text" name="filters[auth_code]" value={@filters.auth_code} maxlength="6" />
          </div>
          <div class="form-group">
            <label>Merchant</label>
            <input type="text" name="filters[merchant]" value={@filters.merchant} placeholder="name or ID" />
          </div>
        </div>
        <div class="form-row">
          <div class="form-group">
            <label>State</label>
            <select name="filters[state]">
              <option value="">Any</option>
              <%= for s <- StateMachine.states() do %>
                <option value={s} selected={@filters.state == s}><%= s %></option>
              <% end %>
            </select>
          </div>
          <div class="form-group">
            <label>Date From</label>
            <input type="date" name="filters[date_from]" value={@filters.date_from} />
          </div>
          <div class="form-group">
            <label>Date To</label>
            <input type="date" name="filters[date_to]" value={@filters.date_to} />
          </div>
          <div class="form-group" style="align-self:flex-end">
            <button type="submit" class="btn-primary">Search</button>
            <button type="button" class="btn-sm" phx-click="clear" phx-target={@myself}>Clear</button>
          </div>
        </div>
      </form>

      <%# Detail drawer %>
      <%= if @detail do %>
        <div class="detail-panel" style="border:1px solid #ccd; border-radius:6px; padding:1rem; margin-bottom:1.25rem; background:#fafbfc">
          <div style="display:flex; justify-content:space-between; align-items:center">
            <h3 style="margin:0">
              Transaction <code style="font-size:0.8em"><%= @detail.transaction.transaction_id %></code>
            </h3>
            <button class="btn-sm" phx-click="close_detail" phx-target={@myself}>✕ Close</button>
          </div>

          <div class="form-row" style="margin-top:0.75rem">
            <div><strong>State:</strong> <%= @detail.transaction.state %>
                 <span class="text-muted">(cardholder sees: "<%= @detail.cardholder_status %>")</span></div>
            <div><strong>Type:</strong> <%= @detail.transaction.transaction_type %></div>
            <div><strong>Amount:</strong> <%= @detail.transaction.amount %>
                 <%= if @detail.transaction.settled_amount do %>
                   → settled <%= @detail.transaction.settled_amount %>
                 <% end %>
                 <%= @detail.transaction.currency %></div>
            <div><strong>Merchant:</strong> <%= @detail.transaction.merchant_name || @detail.transaction.merchant_id || "—" %></div>
          </div>

          <%# Identifiers %>
          <h4 style="margin:1rem 0 0.25rem">Identifiers</h4>
          <table class="data-table">
            <thead><tr><th>Source</th><th>STAN</th><th>RRN</th><th>Auth Code</th></tr></thead>
            <tbody>
              <%= for i <- @detail.identifiers do %>
                <tr>
                  <td><%= i.source %></td>
                  <td><code><%= i.stan || "—" %></code></td>
                  <td><code><%= i.rrn || "—" %></code></td>
                  <td><code><%= i.auth_code || "—" %></code></td>
                </tr>
              <% end %>
            </tbody>
          </table>

          <%# Event timeline %>
          <h4 style="margin:1rem 0 0.25rem">Event Timeline</h4>
          <table class="data-table">
            <thead><tr><th>#</th><th>Event</th><th>Actor</th><th>When</th></tr></thead>
            <tbody>
              <%= for e <- @detail.events do %>
                <tr>
                  <td><%= e.seq %></td>
                  <td><code><%= e.event_type %></code></td>
                  <td><%= e.actor %></td>
                  <td><%= Calendar.strftime(e.occurred_at, "%Y-%m-%d %H:%M:%S") %></td>
                </tr>
              <% end %>
            </tbody>
          </table>

          <%# Related records %>
          <div class="form-row" style="margin-top:0.75rem">
            <div><strong>Clearing:</strong>
              <%= if @detail.clearing do %>
                <%= @detail.clearing.network %> <%= @detail.clearing.amount %>
                (<%= @detail.clearing.match_status %>)
              <% else %>—<% end %>
            </div>
            <div><strong>Adjustments:</strong> <%= length(@detail.adjustments) %></div>
            <div><strong>Statement lines:</strong> <%= length(@detail.statement_lines) %></div>
            <div><strong>Dispute:</strong>
              <%= if @detail.dispute do %>
                <%= @detail.dispute.reason_code %> — <%= @detail.dispute.status %>
              <% else %>—<% end %>
            </div>
          </div>
        </div>
      <% end %>

      <%# Results %>
      <p class="text-muted" style="margin-bottom:0.5rem"><%= @total %> transaction(s)</p>
      <div class="table-wrapper" style="overflow-x:auto">
        <table class="data-table" style="min-width:820px">
          <thead>
            <tr>
              <th>Created</th><th>Type</th><th>State</th><th>Amount</th>
              <th>Merchant</th><th>Flags</th><th></th>
            </tr>
          </thead>
          <tbody>
            <%= if @results == [] do %>
              <tr><td colspan="7" style="text-align:center;color:#888">No transactions.</td></tr>
            <% end %>
            <%= for t <- @results do %>
              <tr>
                <td style="white-space:nowrap"><%= Calendar.strftime(t.inserted_at, "%Y-%m-%d %H:%M") %></td>
                <td><%= t.transaction_type %></td>
                <td><span class={"badge badge-#{state_class(t.state)}"}><%= t.state %></span></td>
                <td style="text-align:right"><%= t.settled_amount || t.amount %> <%= t.currency %></td>
                <td><%= t.merchant_name || t.merchant_id || "—" %></td>
                <td>
                  <%= if t.statement_date, do: "📄" %>
                  <%= if t.clearing_id, do: "🔗" %>
                </td>
                <td>
                  <button class="btn-sm" phx-click="show_detail"
                          phx-value-id={t.transaction_id} phx-target={@myself}>Detail</button>
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
                disabled={@page * 25 >= @total}>Next →</button>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp run_search(socket) do
    %{filters: f, page: page} = socket.assigns

    search_filters = %{
      rrn:       f.rrn,
      stan:      f.stan,
      auth_code: f.auth_code,
      merchant:  f.merchant,
      state:     f.state,
      date_from: parse_date(f.date_from),
      date_to:   parse_date(f.date_to)
    }

    %{results: results, total: total} =
      TransactionSearch.search(search_filters, page: page, per_page: @per_page)

    assign(socket, results: results, total: total)
  end

  defp parse_date(""), do: nil
  defp parse_date(nil), do: nil
  defp parse_date(str) do
    case Date.from_iso8601(str) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp state_class(s) when s in ~w[POSTED STATEMENTED PAID CLOSED], do: "success"
  defp state_class(s) when s in ~w[DECLINED REVERSED],              do: "error"
  defp state_class(s) when s in ~w[DISPUTED CHARGEBACKED],          do: "warning"
  defp state_class(_),                                              do: "info"
end
