defmodule VmuCore.CDM.LimitAllocator do
  @moduledoc """
  Income-based credit limit calculation by risk tier.

  Multipliers are configurable per logo via ParameterEngine (block parameters).
  Falls back to system-level defaults if logo-specific multipliers are not set.

  Tier multipliers (default):
    PRIME      → 2.0× monthly income  (capped at logo max_limit)
    NEAR_PRIME → 1.0× monthly income
    SUBPRIME   → 0.5× monthly income  (min_limit enforced)
    DECLINE    → Decimal.new(0)       (no limit allocated)
  """

  alias VmuCore.Shared.ParameterEngine
  alias Decimal, as: D

  @default_multipliers %{
    prime:      D.new("2.0"),
    near_prime: D.new("1.0"),
    subprime:   D.new("0.5"),
    decline:    D.new("0")
  }

  @dsr_cap D.new("0.50")   # UAE Central Bank CBUAE Notice 2023/1 — max DSR 50%
  @min_payment_rate D.new("0.05")   # 5% of limit as minimum payment estimate

  @doc """
  Calculate the approved credit limit for a given income and risk tier.

  Also enforces the UAE Central Bank DSR (Debt Service Ratio) cap (G9):
    (existing_monthly_payments + 5% of proposed_limit) / monthly_income <= 0.50

  Returns {:ok, limit} or {:error, :tier_declined} or {:error, :dsr_cap_exceeded}.

  existing_monthly_payments defaults to 0 for new-to-bank applicants.
  """
  @spec calculate(Decimal.t(), atom(), String.t(), String.t(), String.t(), Decimal.t()) ::
          {:ok, Decimal.t()} | {:error, :tier_declined} | {:error, :dsr_cap_exceeded}
  def calculate(monthly_income, tier, sys_id, bank_id, logo_id, existing_monthly_payments \\ D.new(0))

  def calculate(_monthly_income, :decline, _sys_id, _bank_id, _logo_id, _existing) do
    {:error, :tier_declined}
  end

  def calculate(monthly_income, tier, sys_id, bank_id, logo_id, existing_monthly_payments) do
    multiplier = resolve_multiplier(tier, sys_id, bank_id, logo_id)
    raw_limit  = D.mult(monthly_income, multiplier) |> D.round(2)

    {min_limit, max_limit} = resolve_limit_bounds(sys_id, bank_id, logo_id)

    limit =
      raw_limit
      |> D.max(min_limit)
      |> D.min(max_limit)
      |> round_to_hundred()

    # DSR check: (existing_payments + 5% of proposed_limit) / income <= 0.50
    min_payment_estimate = D.mult(limit, @min_payment_rate)
    total_debt_service   = D.add(existing_monthly_payments, min_payment_estimate)
    dsr                  = D.div(total_debt_service, monthly_income)

    if D.compare(dsr, @dsr_cap) == :gt do
      {:error, :dsr_cap_exceeded}
    else
      {:ok, limit}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp resolve_multiplier(tier, sys_id, bank_id, logo_id) do
    param_key = "cdm_multiplier_#{tier}"

    case ParameterEngine.get(sys_id, bank_id, logo_id, nil, param_key) do
      {:ok, val} when is_binary(val) ->
        case D.parse(val) do
          {d, ""} -> d
          _       -> Map.fetch!(@default_multipliers, tier)
        end

      _ ->
        Map.fetch!(@default_multipliers, tier)
    end
  end

  defp resolve_limit_bounds(sys_id, bank_id, logo_id) do
    min_str = ParameterEngine.get(sys_id, bank_id, logo_id, nil, "cdm_min_limit")
    max_str = ParameterEngine.get(sys_id, bank_id, logo_id, nil, "cdm_max_limit")

    min_limit = parse_decimal(min_str, "500.00")
    max_limit = parse_decimal(max_str, "50000.00")
    {min_limit, max_limit}
  end

  defp parse_decimal({:ok, val}, _default) when is_binary(val) do
    case D.parse(val) do
      {d, ""} -> d
      _       -> D.new(0)
    end
  end
  defp parse_decimal(_, default), do: D.new(default)

  # Round up to the nearest 100 (e.g., 1234 → 1300) for clean limit figures
  defp round_to_hundred(amount) do
    cents = D.to_integer(D.round(amount, 0, :ceiling))
    remainder = rem(cents, 100)

    if remainder == 0,
      do: D.new(cents),
      else: D.new(cents + (100 - remainder))
  end
end
