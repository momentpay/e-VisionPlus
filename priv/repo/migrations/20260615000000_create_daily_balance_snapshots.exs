defmodule VmuCore.Repo.Migrations.CreateDailyBalanceSnapshots do
  use Ecto.Migration

  def change do
    # Add existing_monthly_payments to cdm_credit_applications for DSR check (G9)
    alter table(:cdm_credit_applications) do
      add_if_not_exists :existing_monthly_payments, :decimal, precision: 18, scale: 2, default: "0"
    end

    # Daily balance snapshots for true ADB interest calculation (G10)
    create table(:cms_daily_balance_snapshots) do
      add :account_id,       :binary_id, null: false
      add :snapshot_date,    :date, null: false
      add :retail_balance,   :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :cash_balance,     :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :fee_balance,      :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :accrued_interest, :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :open_to_buy,      :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :inserted_at,      :utc_datetime, null: false
    end

    create unique_index(:cms_daily_balance_snapshots, [:account_id, :snapshot_date])
    create index(:cms_daily_balance_snapshots, [:snapshot_date])
  end
end
