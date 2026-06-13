defmodule VmuCore.LMS.RateTier do
  use Ecto.Schema
  import Ecto.Changeset

  schema "lms_rate_tiers" do
    field :plan_id,               :integer
    field :tier_order,            :integer
    field :min_amount,            :decimal
    field :max_amount,            :decimal
    field :points_per_unit,       :decimal
    field :min_qualifying_amount, :decimal, default: Decimal.new("0.01")
    field :inserted_at,           :utc_datetime

    belongs_to :plan, VmuCore.LMS.Plan, define_field: false
  end

  def changeset(tier, attrs) do
    tier
    |> cast(attrs, [:plan_id, :tier_order, :min_amount, :max_amount,
                    :points_per_unit, :min_qualifying_amount])
    |> validate_required([:plan_id, :tier_order, :min_amount, :points_per_unit])
    |> validate_number(:tier_order, greater_than: 0)
    |> validate_number(:points_per_unit, greater_than: 0)
    |> unique_constraint([:plan_id, :tier_order])
  end
end
