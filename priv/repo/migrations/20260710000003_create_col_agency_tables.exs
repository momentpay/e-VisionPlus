defmodule VmuCore.Repo.Migrations.CreateColAgencyTables do
  use Ecto.Migration

  def change do
    # COL-P4 — agency placement lifecycle (FR-COL-018/019).
    create table(:col_agency_placements, primary_key: false) do
      add :id,             :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :case_id,        :uuid, null: false, references: :col_collection_cases, type: :uuid
      add :account_id,     :uuid, null: false, references: :cms_accounts, type: :uuid
      add :agency_code,    :string, size: 50, null: false
      add :status,         :string, size: 20, null: false, default: "PLACED"
      # PLACED | RECALLED | CLOSED
      add :placed_amount,  :decimal, precision: 18, scale: 2, null: false
      add :placed_at,      :utc_datetime, null: false
      add :recalled_at,    :utc_datetime
      add :recall_reason,  :string, size: 200

      timestamps(type: :utc_datetime_usec)
    end

    create index(:col_agency_placements, [:account_id])
    create index(:col_agency_placements, [:agency_code, :status])

    # Activity/payment file lines ingested from an agency, one row per line.
    create table(:col_agency_activity, primary_key: false) do
      add :id,                :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :placement_id,      :uuid, null: false, references: :col_agency_placements, type: :uuid
      add :activity_type,     :string, size: 20, null: false
      # PAYMENT | CONTACT | PROMISE | SKIP_TRACE | DISPUTE | RECALL_REQUEST
      add :amount,            :decimal, precision: 18, scale: 2
      add :commission_amount, :decimal, precision: 18, scale: 2
      add :activity_date,     :date
      add :raw_line,          :map, default: %{}
      add :status,            :string, size: 20, null: false, default: "RECEIVED"
      # RECEIVED | APPLIED | REJECTED
      add :reject_reason,     :string, size: 200

      timestamps(type: :utc_datetime_usec)
    end

    create index(:col_agency_activity, [:placement_id])
    create index(:col_agency_activity, [:activity_type, :status])
  end
end
