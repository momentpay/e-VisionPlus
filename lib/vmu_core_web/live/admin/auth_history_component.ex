defmodule VmuCoreWeb.Live.Admin.AuthHistoryComponent do
  @moduledoc """
  Admin LiveComponent: FAS authorization history search (FAS-P8 8F).

  Provides a search form for `fas_authorizations` so operators can look up
  any card transaction by PAN last-4, approval code, STAN, or date range.
  Shows decision path, risk score, and current hold status alongside the
  standard auth metadata.

  Search fields:
    - PAN last-4 (applies a LIKE filter on `pan_token` — tokens are
      deterministic hashes ending in the card's last-4 digits by convention)
    - Approval code (DE38 — 6-char alphanumeric)
    - STAN (DE11 — system trace audit number)
    - Date from / Date to (filters on `inserted_at`)

  Leave all fields blank to show the 50 most recent authorizations.
  """

  use Phoenix.LiveComponent
  import Ecto.Query
  import VmuCoreWeb.AdminUI

  alias VmuCore.{Repo, FAS.AuthorizationRecord, FAS.PendingHold}

  @per_page 50

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       search: %{pan_last4: "", approval_code: "", stan: "", date_from: "", date_to: ""},
       results: [],
       total: 0,
       page: 1,
       searched: false
     )
     |> run_search()}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("search", %{"search" => params}, socket) do
    search = %{
      pan_last4:     String.trim(params["pan_last4"] || ""),
      approval_code: String.trim(params["approval_code"] || ""),
      stan:          String.trim(params["stan"] || ""),
      date_from:     String.trim(params["date_from"] || ""),
      date_to:       String.trim(params["date_to"] || "")
    }

    {:noreply,
     socket
     |> assign(search: search, page: 1, searched: true)
     |> run_search()}
  end

  def handle_event("clear", _, socket) do
    {:noreply,
     socket
     |> assign(search: %{pan_last4: "", approval_code: "", stan: "", date_from: "", date_to: ""},
               page: 1, searched: false)
     |> run_search()}
  end

  def handle_event("next_page", _, socket) do
    {:noreply,
     socket
     |> assign(page: socket.assigns.page + 1)
     |> run_search()}
  end

  def handle_event("prev_page", _, socket) do
    {:noreply,
     socket
     |> assign(page: max(1, socket.assigns.page - 1))
     |> run_search()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="component-panel">
      <.page_header title="Authorization History"
                    subtitle="Search fas_authorizations by card, approval code, STAN, or date" />

      <%# Search form %>
      <form phx-submit="search" phx-target={@myself} class="search-form" style="margin-bottom:1.25rem">
        <div class="form-row">
          <div class="form-group">
            <label>PAN Last 4</label>
            <input type="text" name="search[pan_last4]" value={@search.pan_last4}
                   placeholder="e.g. 1234" maxlength="4" />
          </div>
          <div class="form-group">
            <label>Approval Code</label>
            <input type="text" name="search[approval_code]" value={@search.approval_code}
                   placeholder="6-char DE38" maxlength="6" />
          </div>
          <div class="form-group">
            <label>STAN</label>
            <input type="text" name="search[stan]" value={@search.stan}
                   placeholder="DE11 trace number" maxlength="12" />
          </div>
        </div>
        <div class="form-row">
          <div class="form-group">
            <label>Date From</label>
            <input type="date" name="search[date_from]" value={@search.date_from} />
          </div>
          <div class="form-group">
            <label>Date To</label>
            <input type="date" name="search[date_to]" value={@search.date_to} />
          </div>
          <div class="form-group" style="align-self:flex-end">
            <button type="submit" class="btn-primary">Search</button>
            <button type="button" class="btn-sm" phx-click="clear" phx-target={@myself}>Clear</button>
          </div>
        </div>
      </form>

      <%# Results summary %>
      <p class="text-muted" style="margin-bottom:0.5rem">
        <%= if @searched do %>
          <%= @total %> result(s) found
        <% else %>
          Showing <%= @total %> most recent authorizations
        <% end %>
      </p>

      <%# Results table %>
      <div class="table-wrapper" style="overflow-x:auto">
        <table class="data-table" style="min-width:900px">
          <thead>
            <tr>
              <th>Date/Time</th>
              <th>MTI</th>
              <th>RC</th>
              <th>Amount</th>
              <th>Currency</th>
              <th>Approval Code</th>
              <th>STAN</th>
              <th>Terminal</th>
              <th>Risk Score</th>
              <th>Hold</th>
              <th>Path</th>
            </tr>
          </thead>
          <tbody>
            <%= if @results == [] do %>
              <tr><td colspan="11" style="text-align:center;color:#888">No results.</td></tr>
            <% end %>
            <%= for row <- @results do %>
              <tr>
                <td style="white-space:nowrap"><%= format_dt(row.auth.inserted_at) %></td>
                <td><%= row.auth.mti %></td>
                <td>
                  <span class={"badge badge-#{rc_class(row.auth.rc)}"}>
                    <%= row.auth.rc %>
                  </span>
                </td>
                <td style="text-align:right"><%= Decimal.to_string(row.auth.amount) %></td>
                <td><%= row.auth.currency %></td>
                <td><code><%= row.auth.approval_code || "—" %></code></td>
                <td><code><%= row.auth.stan || "—" %></code></td>
                <td><%= row.auth.terminal_id || "—" %></td>
                <td style="text-align:right"><%= risk_score_str(row.auth.risk_score) %></td>
                <td><%= hold_status(row.hold) %></td>
                <td class="text-muted" style="font-size:0.8em">
                  <%= Map.get(row.auth.decision_path, "path", "—") %>
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
                disabled={@page * 50 >= @total}>Next →</button>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp run_search(socket) do
    %{search: s, page: page} = socket.assigns
    offset = (page - 1) * @per_page

    base_query =
      from(a in AuthorizationRecord, order_by: [desc: a.inserted_at])
      |> maybe_filter_pan(s.pan_last4)
      |> maybe_filter_approval_code(s.approval_code)
      |> maybe_filter_stan(s.stan)
      |> maybe_filter_date_from(s.date_from)
      |> maybe_filter_date_to(s.date_to)

    total   = Repo.aggregate(base_query, :count, :id)
    auth_records = Repo.all(from q in base_query, limit: @per_page, offset: ^offset)

    # Attach hold status (one query to load all relevant holds)
    auth_ids = Enum.map(auth_records, & &1.id)

    holds_by_auth =
      from(h in PendingHold,
        where: h.fas_authorization_id in ^auth_ids,
        order_by: [desc: h.inserted_at]
      )
      |> Repo.all()
      |> Enum.group_by(& &1.fas_authorization_id)

    results =
      Enum.map(auth_records, fn auth ->
        hold = holds_by_auth |> Map.get(auth.id, []) |> List.first()
        %{auth: auth, hold: hold}
      end)

    assign(socket, results: results, total: total || 0)
  end

  defp maybe_filter_pan(query, ""), do: query
  defp maybe_filter_pan(query, last4) do
    where(query, [a], like(a.pan_token, ^"%#{last4}"))
  end

  defp maybe_filter_approval_code(query, ""), do: query
  defp maybe_filter_approval_code(query, code) do
    where(query, [a], a.approval_code == ^code)
  end

  defp maybe_filter_stan(query, ""), do: query
  defp maybe_filter_stan(query, stan) do
    where(query, [a], a.stan == ^stan)
  end

  defp maybe_filter_date_from(query, ""), do: query
  defp maybe_filter_date_from(query, date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        dt = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
        where(query, [a], a.inserted_at >= ^dt)

      _ ->
        query
    end
  end

  defp maybe_filter_date_to(query, ""), do: query
  defp maybe_filter_date_to(query, date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        dt = DateTime.new!(date, ~T[23:59:59], "Etc/UTC")
        where(query, [a], a.inserted_at <= ^dt)

      _ ->
        query
    end
  end

  defp rc_class("00"), do: "success"
  defp rc_class(rc) when rc in ["05", "51", "54", "55", "57", "62", "75", "82"],
    do: "error"
  defp rc_class(_), do: "warning"

  defp risk_score_str(nil), do: "—"
  defp risk_score_str(score), do: Float.round(score, 3) |> Float.to_string()

  defp hold_status(nil), do: "—"
  defp hold_status(%PendingHold{reversal_at: r}) when not is_nil(r), do: "reversed"
  defp hold_status(%PendingHold{cleared_at: c}) when not is_nil(c),  do: "cleared"
  defp hold_status(%PendingHold{expires_at: exp}) do
    if DateTime.compare(exp, DateTime.utc_now()) == :lt, do: "expired", else: "active"
  end

  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt),     do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_dt(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
end
