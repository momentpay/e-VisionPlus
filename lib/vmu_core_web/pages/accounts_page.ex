defmodule VmuCoreWeb.Pages.AccountsPage do
  @moduledoc """
  LiveDashboard custom page — CMS Accounts Overview.

  Live view of the card portfolio:
    - Counts by account status and delinquency bucket
    - Open-to-buy headroom summary
    - Recent GL entries (last 15 postings)
    - Authorization test: enter a PAN + amount to run a live auth call
  """

  use Phoenix.LiveDashboard.PageBuilder
  import Ecto.Query

  alias VmuCore.{Repo, CMS.Account, CMS.BalanceBucket, FAS.Authorization}

  @impl true
  def menu_link(_, _), do: {:ok, "Accounts"}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> load_portfolio()
      |> assign(
        auth_pan:     "",
        auth_amount:  "100.00",
        auth_mcc:     "5411",
        auth_channel: "pos",
        auth_result:  nil
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("auth_test", %{"pan" => pan, "amount" => amt, "mcc" => mcc, "channel" => ch}, socket) do
    result =
      try do
        Authorization.process(%{
          pan:     pan,
          amount:  Decimal.new(amt),
          channel: String.to_existing_atom(ch),
          mcc:     mcc
        })
      rescue
        e -> {:error, "#{inspect(e)}"}
      end

    label =
      case result do
        {:ok, rc, code} -> "✅ APPROVED  RC=#{rc}  Approval=#{code}"
        {:error, rc}    -> "❌ DECLINED  RC=#{rc} #{rc_description(rc)}"
      end

    {:noreply, assign(socket, auth_result: label, auth_pan: pan, auth_amount: amt, auth_mcc: mcc, auth_channel: ch)}
  end

  def handle_event("refresh", _, socket) do
    {:noreply, load_portfolio(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="font-family: monospace; padding: 1rem;">

      <div style="display: flex; align-items: center; gap: 1rem; margin-bottom: 1.5rem;">
        <h2 style="margin: 0;">CMS Accounts — Portfolio Overview</h2>
        <button phx-click="refresh"           style="padding: 0.4rem 1rem; background: #3b82f6; color: white;
                 border: none; border-radius: 4px; cursor: pointer;">
          ↺ Refresh
        </button>
      </div>

      <%!-- Status summary cards --%>
      <div style="display: flex; gap: 1rem; margin-bottom: 2rem; flex-wrap: wrap;">
        <%= for {status, count} <- @by_status do %>
          <div style={"background:#{status_color(status)}; color:white;
                      padding: 1rem 1.5rem; border-radius: 8px; min-width: 120px;"}>
            <div style="font-size: 1.8rem; font-weight: bold;">{count}</div>
            <div style="font-size: 0.8rem; margin-top: 0.3rem;">{status}</div>
          </div>
        <% end %>
      </div>

      <%!-- Delinquency buckets --%>
      <h3 style="border-bottom: 1px solid #e5e7eb; padding-bottom: 0.4rem;">
        Delinquency Buckets (DPD)
      </h3>
      <table style={@table_style}>
        <thead><tr style={@head_style}>
          <th style={@th}>DPD Bucket</th>
          <th style={@th}>Accounts</th>
          <th style={@th}>Total Outstanding</th>
        </tr></thead>
        <tbody>
          <%= for row <- @by_delinquency do %>
            <tr style={@row_style}>
              <td style={@td}>{bucket_label(row.bucket)}</td>
              <td style={@td}>{row.count}</td>
              <td style={@td}>{row.outstanding} AED</td>
            </tr>
          <% end %>
        </tbody>
      </table>

      <%!-- Recent GL entries --%>
      <h3 style="border-bottom: 1px solid #e5e7eb; padding-bottom: 0.4rem; margin-top: 2rem;">
        Recent GL Entries (last 15)
      </h3>
      <table style={@table_style}>
        <thead><tr style={@head_style}>
          <th style={@th}>Date</th>
          <th style={@th}>Code</th>
          <th style={@th}>DR</th>
          <th style={@th}>CR</th>
          <th style={@th}>Narrative</th>
        </tr></thead>
        <tbody>
          <%= for e <- @recent_gl do %>
            <tr style={@row_style}>
              <td style={@td}>{e.posting_date}</td>
              <td style={@td}><code>{e.transaction_code}</code></td>
              <td style={@td}>{e.dr_amount}</td>
              <td style={@td}>{e.cr_amount}</td>
              <td style={@td}>{e.narrative}</td>
            </tr>
          <% end %>
        </tbody>
      </table>

      <%!-- Live authorization test panel --%>
      <h3 style="border-bottom: 1px solid #e5e7eb; padding-bottom: 0.4rem; margin-top: 2rem;">
        Live Authorization Test
      </h3>
      <p style="color: #6b7280; font-size: 0.85rem; margin-top: 0;">
        Runs a real auth through ParameterEngine → AccountStateCoordinator → STIP. No money moves.
      </p>
      <form phx-submit="auth_test"         style="display: flex; gap: 0.75rem; align-items: flex-end; flex-wrap: wrap;">
        <label style="display:flex; flex-direction:column; gap:0.3rem; font-size:0.85rem;">
          PAN (raw)
          <input name="pan" value={@auth_pan} placeholder="4072001234560001"
            style="padding: 0.4rem 0.6rem; border: 1px solid #d1d5db;
                   border-radius: 4px; font-family: monospace; width: 200px;" />
        </label>
        <label style="display:flex; flex-direction:column; gap:0.3rem; font-size:0.85rem;">
          Amount (AED)
          <input name="amount" value={@auth_amount}
            style="padding: 0.4rem 0.6rem; border: 1px solid #d1d5db;
                   border-radius: 4px; width: 100px;" />
        </label>
        <label style="display:flex; flex-direction:column; gap:0.3rem; font-size:0.85rem;">
          MCC
          <input name="mcc" value={@auth_mcc}
            style="padding: 0.4rem 0.6rem; border: 1px solid #d1d5db;
                   border-radius: 4px; width: 70px;" />
        </label>
        <label style="display:flex; flex-direction:column; gap:0.3rem; font-size:0.85rem;">
          Channel
          <select name="channel"
            style="padding: 0.4rem 0.6rem; border: 1px solid #d1d5db; border-radius: 4px;">
            <option value="pos"         selected={@auth_channel == "pos"}>POS</option>
            <option value="atm"         selected={@auth_channel == "atm"}>ATM</option>
            <option value="ecom"        selected={@auth_channel == "ecom"}>ECOM</option>
            <option value="contactless" selected={@auth_channel == "contactless"}>Contactless</option>
          </select>
        </label>
        <button type="submit"
          style="padding: 0.5rem 1.2rem; background: #059669; color: white;
                 border: none; border-radius: 4px; cursor: pointer; font-weight: bold;">
          Run Auth →
        </button>
      </form>

      <%= if @auth_result do %>
        <div style={"margin-top: 1rem; padding: 0.75rem 1rem; border-radius: 6px;
                    background: #{if String.starts_with?(@auth_result, "✅"), do: "#d1fae5", else: "#fee2e2"};
                    font-size: 1rem; font-family: monospace;"}>
          {@auth_result}
        </div>
      <% end %>

    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp load_portfolio(socket) do
    assign(socket,
      by_status:      portfolio_by_status(),
      by_delinquency: portfolio_by_delinquency(),
      recent_gl:      recent_gl_entries(),
      table_style:    "width:100%; border-collapse:collapse; font-size:0.9rem;",
      head_style:     "background:#f3f4f6;",
      row_style:      "border-top: 1px solid #e5e7eb;",
      th:             "padding:0.5rem 0.75rem; text-align:left; font-weight:600;",
      td:             "padding:0.5rem 0.75rem;"
    )
  end

  defp portfolio_by_status do
    Repo.all(
      from a in Account,
      group_by: a.account_status,
      select: {a.account_status, count(a.account_id)},
      order_by: [asc: a.account_status]
    )
  end

  defp portfolio_by_delinquency do
    Repo.all(
      from a in Account,
      join: b in BalanceBucket, on: b.account_id == a.account_id,
      group_by: a.delinquency_bucket,
      select: %{
        bucket:      a.delinquency_bucket,
        count:       count(a.account_id),
        outstanding: sum(b.statement_balance)
      },
      order_by: [asc: a.delinquency_bucket]
    )
  end

  defp recent_gl_entries do
    Repo.all(
      from e in "cms_ledger_entries",
      order_by: [desc: e.posting_date, desc: e.inserted_at],
      limit: 15,
      select: %{
        posting_date:     e.posting_date,
        transaction_code: e.transaction_code,
        dr_amount:        e.dr_amount,
        cr_amount:        e.cr_amount,
        narrative:        e.narrative
      }
    )
  end

  defp status_color("ACTIVE"),     do: "#059669"
  defp status_color("DELINQUENT"), do: "#d97706"
  defp status_color("BLOCKED"),    do: "#dc2626"
  defp status_color("CLOSED"),     do: "#6b7280"
  defp status_color(_),            do: "#3b82f6"

  defp bucket_label(0),   do: "Current (0 DPD)"
  defp bucket_label(30),  do: "30 DPD"
  defp bucket_label(60),  do: "60 DPD"
  defp bucket_label(90),  do: "90 DPD"
  defp bucket_label(120), do: "120+ DPD"
  defp bucket_label(n),   do: "#{n} DPD"

  defp rc_description("14"), do: "(invalid card number)"
  defp rc_description("15"), do: "(BIN not found)"
  defp rc_description("51"), do: "(insufficient funds)"
  defp rc_description("54"), do: "(expired card)"
  defp rc_description("62"), do: "(restricted / blocked)"
  defp rc_description("96"), do: "(system malfunction)"
  defp rc_description(_),    do: ""
end
