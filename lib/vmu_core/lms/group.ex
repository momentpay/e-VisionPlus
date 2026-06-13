defmodule VmuCore.LMS.Group do
  use Ecto.Schema
  import Ecto.Changeset

  schema "lms_groups" do
    field :scheme_id,         :integer
    field :group_code,        :string
    field :group_type,        :string    # DEFAULT | BONUS
    field :group_name,        :string
    field :settlement_account, :string
    field :status,            :string, default: "ACTIVE"
    field :inserted_at,       :utc_datetime

    belongs_to :scheme, VmuCore.LMS.Scheme, define_field: false
    has_many :plans, VmuCore.LMS.Plan, foreign_key: :group_id
  end

  @valid_types ~w(DEFAULT BONUS)

  def changeset(group, attrs) do
    group
    |> cast(attrs, [:scheme_id, :group_code, :group_type, :group_name,
                    :settlement_account, :status])
    |> validate_required([:scheme_id, :group_code, :group_type, :group_name])
    |> validate_inclusion(:group_type, @valid_types)
    |> unique_constraint([:scheme_id, :group_code])
  end
end
