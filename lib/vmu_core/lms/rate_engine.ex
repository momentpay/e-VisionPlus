defmodule VmuCore.LMS.RateEngine do
  @moduledoc """
  Calculates points earned for a monetary transaction given a plan and tier table.

  Plan resolution priority (per VisionPlus LMS spec):
    1. OVERRIDE (if effective for date) → use only the override plan
    2. BASE + SUPPLEMENTARY (if both effective) → sum both
    3. BASE only

  Tier selection: the highest tier whose min_amount ≤ transaction amount.
  """

  alias VmuCore.LMS.{Plan, RateTier}
  alias VmuCore.Repo
  import Ecto.Query
  alias Decimal, as: D

  @doc """
  Returns {:ok, points} for the given plan_id and transaction amount,
  or {:error, :below_minimum | :no_applicable_tier}.
  """
  def calculate_points(plan_id, amount) do
    tier =
      from(t in RateTier,
        where: t.plan_id == ^plan_id and t.min_amount <= ^amount,
        order_by: [desc: t.tier_order],
        limit: 1
      )
      |> Repo.one()

    case tier do
      nil ->
        {:error, :no_applicable_tier}

      t ->
        if D.lt?(amount, t.min_qualifying_amount) do
          {:error, :below_minimum}
        else
          points = D.mult(amount, t.points_per_unit)
          {:ok, D.round(points, 2, :floor)}
        end
    end
  end

  @doc """
  Resolves which plan(s) apply for a given group on a given transaction date.
  Returns a list of plans. OVERRIDE is mutually exclusive with BASE+SUPPLEMENTARY.
  """
  def resolve_active_plans(group_id, transaction_date) do
    plans =
      from(p in Plan,
        where:
          p.group_id == ^group_id and
          p.status == "ACTIVE" and
          p.effective_from <= ^transaction_date and
          (is_nil(p.effective_to) or p.effective_to >= ^transaction_date),
        order_by: p.plan_type
      )
      |> Repo.all()

    override = Enum.find(plans, &(&1.plan_type == "OVERRIDE"))

    if override,
      do: [override],
      else: Enum.filter(plans, &(&1.plan_type in ["BASE", "SUPPLEMENTARY"]))
  end
end
