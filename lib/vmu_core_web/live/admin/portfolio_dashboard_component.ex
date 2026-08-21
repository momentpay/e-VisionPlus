defmodule VmuCoreWeb.Live.Admin.PortfolioDashboardComponent do
  @moduledoc """
  Admin LiveComponent: portfolio-wide overview (the Overview module's first
  live screen, Phase 7 of the AG Grid/AG Charts rollout — see
  `docs/shared/Admin_Menu_Standard.md`).

  Read-only, no scope picker — genuinely global aggregates across every
  sys/bank/logo, reusing the same real data each figure's own module
  screen already reports (`VmuCore.COL.CollectionsMi` for the recovery
  KPIs) rather than inventing a parallel metrics layer. "Issuing KPIs" and
  "Alerts & Notifications" (the other two Overview sidebar items) stay
  `:planned` — this screen only covers the account/dispute/collections
  aggregates that already exist elsewhere in the codebase.
  """

  use Phoenix.LiveComponent
  import Ecto.Query
  import VmuCoreWeb.AdminUI
  import VmuCoreWeb.Components.AgGrid

  alias VmuCore.Repo
  alias VmuCore.CMS.Account
  alias VmuCore.DPS.Dispute
  alias VmuCore.COL.CollectionsMi

  @terminal_dispute_statuses ~w[CLOSED_WIN CLOSED_LOSE CANCELLED]

  @impl true
  def mount(socket) do
    {:ok, load(socket)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> load()}
  end

  defp load(socket) do
    today = Date.utc_today()
    from_date = Date.add(today, -30)

    assign(socket,
      total_accounts: Repo.aggregate(Account, :count, :account_id),
      total_credit_limit: Repo.one(from(a in Account, select: sum(a.credit_limit))) || Decimal.new(0),
      total_open_to_buy: Repo.one(from(a in Account, select: sum(a.open_to_buy))) || Decimal.new(0),
      open_disputes: Repo.aggregate(from(d in Dispute, where: d.status not in @terminal_dispute_statuses), :count, :dispute_id),
      status_dist: account_status_distribution(),
      delinquency_dist: delinquency_distribution(),
      promise: CollectionsMi.promise_kept_rate(from_date, today),
      recovery: CollectionsMi.recovery_rate(from_date, today)
    )
  end

  defp account_status_distribution do
    Repo.all(
      from a in Account,
        group_by: a.account_status,
        select: {a.account_status, count(a.account_id)},
        order_by: [desc: count(a.account_id)]
    )
    |> Enum.map(fn {status, n} -> %{status: status, count: n} end)
  end

  defp delinquency_distribution do
    Repo.all(
      from a in Account,
        where: a.account_status in ["ACTIVE", "DELINQUENT"],
        group_by: a.delinquency_bucket,
        select: {a.delinquency_bucket, count(a.account_id)},
        order_by: [asc: a.delinquency_bucket]
    )
    |> Enum.map(fn {bucket, n} -> %{bucket: bucket_label(bucket), count: n} end)
  end

  defp bucket_label(0), do: "Current"
  defp bucket_label(n), do: "#{n}+ DPD"

  defp fmt_pct(nil), do: "—"
  defp fmt_pct(d), do: "#{d}%"

  defp money(nil), do: "—"
  defp money(%Decimal{} = d), do: d |> Decimal.round(2) |> Decimal.to_string()
  defp money(v), do: to_string(v)

  defp utilization_pct(limit, otb) do
    used = Decimal.sub(limit, otb)

    if Decimal.compare(limit, Decimal.new(0)) == :gt do
      used |> Decimal.div(limit) |> Decimal.mult(Decimal.new(100)) |> Decimal.round(1)
    else
      Decimal.new(0)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="component-panel">
      <.page_header title="Portfolio Dashboard" subtitle="Live totals across every institution — read-only" />

      <div style="display:flex; gap:1rem; flex-wrap:wrap; margin-bottom:1.5rem">
        <.form_card title="Accounts">
          <.kv_detail rows={[
            {"Total accounts", @total_accounts},
            {"Total credit limit", money(@total_credit_limit)},
            {"Total open-to-buy", money(@total_open_to_buy)},
            {"Utilization", "#{utilization_pct(@total_credit_limit, @total_open_to_buy)}%"}
          ]} />
        </.form_card>

        <.form_card title="Disputes">
          <.kv_detail rows={[
            {"Open disputes", @open_disputes}
          ]} />
        </.form_card>

        <.form_card title="Collections — last 30 days">
          <.kv_detail rows={[
            {"Promise-kept rate", fmt_pct(@promise.rate)},
            {"Recovery rate", fmt_pct(@recovery.rate)}
          ]} />
        </.form_card>
      </div>

      <div style="display:flex; gap:1.5rem; flex-wrap:wrap">
        <div :if={@status_dist != []} style="flex:1; min-width:320px">
          <h4 style="margin:0 0 0.5rem">Account status distribution</h4>
          <.ag_chart
            id="portfolio-status-chart"
            type="donut"
            data={@status_dist}
            category="status"
            series={[%{field: "count", name: "Accounts"}]}
          />
        </div>

        <div :if={@delinquency_dist != []} style="flex:1; min-width:320px">
          <h4 style="margin:0 0 0.5rem">Delinquency bucket distribution</h4>
          <.ag_chart
            id="portfolio-delinquency-chart"
            type="bar"
            data={@delinquency_dist}
            category="bucket"
            series={[%{field: "count", name: "Accounts"}]}
          />
        </div>
      </div>

      <p :if={@total_accounts == 0} class="text-muted" style="margin-top:1rem">
        No accounts in the system yet — figures above will populate as accounts are opened.
      </p>
    </div>
    """
  end
end
