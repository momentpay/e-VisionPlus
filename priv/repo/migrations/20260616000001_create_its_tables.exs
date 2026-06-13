defmodule VmuCore.Repo.Migrations.CreateItsTables do
  use Ecto.Migration

  def change do
    # Extend dps_disputes with fields needed for ITS1 chargeback extraction
    alter table(:dps_disputes) do
      add_if_not_exists :submitted_at, :utc_datetime
      add_if_not_exists :arn,          :string, size: 24
      add_if_not_exists :card_number_token, :string, size: 64
    end

    create table(:its_copy_requests) do
      add :dispute_id,         references(:dps_disputes, on_delete: :nilify_all)
      add :account_id,         :binary_id, null: false
      add :card_number_token,  :string, size: 64, null: false
      add :transaction_date,   :date, null: false
      add :transaction_amount, :decimal, precision: 18, scale: 2, null: false
      add :currency,           :string, size: 3, null: false, default: "AED"
      add :merchant_name,      :string, size: 100
      add :merchant_id,        :string, size: 20
      add :acquirer_bin,       :string, size: 11
      add :network,            :string, size: 10, null: false
      add :arn,                :string, size: 24
      add :request_type,       :string, size: 20, null: false
      add :request_reason,     :string, size: 50
      add :status,             :string, size: 20, null: false, default: "PENDING"
      add :sent_at,            :utc_datetime
      add :fulfilled_at,       :utc_datetime
      add :response_reason,    :string, size: 100
      add :deadline_date,      :date
      add :its1_batch_date,    :date
      add :its2_batch_date,    :date
      add :idempotency_key,    :string, size: 64
      timestamps(type: :utc_datetime)
    end

    create unique_index(:its_copy_requests, [:idempotency_key])
    create index(:its_copy_requests, [:account_id, :status])
    create index(:its_copy_requests, [:dispute_id])
    create index(:its_copy_requests, [:its1_batch_date])

    create table(:its_fee_claims) do
      add :clearing_record_id,   references(:trams_clearing_records, on_delete: :restrict)
      add :network,              :string, size: 10, null: false
      add :claim_type,           :string, size: 20, null: false
      add :mcc,                  :string, size: 4
      add :interchange_category, :string, size: 20
      add :gross_amount,         :decimal, precision: 18, scale: 2, null: false
      add :interchange_rate,     :decimal, precision: 8, scale: 6, null: false
      add :interchange_amount,   :decimal, precision: 18, scale: 2, null: false
      add :scheme_fee_amount,    :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :net_interchange,      :decimal, precision: 18, scale: 2, null: false
      add :currency,             :string, size: 3, null: false, default: "AED"
      add :processing_date,      :date, null: false
      add :settlement_date,      :date
      add :status,               :string, size: 20, null: false, default: "PENDING"
      add :gl_entry_id,          :bigint
      add :idempotency_key,      :string, size: 64
      add :inserted_at,          :utc_datetime, null: false
    end

    create unique_index(:its_fee_claims, [:idempotency_key])
    create index(:its_fee_claims, [:clearing_record_id])
    create index(:its_fee_claims, [:settlement_date, :status])

    create table(:its_financial_adjustments) do
      add :network,              :string, size: 10, null: false
      add :adjustment_type,      :string, size: 30, null: false
      add :reference_no,         :string, size: 30, null: false
      add :original_clearing_id, references(:trams_clearing_records, on_delete: :nilify_all)
      add :original_txn_date,    :date
      add :adjustment_amount,    :decimal, precision: 18, scale: 2, null: false
      add :currency,             :string, size: 3, null: false, default: "AED"
      add :reason_code,          :string, size: 10
      add :reason_description,   :string, size: 200
      add :received_date,        :date, null: false
      add :applied_date,         :date
      add :status,               :string, size: 20, null: false, default: "RECEIVED"
      add :gl_entry_id,          :bigint
      timestamps(type: :utc_datetime)
    end

    create unique_index(:its_financial_adjustments, [:reference_no])
    create index(:its_financial_adjustments, [:network, :received_date])
    create index(:its_financial_adjustments, [:status])
  end
end
