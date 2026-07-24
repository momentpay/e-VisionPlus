defmodule VmuCore.Repo.Migrations.CreateColWorkoutAndSettlementTables do
  use Ecto.Migration

  def change do
    # COL-P9 — hardship/workout plans (FR-COL-014).
    create table(:col_workout_plans, primary_key: false) do
      add :id,               :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :case_id,          :uuid, null: false, references: :col_collection_cases, type: :uuid
      add :account_id,       :uuid, null: false, references: :cms_accounts, type: :uuid
      add :plan_type,        :string, size: 20, null: false
      # RESTRUCTURE | APR_REDUCTION | PAYMENT_HOLIDAY
      add :new_apr,          :decimal, precision: 5, scale: 2
      # APR_REDUCTION only
      add :holiday_months,   :smallint
      # PAYMENT_HOLIDAY only
      add :emi_tenor_months, :smallint
      # RESTRUCTURE only — approval-tracked; real EMI-schedule generation not
      # wired (see docs/col tracker) since it needs a registered plan_segments
      # plan_id, which is bank/logo configuration outside COL's scope.
      add :start_date,       :date, null: false
      add :end_date,         :date, null: false
      add :status,           :string, size: 20, null: false, default: "PENDING_APPROVAL"
      # PENDING_APPROVAL | APPROVED | REJECTED | ACTIVE | COMPLETED | CANCELLED
      add :reason,           :string, size: 200
      add :requested_by,     :string, size: 50, null: false
      add :approved_by,      :string, size: 50

      timestamps(type: :utc_datetime_usec)
    end

    create index(:col_workout_plans, [:account_id])
    create index(:col_workout_plans, [:status])

    # Settlement offers (FR-COL-015).
    create table(:col_settlement_offers, primary_key: false) do
      add :id,                 :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :case_id,            :uuid, null: false, references: :col_collection_cases, type: :uuid
      add :account_id,         :uuid, null: false, references: :cms_accounts, type: :uuid
      add :outstanding_amount, :decimal, precision: 18, scale: 2, null: false
      # Snapshot of outstanding at time of offer, for discount_percent calculation
      add :offer_amount,       :decimal, precision: 18, scale: 2, null: false
      add :discount_percent,   :decimal, precision: 5, scale: 2, null: false
      add :expiry_date,        :date, null: false
      add :status,             :string, size: 20, null: false, default: "PENDING_APPROVAL"
      # PENDING_APPROVAL | APPROVED | REJECTED | PAID | EXPIRED | CANCELLED
      add :requested_by,       :string, size: 50, null: false
      add :approved_by,        :string, size: 50
      add :paid_amount,        :decimal, precision: 18, scale: 2
      add :forgiven_amount,    :decimal, precision: 18, scale: 2
      add :paid_at,            :utc_datetime
      add :reference,          :string, size: 100

      timestamps(type: :utc_datetime_usec)
    end

    create index(:col_settlement_offers, [:account_id])
    create index(:col_settlement_offers, [:status])
  end
end
