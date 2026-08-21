defmodule VmuCore.COL.WorkoutPlan do
  @moduledoc """
  Hardship/workout plan (COL-P9, FR-COL-014): restructure, APR reduction, or
  payment holiday, maker-checker gated. Written by `VmuCore.COL.WorkoutCommand`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @plan_types ~w[RESTRUCTURE APR_REDUCTION PAYMENT_HOLIDAY]
  @statuses ~w[PENDING_APPROVAL APPROVED REJECTED ACTIVE COMPLETED CANCELLED]

  schema "col_workout_plans" do
    field :case_id,          :binary_id
    field :account_id,       :binary_id
    field :plan_type,        :string
    field :new_apr,          :decimal
    field :holiday_months,   :integer
    field :emi_tenor_months, :integer
    field :start_date,       :date
    field :end_date,         :date
    field :status,           :string, default: "PENDING_APPROVAL"
    field :reason,           :string
    field :requested_by,     :string
    field :approved_by,      :string

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w[case_id account_id plan_type start_date end_date requested_by]a
  @optional ~w[new_apr holiday_months emi_tenor_months status reason approved_by]a

  def changeset(plan, attrs) do
    plan
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:plan_type, @plan_types)
    |> validate_inclusion(:status, @statuses)
  end

  def plan_types, do: @plan_types
end
