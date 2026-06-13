defmodule VmuCore.LMS.Plan do
  use Ecto.Schema
  import Ecto.Changeset

  schema "lms_plans" do
    field :group_id,       :integer
    field :plan_type,      :string    # BASE | SUPPLEMENTARY | OVERRIDE
    field :effective_from, :date
    field :effective_to,   :date
    field :status,         :string, default: "ACTIVE"
    field :inserted_at,    :utc_datetime

    belongs_to :group, VmuCore.LMS.Group, define_field: false
    has_many :rate_tiers, VmuCore.LMS.RateTier, foreign_key: :plan_id
  end

  @valid_types ~w(BASE SUPPLEMENTARY OVERRIDE)

  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [:group_id, :plan_type, :effective_from, :effective_to, :status])
    |> validate_required([:group_id, :plan_type, :effective_from])
    |> validate_inclusion(:plan_type, @valid_types)
    |> validate_date_range()
  end

  defp validate_date_range(cs) do
    from = get_field(cs, :effective_from)
    to   = get_field(cs, :effective_to)

    if from && to && Date.compare(from, to) == :gt do
      add_error(cs, :effective_to, "must be after effective_from")
    else
      cs
    end
  end
end
