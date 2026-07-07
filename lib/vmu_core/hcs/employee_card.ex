defmodule VmuCore.HCS.EmployeeCard do
  use Ecto.Schema
  import Ecto.Changeset

  schema "hcs_employee_cards" do
    field :company_id,          :integer
    field :employee_account_id, :binary_id
    field :employee_name,       :string
    field :employee_id,         :string
    field :department,          :string
    field :cost_centre,         :string
    field :individual_limit,    :decimal
    field :available_individual,:decimal
    field :card_type,           :string, default: "STANDARD"
    field :can_withdraw_cash,   :boolean, default: false
    field :monthly_spend_cap,   :decimal
    field :status,              :string, default: "ACTIVE"
    field :issued_at,           :utc_datetime

    belongs_to :company, VmuCore.HCS.Company, define_field: false

    timestamps(type: :utc_datetime)
  end

  @valid_card_types ~w(STANDARD TRAVEL PURCHASING VIRTUAL)
  @valid_statuses   ~w(ACTIVE SUSPENDED CANCELLED)

  def changeset(card, attrs) do
    card
    |> cast(attrs, [:company_id, :employee_account_id, :employee_name, :employee_id,
                    :department, :cost_centre, :individual_limit, :available_individual,
                    :card_type, :can_withdraw_cash, :monthly_spend_cap, :status, :issued_at])
    |> validate_required([:company_id, :employee_account_id, :employee_name,
                          :individual_limit, :available_individual])
    |> validate_inclusion(:card_type, @valid_card_types)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:individual_limit, greater_than: 0)
    |> unique_constraint([:company_id, :employee_account_id])
  end
end
