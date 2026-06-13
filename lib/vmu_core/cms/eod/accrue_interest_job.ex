defmodule VmuCore.CMS.EOD.AccrueInterestJob do
  @moduledoc """
  EOD Step 2 — Calculate and post accrued interest for one account.

  Uses InterestEngine.calculate/5 with the block-level APR from ParameterEngine.
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

    {:ok, apr} =
      ParameterEngine.get(account.sys_id, account.bank_id, account.logo_id, account.block_id, :apr_percentage)

    days_in_cycle = days_in_cycle(account.cycle_code, eod_date)

    # Build simplified daily balance series from current account balances
    retail_daily = for i <- 0..(days_in_cycle - 1),
      do: {Date.add(eod_date, -i), account_retail_balance(account_id)}
    cash_daily   = for i <- 0..(days_in_cycle - 1),
      do: {Date.add(eod_date, -i), account_cash_balance(account_id)}

    interest = InterestEngine.calculate(retail_daily, cash_daily, apr, days_in_cycle)

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
