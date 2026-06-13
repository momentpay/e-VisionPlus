defmodule VmuCore.CMS.InterestEngine do
  @moduledoc """
  Average Daily Balance (ADB) interest calculation engine.

  VisionPlus interest method:
    1. For each day in the billing cycle, record the outstanding balance.
    2. ADB = sum(daily_balances) / days_in_cycle
    3. Monthly interest = ADB × (APR / 365) × days_in_cycle

  All arithmetic uses Decimal — never Float.

  Grace period: if the previous statement balance was paid in full by
  the payment due date, no interest is charged on retail purchases for
  that cycle (cash advances always accrue from transaction date).
  """

  alias VmuCore.CMS.BalanceBucket
  alias Decimal, as: D

  @doc """
  Calculate monthly interest for an account cycle.

  Params:
    - daily_balances: list of {Date.t(), Decimal.t()} tuples for each day in cycle
    - apr_percentage: Decimal — e.g. Decimal.new("24.00") for 24% APR
    - days_in_cycle:  integer — billing cycle length (28-31)
    - grace_period_applies: boolean — true if previous balance was paid in full

  Returns %{retail_interest: Decimal.t(), cash_interest: Decimal.t(), total: Decimal.t()}
  """
  def calculate(retail_daily, cash_daily, apr_percentage, days_in_cycle, grace_period_applies \\ false) do
    retail_adb = average_daily_balance(retail_daily, days_in_cycle)
    cash_adb   = average_daily_balance(cash_daily, days_in_cycle)

    # Retail: no interest if grace period applies and full payment was made
    retail_interest =
      if grace_period_applies do
        D.new(0)
      else
        compute_interest(retail_adb, apr_percentage, days_in_cycle)
      end

    # Cash advances: always accrued, no grace period
    cash_interest = compute_interest(cash_adb, apr_percentage, days_in_cycle)

    total = D.add(retail_interest, cash_interest)

    %{
      retail_adb:      retail_adb,
      cash_adb:        cash_adb,
      retail_interest: retail_interest,
      cash_interest:   cash_interest,
      total:           total
    }
  end

  @doc """
  Determine if grace period applies for the current cycle.
  True if previous statement balance was fully paid before due date.
  """
  def grace_period_applies?(prev_statement_balance, total_payments_received) do
    case D.compare(total_payments_received, prev_statement_balance) do
      :gt -> true
      :eq -> true
      :lt -> false
    end
  end

  @doc """
  Compute minimum payment due for a statement.

  VisionPlus standard: max(floor(statement_balance × min_payment_pct), minimum_floor)
  """
  def minimum_payment(statement_balance, min_payment_pct \\ D.new("0.05"), floor_amount \\ D.new("100.00")) do
    computed = D.mult(statement_balance, min_payment_pct) |> D.round(2, :ceiling)

    case D.compare(computed, floor_amount) do
      :lt -> floor_amount
      _   -> computed
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp average_daily_balance(daily_balances, days_in_cycle) when length(daily_balances) > 0 do
    sum = Enum.reduce(daily_balances, D.new(0), fn {_date, bal}, acc ->
      D.add(acc, D.max(bal, D.new(0)))  # negative balances (overpayment) treated as zero
    end)

    D.div(sum, D.new(days_in_cycle)) |> D.round(2)
  end

  defp average_daily_balance([], _days), do: D.new(0)

  defp compute_interest(adb, apr_percentage, days_in_cycle) do
    # interest = ADB × (APR% / 100 / 365) × days_in_cycle
    daily_rate = D.div(D.div(apr_percentage, D.new(100)), D.new(365))
    D.mult(D.mult(adb, daily_rate), D.new(days_in_cycle))
    |> D.round(2, :ceiling)
  end
end
