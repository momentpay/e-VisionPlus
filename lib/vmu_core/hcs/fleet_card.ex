defmodule VmuCore.HCS.FleetCard do
  @moduledoc """
  Vehicle-keyed card sub-account (Way4 parity plan Phase 1 item 3,
  2026-07-25) — the fleet analog of `HCS.EmployeeCard`. Deliberately a
  parallel schema rather than a variant of `EmployeeCard` (vehicle and
  employee are different identity concepts); shares the same field names
  for limit/control fields on purpose so `HCS.LimitController` can
  enforce both kinds through the same generic checks.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "hcs_fleet_cards" do
    field :company_id,           :integer
    field :vehicle_id,           :integer
    field :account_id,           :binary_id
    field :card_type,            :string, default: "FUEL"
    field :can_withdraw_cash,    :boolean, default: false
    field :individual_limit,     :decimal
    field :available_individual, :decimal
    field :monthly_spend_cap,    :decimal
    field :status,               :string, default: "ACTIVE"
    field :issued_at,            :utc_datetime
    field :daily_spend,          :decimal, default: 0
    field :daily_spend_date,     :date

    belongs_to :company, VmuCore.HCS.Company, define_field: false
    belongs_to :vehicle, VmuCore.HCS.Vehicle, define_field: false

    timestamps(type: :utc_datetime)
  end

  @valid_card_types ~w(FUEL STANDARD)
  @valid_statuses   ~w(ACTIVE SUSPENDED CANCELLED)

  def changeset(card, attrs) do
    card
    |> cast(attrs, [:company_id, :vehicle_id, :account_id, :card_type, :can_withdraw_cash,
                    :individual_limit, :available_individual, :monthly_spend_cap, :status,
                    :issued_at, :daily_spend, :daily_spend_date])
    |> validate_required([:company_id, :vehicle_id, :account_id, :individual_limit,
                          :available_individual])
    |> validate_inclusion(:card_type, @valid_card_types)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:individual_limit, greater_than: 0)
    |> unique_constraint([:company_id, :account_id])
  end
end
