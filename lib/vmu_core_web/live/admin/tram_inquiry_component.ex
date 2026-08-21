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
  import VmuCoreWeb.Components.AgGrid
  import VmuCoreWeb.Components.Drawer

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
    <div id={@id} class="component-panel">
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

      <%!-- Detail opens in the shared right-side drawer rather than above the
           results table, so the operator keeps their place in the search they
           just ran. See docs/shared/Admin_Detail_UX_Philosophy.md §2. --%>
      <.detail_drawer
        id="tram-detail-drawer"
        open={@detail != nil}
        title={@detail && "Transaction #{short_id(@detail.transaction.transaction_id)}…"}
        subtitle={@detail && @detail.transaction.transaction_id}
        on_close="close_detail"
        target={@myself}
      >
        <div :if={@detail}>
          <.kv_detail rows={[
            {"State", "#{@detail.transaction.state} (cardholder sees: \"#{@detail.cardholder_status}\")"},
            {"Type", @detail.transaction.transaction_type},
            {"Amount", amount_line(@detail.transaction)},
            {"Merchant", @detail.transaction.merchant_name || @detail.transaction.merchant_id || "—"}
          ]} />

          <%!-- Identifiers and the event timeline are one transaction's own
               fixed-shape sub-records — a handful of rows, bounded by this
               record rather than by platform activity — so they are plain
               tables, not <.ag_grid>. Philosophy doc §1. --%>
          <div class="form-pane-section-title" style="margin-top:16px;">Identifiers</div>
          <div class="table-wrap">
            <table class="data-table">
              <thead><tr><th>Source</th><th>STAN</th><th>RRN</th><th>Auth Code</th></tr></thead>
              <tbody>
                <tr :for={i <- @detail.identifiers}>
                  <td><%= i.source %></td>
                  <td class="mono"><%= i.stan || "—" %></td>
                  <td class="mono"><%= i.rrn || "—" %></td>
                  <td class="mono"><%= i.auth_code || "—" %></td>
                </tr>
                <tr :if={@detail.identifiers == []}>
                  <td colspan="4" class="cell-note">No identifiers.</td>
                </tr>
              </tbody>
            </table>
          </div>

          <div class="form-pane-section-title" style="margin-top:16px;">Event Timeline</div>
          <div class="table-wrap">
            <table class="data-table">
              <thead><tr><th>#</th><th>Event</th><th>Actor</th><th>When</th></tr></thead>
              <tbody>
                <tr :for={e <- @detail.events}>
                  <td class="mono"><%= e.seq %></td>
                  <td class="mono"><%= e.event_type %></td>
                  <td><%= e.actor %></td>
                  <td><%= Calendar.strftime(e.occurred_at, "%Y-%m-%d %H:%M:%S") %></td>
                </tr>
                <tr :if={@detail.events == []}>
                  <td colspan="4" class="cell-note">No events.</td>
                </tr>
              </tbody>
            </table>
          </div>

          <div class="form-pane-section-title" style="margin-top:16px;">Related Records</div>
          <.kv_detail rows={[
            {"Clearing", clearing_line(@detail.clearing)},
            {"Adjustments", length(@detail.adjustments)},
            {"Statement lines", length(@detail.statement_lines)},
            {"Dispute", dispute_line(@detail.dispute)}
          ]} />
        </div>
      </.detail_drawer>

      <%# Results %>
      <p class="text-muted" style="margin-bottom:0.5rem"><%= @total %> transaction(s)</p>
      <.ag_grid
        id="tram-inquiry-results-grid"
        paginate={false}
        empty_message="No transactions."
        columns={[
          %{field: "created", header: "Created", width: 130},
          %{field: "type", header: "Type", width: 130},
          %{field: "state", header: "State", type: "badge", classField: "state_class", width: 120},
          %{field: "amount", header: "Amount", flex: 1},
          %{field: "merchant", header: "Merchant", flex: 1},
          %{field: "flags", header: "Flags", width: 90},
          %{field: "actions", header: "", type: "actions",
            actions: [%{label: "Detail", event: "show_detail", param: "transaction_id"}], width: 100}
        ]}
        rows={Enum.map(@results, &tram_result_row/1)}
      />

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

  defp short_id(id), do: id |> to_string() |> String.slice(0, 8)

  defp amount_line(%{amount: amount, settled_amount: nil, currency: ccy}), do: "#{amount} #{ccy}"

  defp amount_line(%{amount: amount, settled_amount: settled, currency: ccy}),
    do: "#{amount} → settled #{settled} #{ccy}"

  defp clearing_line(nil), do: "—"

  defp clearing_line(c), do: "#{c.network} #{c.amount} (#{c.match_status})"

  defp dispute_line(nil), do: "—"

  defp dispute_line(d), do: "#{d.reason_code} — #{d.status}"

  defp tram_result_row(t) do
    flags = [if(t.statement_date, do: "📄"), if(t.clearing_id, do: "🔗")] |> Enum.reject(&is_nil/1) |> Enum.join(" ")

    %{
      created: Calendar.strftime(t.inserted_at, "%Y-%m-%d %H:%M"),
      type: t.transaction_type,
      state: t.state,
      state_class: "badge-#{state_class(t.state)}",
      amount: "#{t.settled_amount || t.amount} #{t.currency}",
      merchant: t.merchant_name || t.merchant_id || "—",
      flags: if(flags == "", do: "—", else: flags),
      transaction_id: t.transaction_id
    }
  end

  defp state_class(s) when s in ~w[POSTED STATEMENTED PAID CLOSED], do: "success"
  defp state_class(s) when s in ~w[DECLINED REVERSED],              do: "error"
  defp state_class(s) when s in ~w[DISPUTED CHARGEBACKED],          do: "warning"
  defp state_class(_),                                              do: "info"
end
