defmodule VmuCore.Repo.Migrations.CreateHcsFleetTables do
  use Ecto.Migration

  # F2/F3 (2026-07-12) — fleet vehicle/driver sub-account, parallel to
  # hcs_employee_cards rather than reusing it (vehicle and employee are
  # different identity concepts even though the limit/control mechanics
  # are identical — see docs/fleet/FLEET_Module_Requirements.md Phase F2).
  def change do
    create table(:hcs_vehicles) do
      add :company_id,    references(:hcs_companies, on_delete: :restrict), null: false
      add :vin,           :string, size: 17
      add :plate_number,  :string, size: 20, null: false
      add :make,          :string, size: 50
      add :model,         :string, size: 50
      add :year,          :integer
      add :status,        :string, size: 20, null: false, default: "ACTIVE"
      timestamps(type: :utc_datetime)
    end

    create unique_index(:hcs_vehicles, [:company_id, :vin], where: "vin IS NOT NULL")
    create index(:hcs_vehicles, [:company_id, :status])

    create table(:hcs_driver_assignments) do
      add :vehicle_id,        references(:hcs_vehicles, on_delete: :restrict), null: false
      add :driver_name,       :string, size: 200, null: false
      add :driver_license_no, :string, size: 50
      add :assigned_at,       :utc_datetime, null: false
      add :unassigned_at,     :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:hcs_driver_assignments, [:vehicle_id, :unassigned_at])

    create table(:hcs_fleet_cards) do
      add :company_id,           references(:hcs_companies, on_delete: :restrict), null: false
      add :vehicle_id,           references(:hcs_vehicles, on_delete: :restrict), null: false
      add :account_id,           references(:cms_accounts, column: :account_id, type: :uuid, on_delete: :restrict), null: false
      add :card_type,            :string, size: 20, null: false, default: "FUEL"
      add :can_withdraw_cash,    :boolean, null: false, default: false
      add :individual_limit,     :decimal, precision: 18, scale: 2, null: false
      add :available_individual, :decimal, precision: 18, scale: 2, null: false
      add :monthly_spend_cap,    :decimal, precision: 18, scale: 2
      add :status,               :string, size: 20, null: false, default: "ACTIVE"
      add :issued_at,            :utc_datetime
      add :daily_spend,          :decimal, precision: 18, scale: 2, default: "0"
      add :daily_spend_date,     :date
      timestamps(type: :utc_datetime)
    end

    create unique_index(:hcs_fleet_cards, [:company_id, :account_id])
    create index(:hcs_fleet_cards, [:vehicle_id])
    create index(:hcs_fleet_cards, [:account_id])

    alter table(:hcs_spending_controls) do
      add :fleet_card_id, references(:hcs_fleet_cards, on_delete: :restrict)
    end
  end
end
