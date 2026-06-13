defmodule VmuCore.HCS.Company do
  use Ecto.Schema
  import Ecto.Changeset

  schema "hcs_companies" do
    field :company_code,         :string
    field :company_name,         :string
    field :registration_no,      :string
    field :tax_id,               :string
    field :industry_code,        :string
    field :liability_model,      :string   # CENTRAL | INDIVIDUAL
    field :billing_cycle_day,    :integer, default: 25
    field :credit_limit,         :decimal
    field :available_limit,      :decimal
    field :max_employee_cards,   :integer, default: 50
    field :parent_account_id,    :integer
    field :relationship_manager, :string
    field :status,               :string, default: "ACTIVE"
    field :kyc_status,           :string, default: "PENDING"
    field :kyc_verified_at,      :utc_datetime

    has_many :employee_cards, VmuCore.HCS.EmployeeCard
    has_many :spending_controls, VmuCore.HCS.SpendingControl
    has_many :consolidated_statements, VmuCore.HCS.ConsolidatedStatement

    timestamps(type: :utc_datetime)
  end

  @valid_models   ~w(CENTRAL INDIVIDUAL)
  @valid_statuses ~w(ACTIVE SUSPENDED CLOSED)
  @valid_kyc      ~w(PENDING VERIFIED REJECTED)

  def changeset(company, attrs) do
    company
    |> cast(attrs, [:company_code, :company_name, :registration_no, :tax_id, :industry_code,
                    :liability_model, :billing_cycle_day, :credit_limit, :available_limit,
                    :max_employee_cards, :parent_account_id, :relationship_manager,
                    :status, :kyc_status, :kyc_verified_at])
    |> validate_required([:company_code, :company_name, :registration_no, :liability_model,
                          :credit_limit, :available_limit])
    |> validate_inclusion(:liability_model, @valid_models)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:kyc_status, @valid_kyc)
    |> validate_number(:billing_cycle_day, greater_than_or_equal_to: 1, less_than_or_equal_to: 31)
    |> validate_number(:credit_limit, greater_than: 0)
    |> unique_constraint(:company_code)
  end
end
