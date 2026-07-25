defmodule VmuCore.Repo.Migrations.CreateHcsFacilityLimitChanges do
  use Ecto.Migration

  @moduledoc """
  F-UI1.1 (2026-07-12) — maker-checker facility limit change requests for
  HCS companies, routed through the existing unified Approval Inbox
  (mirrors COL-P9's WorkoutPlan/SettlementOffer shape).
  """

  def change do
    create table(:hcs_facility_limit_changes, primary_key: false) do
      add :id,               :binary_id, primary_key: true
      add :company_id,       references(:hcs_companies, type: :integer), null: false
      add :current_limit,    :decimal, null: false
      add :requested_limit,  :decimal, null: false
      add :reason,           :string
      add :status,           :string, null: false, default: "PENDING_APPROVAL"
      add :requested_by,     :string, null: false
      add :approved_by,      :string

      timestamps(type: :utc_datetime)
    end

    create index(:hcs_facility_limit_changes, [:company_id])
    create index(:hcs_facility_limit_changes, [:status])
  end
end
