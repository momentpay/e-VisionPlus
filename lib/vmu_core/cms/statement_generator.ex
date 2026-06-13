defmodule VmuCore.CMS.StatementGenerator do
  @moduledoc """
  Generates the monthly billing statement snapshot for a credit card account.

  Produces a statement_balance, minimum_payment, and next_statement_date.
  The snapshot is persisted back to cms_balance_buckets for the statement date
  and AccountStateCoordinator is refreshed so OTB reflects the new balance.
  """

  require Logger
  import Ecto.Query

  alias VmuCore.{Repo, CMS.Account, CMS.BalanceBucket, CMS.InterestEngine, CMS.AccountStateCoordinator}
  alias Decimal, as: D

  @doc """
  Generate and persist a statement for account_id on statement_date.

  Returns {:ok, %{statement_balance, minimum_payment, next_statement_date}}
  """
  def generate(account_id, statement_date, opts \\ []) do
    apr = Keyword.get(opts, :apr_percentage, D.new("24.00"))
    min_pct = Keyword.get(opts, :min_payment_pct, D.new("0.05"))

    with {:ok, account} <- load_account(account_id),
         {:ok, bucket}  <- latest_bucket(account_id, statement_date) do

      days_in_cycle  = days_in_cycle(account.cycle_code, statement_date)
      grace_applies  = InterestEngine.grace_period_applies?(
                         bucket.statement_balance,
                         payments_received(account_id, statement_date, days_in_cycle))

      interest       = InterestEngine.calculate(
                         retail_daily_balances(account_id, statement_date, days_in_cycle),
                         cash_daily_balances(account_id, statement_date, days_in_cycle),
                         apr, days_in_cycle, grace_applies)

      total_interest = interest.total
      new_retail     = D.add(bucket.retail_balance, total_interest)
      stmt_balance   = BalanceBucket.total(%{bucket | retail_balance: new_retail})
      min_payment    = InterestEngine.minimum_payment(stmt_balance, min_pct)
      next_stmt_date = next_statement_date(account.cycle_code, statement_date)

      Repo.update_all(
        from(b in BalanceBucket,
          where: b.account_id == ^account_id and b.balance_date == ^statement_date),
        set: [
          accrued_interest: D.add(bucket.accrued_interest, total_interest),
          statement_balance: stmt_balance,
          minimum_payment:   min_payment,
          updated_at:        NaiveDateTime.utc_now()
        ]
      )

      Repo.update_all(
        from(a in Account, where: a.account_id == ^account_id),
        set: [
          next_statement_date: next_stmt_date,
          updated_at:          NaiveDateTime.utc_now()
        ]
      )

      AccountStateCoordinator.refresh(account_id)

      Logger.info("[Statement] account=#{account_id} balance=#{stmt_balance} min=#{min_payment}")

      {:ok, %{statement_balance: stmt_balance, minimum_payment: min_payment, next_statement_date: next_stmt_date}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp load_account(account_id) do
    case Repo.get(Account, account_id) do
      nil     -> {:error, :account_not_found}
      account -> {:ok, account}
    end
  end

  defp latest_bucket(account_id, as_of_date) do
    query = from b in BalanceBucket,
              where: b.account_id == ^account_id and b.balance_date <= ^as_of_date,
              order_by: [desc: b.balance_date],
              limit: 1

    case Repo.one(query) do
      nil    -> {:error, :no_balance_bucket}
      bucket -> {:ok, bucket}
    end
  end

  defp days_in_cycle(cycle_code, statement_date) do
    # cycle_code = billing day of month (1-31)
    prev_month = Date.add(statement_date, -(cycle_code))
    Date.diff(statement_date, prev_month)
  end

  defp next_statement_date(cycle_code, from_date) do
    %{year: y, month: m} = from_date
    {ny, nm} = if m == 12, do: {y + 1, 1}, else: {y, m + 1}
    max_day  = Date.days_in_month(Date.new!(ny, nm, 1))
    Date.new!(ny, nm, min(cycle_code, max_day))
  end

  defp payments_received(account_id, statement_date, days_in_cycle) do
    start_date = Date.add(statement_date, -days_in_cycle)

    Repo.one(
      from e in VmuCore.CMS.LedgerEntry,
        where: e.account_id == ^account_id
          and e.transaction_code == "PAYMENT"
          and e.posting_date >= ^start_date
          and e.posting_date <= ^statement_date,
        select: coalesce(sum(e.cr_amount), ^D.new(0))
    ) || D.new(0)
  end

  # Simplified: use statement balance as proxy for daily balance series
  # In production this would aggregate daily snapshots from cms_balance_buckets
  defp retail_daily_balances(account_id, statement_date, days_in_cycle) do
    bucket = Repo.one(
      from b in BalanceBucket,
        where: b.account_id == ^account_id and b.balance_date <= ^statement_date,
        order_by: [desc: b.balance_date], limit: 1
    )

    balance = if bucket, do: bucket.retail_balance, else: D.new(0)
    for i <- 0..(days_in_cycle - 1), do: {Date.add(statement_date, -i), balance}
  end

  defp cash_daily_balances(account_id, statement_date, days_in_cycle) do
    bucket = Repo.one(
      from b in BalanceBucket,
        where: b.account_id == ^account_id and b.balance_date <= ^statement_date,
        order_by: [desc: b.balance_date], limit: 1
    )

    balance = if bucket, do: bucket.cash_balance, else: D.new(0)
    for i <- 0..(days_in_cycle - 1), do: {Date.add(statement_date, -i), balance}
  end
end
