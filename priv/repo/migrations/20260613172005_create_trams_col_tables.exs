defmodule VmuCore.Repo.Migrations.CreateTramsColTables do
  use Ecto.Migration

  def change do
    # Clearing records — one per inbound Mastercard IPM / Visa Base II record
    create table(:trams_clearing_records, primary_key: false) do
      add :clearing_id,       :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :account_id,        :uuid, references: :cms_accounts, type: :uuid
      add :network,           :string, size: 2, null: false  # MC | VI
      add :file_name,         :string, size: 100, null: false
      add :record_type,       :string, size: 4   # DE 24 / Base II record type
      add :pan_token,         :string, size: 64
      add :transaction_date,  :date
      add :settlement_date,   :date
      add :amount,            :decimal, precision: 18, scale: 2
      add :currency,          :string, size: 3
      add :interchange_fee,   :decimal, precision: 18, scale: 2, default: 0
      add :mcc,               :string, size: 4
      add :acquirer_id,       :string, size: 11
      add :rrn,               :string, size: 12  # retrieval reference number
      add :auth_code,         :string, size: 6
      add :match_status,      :string, size: 20, default: "UNMATCHED"
      # UNMATCHED | MATCHED | EXCEPTION | SETTLED
      add :matched_auth_id,   :uuid   # link to original authorization

      timestamps()
    end

    create index(:trams_clearing_records, [:account_id])
    create index(:trams_clearing_records, [:match_status])
    create index(:trams_clearing_records, [:rrn, :network])

    # COL collection cases
    create table(:col_collection_cases, primary_key: false) do
      add :case_id,           :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :account_id,        :uuid, null: false, references: :cms_accounts, type: :uuid
      add :dpd_bucket,        :smallint, null: false   # 30, 60, 90, 120
      add :outstanding_amount,:decimal, precision: 18, scale: 2, null: false
      add :status,            :string, size: 20, null: false, default: "OPEN"
      # OPEN | PROMISED | WORKOUT | AGENCY | WRITTEN_OFF | RECOVERED | CLOSED
      add :assigned_to,       :string, size: 50   # collector ID or agency code
      add :promise_date,      :date
      add :promise_amount,    :decimal, precision: 18, scale: 2
      add :workout_plan_id,   :uuid
      add :write_off_date,    :date
      add :write_off_amount,  :decimal, precision: 18, scale: 2

      timestamps()
    end

    create index(:col_collection_cases, [:account_id])
    create index(:col_collection_cases, [:dpd_bucket, :status])
  end
end
