defmodule VmuCore.CMS.EOD.AccrueInterestJob do
  @moduledoc """
  EOD Step 2 — Calculate and post accrued interest for one account.

  Uses InterestEngine.calculate/6 with separate purchase and cash APRs
  resolved from ParameterEngine (Block → Logo → Bank → System cascade).
  Posts the interest to cms_ledger_entries via InternalGlPoster (idempotent).
  Enqueues AgeBucketsJob on success.
  """

  use Oban.Worker, queue: :eod, max_attempts: 3, unique: [period: 86_400]

  require Logger
  alias VmuCore.{Repo, CMS.Account, CMS.InterestEngine, CMS.InternalGlPoster}
  alias VmuCore.Shared.ParameterEngine
  alias Decimal, as: D

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id, "eod_date" => eod_date_str}}) do
    eod_date = Date.from_iso8601!(eod_date_str)

    account = Repo.get!(Account, account_id)

    {:ok, base_purchase_apr} =
      ParameterEngine.get(account.sys_id, account.bank_id, account.logo_id, account.block_id, :apr_percentage)

    # Cash APR from Block → Logo cascade; fall back to purchase_apr if not configured
    base_cash_apr =
      case ParameterEngine.get(account.sys_id, account.bank_id, account.logo_id, account.block_id, :cash_apr_percentage) do
        {:ok, nil} -> base_purchase_apr
        {:ok, v}   -> v
        _          -> base_purchase_apr
      end

    # Penalty APR escalation (3K): if account DPD >= dpd_trigger, override both APRs
    {purchase_apr, cash_apr} = resolve_effective_aprs(
      account,
      base_purchase_apr,
      base_cash_apr
    )

    days_in_cycle = days_in_cycle(account.cycle_code, eod_date)

    # Build simplified daily balance series from current account balances
    retail_daily = for i <- 0..(days_in_cycle - 1),
      do: {Date.add(eod_date, -i), account_retail_balance(account_id)}
    cash_daily   = for i <- 0..(days_in_cycle - 1),
      do: {Date.add(eod_date, -i), account_cash_balance(account_id)}

    interest = InterestEngine.calculate(retail_daily, cash_daily, purchase_apr, cash_apr, days_in_cycle)

    if D.compare(interest.total, D.new(0)) == :gt do
      idempotency_key = "INTEREST-#{account_id}-#{eod_date_str}"
      InternalGlPoster.post_interest(account_id, interest.total, eod_date, idempotency_key)
      Logger.info("[EOD] Accrued interest=#{interest.total} account=#{account_id}")
    end

    %{account_id: account_id, eod_date: eod_date_str}
    |> VmuCore.CMS.EOD.AgeBucketsJob.new()
    |> Oban.insert()

    :ok
  end

  # ── Penalty APR escalation (3K) ──────────────────────────────────────────────
  #
  # If account.delinquency_bucket >= penalty_apr_dpd_trigger AND penalty_apr > 0,
  # both purchase and cash APRs are replaced with penalty_apr for this billing cycle.
  # This is logged at WARNING level so the escalation is visible in EOD audit logs.
  #
  defp resolve_effective_aprs(account, base_purchase_apr, base_cash_apr) do
    alias VmuCore.Shared.ParameterEngine
    alias VmuCore.CMS.PenaltyAprManager

    dpd       = account.delinquency_bucket || 0
    sys_id    = account.sys_id
    bank_id   = account.bank_id
    logo_id   = account.logo_id
    block_id  = account.block_id

    # CMS-G1 ADR-C2: penalty pricing PERSISTS once triggered — penalized?/3 is
    # true while penalty_apr_active, even after DPD falls below the trigger.
    # Deactivation only happens via the cure rule at statement cycle.
    with {:ok, penalty_apr}     when not is_nil(penalty_apr) <-
           ParameterEngine.get(sys_id, bank_id, logo_id, block_id, :penalty_apr),
         {:ok, dpd_trigger}     when not is_nil(dpd_trigger) <-
           ParameterEngine.get(sys_id, bank_id, logo_id, block_id, :penalty_apr_dpd_trigger),
         true <- PenaltyAprManager.penalized?(account, dpd, dpd_trigger),
         true <- Decimal.compare(penalty_apr, Decimal.new(0)) == :gt do

      # Persist activation on first trigger (idempotent when already active)
      if dpd >= dpd_trigger, do: PenaltyAprManager.maybe_activate(account, dpd)

      Logger.warning(
        "[AccrueInterest] Penalty APR pricing account=#{account.account_id} " <>
        "DPD=#{dpd} trigger=#{dpd_trigger} active=#{account.penalty_apr_active} " <>
        "APR #{base_purchase_apr}% → #{penalty_apr}%"
      )

      {penalty_apr, penalty_apr}
    else
      _ -> {base_purchase_apr, base_cash_apr}
    end
  end

  defp days_in_cycle(cycle_code, date) do
    prev = Date.add(date, -cycle_code)
    Date.diff(date, prev)
  end

  defp account_retail_balance(account_id) do
    import Ecto.Query
    Repo.one(
      from b in VmuCore.CMS.BalanceBucket,
        where: b.account_id == ^account_id,
        order_by: [desc: b.balance_date],
        limit: 1,
        select: b.retail_balance
    ) || D.new(0)
  end

  defp account_cash_balance(account_id) do
    import Ecto.Query
    Repo.one(
      from b in VmuCore.CMS.BalanceBucket,
        where: b.account_id == ^account_id,
        order_by: [desc: b.balance_date],
        limit: 1,
        select: b.cash_balance
    ) || D.new(0)
  end
end
