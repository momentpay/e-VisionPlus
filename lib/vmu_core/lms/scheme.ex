defmodule VmuCore.LMS.Scheme do
  use Ecto.Schema
  import Ecto.Changeset

  schema "lms_schemes" do
    field :scheme_code,           :string
    field :scheme_name,           :string
    field :org_id,                :integer
    field :currency,              :string, default: "AED"
    field :points_expiry_months,  :integer
    field :warehouse_days,        :integer, default: 0
    field :cycle_to_date_include, :boolean, default: true
    field :status,                :string, default: "ACTIVE"

    has_many :groups, VmuCore.LMS.Group, foreign_key: :scheme_id

    timestamps(type: :utc_datetime)
  end

  @required [:scheme_code, :scheme_name, :org_id]

  def changeset(scheme, attrs) do
    scheme
    |> cast(attrs, @required ++ [:currency, :points_expiry_months, :warehouse_days,
                                  :cycle_to_date_include, :status])
    |> validate_required(@required)
    |> validate_length(:scheme_code, max: 5)
    |> validate_inclusion(:status, ~w(ACTIVE SUSPENDED CLOSED))
    |> unique_constraint(:scheme_code)
  end
end
