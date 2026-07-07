defmodule VmuCore.CMS.InterestEngine do
  @moduledoc """
  Average Daily Balance (ADB) interest calculation engine.

  VisionPlus interest method:
    1. For each day in the billing cycle, record the outstanding balance.
    2. ADB = sum(daily_balances) / days_in_cycle
    3. Monthly interest = ADB × (APR / 365) × days_in_cycle

  All arithmetic uses Decimal — never Float.

  ## Grace period

  If the previous statement balance was paid in full by the payment due date,
  no interest is charged on retail purchases for that cycle. Cash advances
  **always** accrue interest from transaction date — no grace period applies.

  ## APR routing (2D)

  Cash advances carry a separate, higher APR than retail purchases. The cascade:

      Block.cash_apr_percentage → Logo.cash_apr → (fallback: Logo.purchase_apr)

  Callers should resolve both APRs from ParameterEngine before calling `calculate/6`:

      {:ok, purchase_apr} = ParameterEngine.get(sys, bank, logo, block, :apr_percentage)
      {:ok, cash_apr}     = ParameterEngine.get(sys, bank, logo, block, :cash_apr_percentage)
      # On error fall back to :cash_apr at logo level, then purchase_apr

  ## Balance transfer billing (3C)

  Balance transfer (BT) balances use `PlanSegment.effective_apr/1` to determine
  the current rate — promotional during the promo window, standard rate thereafter.
  BT balances **never** receive a grace period (same behaviour as CASH advances).

  Use `calculate/8` to compute all three balance pools in a single pass:

      bt_apr = PlanSegment.effective_apr(bt_plan)
      result = InterestEngine.calculate(
        retail_daily, cash_daily, bt_daily,
        purchase_apr, cash_apr, bt_apr,
        days_in_cycle, grace_applies
      )
      result.bt_interest  # => Decimal
  """

  alias Decimal, as: D

  @doc """
  Calculate monthly interest for an account cycle with separate APRs for retail and cash.

  Params:
    - retail_daily     : `[{Date.t(), Decimal.t()}]` — daily retail balances in cycle
    - cash_daily       : `[{Date.t(), Decimal.t()}]` — daily cash balances in cycle
    - purchase_apr     : `Decimal.t()` — retail APR, e.g. `Decimal.new("24.00")` (24%)
    - cash_apr         : `Decimal.t()` — cash advance APR, e.g. `Decimal.new("30.00")` (30%)
    - days_in_cycle    : `pos_integer()` — billing cycle length (28–31)
    - grace_period_applies : `boolean()` — true when previous statement was paid in full

  Returns:
    ```
    %{
      retail_adb:      Decimal.t(),
      cash_adb:        Decimal.t(),
      retail_interest: Decimal.t(),
      cash_interest:   Decimal.t(),
      total:           Decimal.t()
    }
    ```
  """
  @spec calculate(
          list({Date.t(), Decimal.t()}),
          list({Date.t(), Decimal.t()}),
          Decimal.t(),
          Decimal.t(),
          pos_integer(),
          boolean()
        ) :: map()
  def calculate(retail_daily, cash_daily, purchase_apr, cash_apr, days_in_cycle, grace_period_applies \\ false) do
    calculate(retail_daily, cash_daily, [], purchase_apr, cash_apr, D.new(0), days_in_cycle, grace_period_applies)
  end

  @doc """
  Full three-pool calculation: retail + cash + balance transfer.

  BT balances use `bt_apr` (resolved via `PlanSegment.effective_apr/1` by the caller)
  and never receive a grace period regardless of full payment.

  Returns all fields from `calculate/6` plus:
    - `:bt_adb`      — average daily balance for BT pool
    - `:bt_interest` — interest assessed on BT pool this cycle

  The `:total` field includes `bt_interest`.
  """
  @spec calculate(
          list({Date.t(), Decimal.t()}),
          list({Date.t(), Decimal.t()}),
          list({Date.t(), Decimal.t()}),
          Decimal.t(),
          Decimal.t(),
          Decimal.t(),
          pos_integer(),
          boolean()
        ) :: map()
  def calculate(retail_daily, cash_daily, bt_daily, purchase_apr, cash_apr, bt_apr, days_in_cycle, grace_period_applies \\ false) do
    retail_adb = average_daily_balance(retail_daily, days_in_cycle)
    cash_adb   = average_daily_balance(cash_daily,  days_in_cycle)
    bt_adb     = average_daily_balance(bt_daily,    days_in_cycle)

    # Retail: no interest when grace period applies and full payment was made
    retail_interest =
      if grace_period_applies do
        D.new(0)
      else
        compute_interest(retail_adb, purchase_apr, days_in_cycle)
      end

    # Cash advances: always accrue; use the dedicated cash APR (typically higher)
    cash_interest = compute_interest(cash_adb, cash_apr, days_in_cycle)

    # Balance transfer: always accrues (same as cash); uses promo or standard APR
    bt_interest = compute_interest(bt_adb, bt_apr, days_in_cycle)

    total = D.add(retail_interest, cash_interest) |> D.add(bt_interest)

    %{
      retail_adb:      retail_adb,
      cash_adb:        cash_adb,
      bt_adb:          bt_adb,
      retail_interest: retail_interest,
      cash_interest:   cash_interest,
      bt_interest:     bt_interest,
      total:           total
    }
  end

  @doc """
  Determine if grace period applies for the current cycle.
  Returns true when `total_payments_received >= prev_statement_balance`.
  """
  @spec grace_period_applies?(Decimal.t(), Decimal.t()) :: boolean()
  def grace_period_applies?(prev_statement_balance, total_payments_received) do
    case D.compare(total_payments_received, prev_statement_balance) do
      :gt -> true
      :eq -> true
      :lt -> false
    end
  end

  @doc """
  Compute the VisionPlus compound minimum payment due for a statement.

  Formula (per VisionPlus spec):

      minimum_payment = interest_due
                      + fees_due
                      + past_due
                      + max(principal_balance × 0.01, floor_amount)

  Where:
    - `interest_due`        — interest assessed this cycle (from `calculate/6`)
    - `fees_due`            — fees assessed this cycle (from balance_bucket.unpaid_fees delta)
    - `past_due`            — prior cycle unpaid minimum (delinquency carry-forward)
    - `principal_balance`   — current retail + cash outstanding balance
    - `floor_amount`        — minimum floor from logo parameters (default 25.00)

  ## Examples

      iex> InterestEngine.minimum_payment(
      ...>   D.new("50.00"),   # interest_due
      ...>   D.new("25.00"),   # fees_due
      ...>   D.new("0"),       # past_due (current)
      ...>   D.new("2000.00"), # principal
      ...>   D.new("25.00")    # floor
      ...> )
      #Decimal<95.00>  # 50 + 25 + 0 + max(20, 25) = 100
  """
  @spec minimum_payment(
          Decimal.t(),
          Decimal.t(),
          Decimal.t(),
          Decimal.t(),
          Decimal.t()
        ) :: Decimal.t()
  def minimum_payment(
        interest_due,
        fees_due,
        past_due,
        principal_balance,
        floor_amount \\ D.new("25.00")
      ) do
    one_pct_principal = D.mult(principal_balance, D.new("0.01")) |> D.round(2, :ceiling)

    principal_component =
      case D.compare(one_pct_principal, floor_amount) do
        :gt -> one_pct_principal
        _   -> floor_amount
      end

    D.add(interest_due, fees_due)
    |> D.add(past_due)
    |> D.add(principal_component)
    |> D.round(2, :ceiling)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp average_daily_balance(daily_balances, days_in_cycle) when length(daily_balances) > 0 do
    sum =
      Enum.reduce(daily_balances, D.new(0), fn {_date, bal}, acc ->
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
