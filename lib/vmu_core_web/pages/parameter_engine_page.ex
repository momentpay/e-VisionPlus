defmodule VmuCoreWeb.Pages.ParameterEnginePage do
  @moduledoc """
  LiveDashboard custom page — VisionPlus Parameter Engine.

  Shows the live ETS cache that backs every card authorization:
    - Cache health (entry count, last refresh)
    - BIN prefix → SYS/BANK/LOGO routing table
    - Block parameters (APR, cash advance fee, default credit limit)
    - STIP offline-approval thresholds

  Refresh button reloads all params from PostgreSQL into ETS without
  restarting the application.
  """

  use Phoenix.LiveDashboard.PageBuilder
  import Ecto.Query

  alias VmuCore.Shared.{ParameterEngine, BlockParameter, SysParameter, BankParameter, LogoParameter}
  alias VmuCore.Repo

  @impl true
  def menu_link(_, _), do: {:ok, "Parameters"}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_assigns(socket)}
  end

  @impl true
  def handle_event("refresh", _, socket) do
    ParameterEngine.refresh_all()
    {:noreply, load_assigns(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="font-family: monospace; padding: 1rem;">

      <div style="display: flex; align-items: center; gap: 1rem; margin-bottom: 1.5rem;">
        <h2 style="margin: 0;">Parameter Engine — ETS Cache</h2>
        <button phx-click="refresh"           style="padding: 0.4rem 1rem; background: #3b82f6; color: white;
                 border: none; border-radius: 4px; cursor: pointer;">
          ↺ Reload from DB
        </button>
        <span style="color: #6b7280; font-size: 0.85rem;">
          {@cache_size} entries · refreshed {@refreshed_at}
        </span>
      </div>

      <%!-- BIN routing table --%>
      <h3 style="border-bottom: 1px solid #e5e7eb; padding-bottom: 0.4rem;">
        BIN → Logo Routing
      </h3>
      <table style={@table_style}>
        <thead><tr style={@head_style}>
          <th style={@th}>BIN Prefix</th>
          <th style={@th}>SYS</th>
          <th style={@th}>Bank</th>
          <th style={@th}>Logo</th>
          <th style={@th}>Description</th>
        </tr></thead>
        <tbody>
          <%= for row <- @bin_routes do %>
            <tr style={@row_style}>
              <td style={@td}><code>{row.bin}</code></td>
              <td style={@td}>{row.sys_id}</td>
              <td style={@td}>{row.bank_id}</td>
              <td style={@td}><strong>{row.logo_id}</strong></td>
              <td style={@td}>{row.description}</td>
            </tr>
          <% end %>
        </tbody>
      </table>

      <%!-- Block parameters --%>
      <h3 style="border-bottom: 1px solid #e5e7eb; padding-bottom: 0.4rem; margin-top: 2rem;">
        Block Parameters (APR / Fees / Limits)
      </h3>
      <table style={@table_style}>
        <thead><tr style={@head_style}>
          <th style={@th}>Block</th>
          <th style={@th}>Logo</th>
          <th style={@th}>APR %</th>
          <th style={@th}>Cash Adv %</th>
          <th style={@th}>Default Limit (AED)</th>
        </tr></thead>
        <tbody>
          <%= for b <- @blocks do %>
            <tr style={@row_style}>
              <td style={@td}><strong>{b.block_id}</strong></td>
              <td style={@td}>{b.logo_id}</td>
              <td style={@td}>{b.apr_percentage}%</td>
              <td style={@td}>{b.cash_advance_fee_percent}%</td>
              <td style={@td}>{b.credit_limit_default}</td>
            </tr>
          <% end %>
        </tbody>
      </table>

      <%!-- STIP thresholds --%>
      <h3 style="border-bottom: 1px solid #e5e7eb; padding-bottom: 0.4rem; margin-top: 2rem;">
        STIP Offline-Approval Thresholds
      </h3>
      <table style={@table_style}>
        <thead><tr style={@head_style}>
          <th style={@th}>SYS</th>
          <th style={@th}>Logo</th>
          <th style={@th}>Max Single Txn</th>
          <th style={@th}>Max Cumulative</th>
        </tr></thead>
        <tbody>
          <%= for s <- @stip do %>
            <tr style={@row_style}>
              <td style={@td}>{s.sys_id}</td>
              <td style={@td}>{s.logo_id}</td>
              <td style={@td}>{s.max_amount} AED</td>
              <td style={@td}>{s.max_cumulative} AED</td>
            </tr>
          <% end %>
        </tbody>
      </table>

      <%!-- Raw ETS inspect --%>
      <h3 style="border-bottom: 1px solid #e5e7eb; padding-bottom: 0.4rem; margin-top: 2rem;">
        Raw ETS Cache Sample (first 20 entries)
      </h3>
      <pre style="background: #1f2937; color: #d1fae5; padding: 1rem;
                  border-radius: 6px; overflow-x: auto; font-size: 0.8rem;">{@raw_sample}</pre>

    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp load_assigns(socket) do
    assign(socket,
      cache_size:   safe_cache_size(),
      refreshed_at: DateTime.utc_now() |> Calendar.strftime("%H:%M:%S UTC"),
      bin_routes:   load_bin_routes(),
      blocks:       load_blocks(),
      stip:         load_stip(),
      raw_sample:   load_raw_sample(),
      table_style:  "width:100%; border-collapse:collapse; font-size:0.9rem;",
      head_style:   "background:#f3f4f6;",
      row_style:    "border-top: 1px solid #e5e7eb;",
      th:           "padding:0.5rem 0.75rem; text-align:left; font-weight:600;",
      td:           "padding:0.5rem 0.75rem;"
    )
  end

  defp safe_cache_size do
    try do
      ParameterEngine.cache_size()
    rescue
      _ -> 0
    end
  end

  defp load_bin_routes do
    # Pull BIN→logo mappings from ETS then enrich with logo description from DB
    logos = Repo.all(from l in LogoParameter, select: l)
            |> Map.new(&{&1.logo_id, &1})

    try do
      :ets.tab2list(:vmu_parameter_cache)
      |> Enum.filter(fn {key, _} ->
        match?({:logo, _, _, _, :bin_prefix}, key)
      end)
      |> Enum.map(fn {{:logo, sys, bank, logo, :bin_prefix}, bin} ->
        %{
          bin:         bin,
          sys_id:      sys,
          bank_id:     bank,
          logo_id:     logo,
          description: get_in(logos, [logo, Access.key(:description)]) || "—"
        }
      end)
      |> Enum.sort_by(& &1.bin)
    rescue
      _ -> []
    end
  end

  defp load_blocks do
    Repo.all(from b in BlockParameter,
      order_by: [asc: b.logo_id, asc: b.block_id])
  end

  defp load_stip do
    Repo.all(from s in "stip_thresholds",
      select: %{
        sys_id:         s.sys_id,
        logo_id:        s.logo_id,
        max_amount:     s.max_amount,
        max_cumulative: s.max_cumulative
      },
      order_by: [asc: s.logo_id])
  end

  defp load_raw_sample do
    try do
      :ets.tab2list(:vmu_parameter_cache)
      |> Enum.take(20)
      |> Enum.map_join("\n", &inspect/1)
    rescue
      _ -> "ETS table not available"
    end
  end
end
