defmodule VmuCore.Repo.Migrations.CreateCdmMbsTables do
  use Ecto.Migration

  def change do
    # Credit applications — underwriting workflow
    create table(:cdm_credit_applications, primary_key: false) do
      add :application_id,  :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :customer_id,     :uuid, null: false, references: :cms_customers, type: :uuid
      add :sys_id,          :string, size: 4, null: false
      add :bank_id,         :string, size: 4, null: false
      add :logo_id,         :string, size: 4, null: false
      add :requested_limit, :decimal, precision: 18, scale: 2
      add :approved_limit,  :decimal, precision: 18, scale: 2
      add :monthly_income,  :decimal, precision: 18, scale: 2
      add :employment_type, :string, size: 20   # EMPLOYED | SELF_EMPLOYED | RETIRED | STUDENT
      add :bureau_score,    :integer
      add :bureau_ref,      :string, size: 50
      add :risk_tier,       :string, size: 10  # PRIME | NEAR_PRIME | SUBPRIME
      add :status,          :string, size: 20, null: false, default: "PENDING"
      # PENDING | BUREAU_PENDING | APPROVED | DECLINED | REFERRED | CANCELLED
      add :decline_reason,  :string, size: 100
      add :submitted_at,    :naive_datetime
      add :decided_at,      :naive_datetime

      timestamps()
    end

    create index(:cdm_credit_applications, [:customer_id])
    create index(:cdm_credit_applications, [:status])

    # MBS merchant hierarchy
    create table(:mbs_merchants, primary_key: false) do
      add :merchant_id,     :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :sys_id,          :string, size: 4, null: false
      add :bank_id,         :string, size: 4, null: false
      add :merchant_name,   :string, size: 100, null: false
      add :merchant_type,   :string, size: 20, null: false  # CHAIN | STANDALONE | VIRTUAL
      add :mcc,             :string, size: 4, null: false
      add :registration_no, :string, size: 50
      add :vat_no,          :string, size: 20
      add :settlement_bank, :string, size: 50
      add :settlement_iban, :string, size: 34
      add :mdr_template_id, :string, size: 20   # references settlement_core MDR template
      add :status,          :string, size: 20, null: false, default: "ACTIVE"

      timestamps()
    end

    create index(:mbs_merchants, [:sys_id, :bank_id])
    create index(:mbs_merchants, [:mcc])

    # MBS terminals
    create table(:mbs_terminals, primary_key: false) do
      add :terminal_id,     :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :merchant_id,     :uuid, null: false, references: :mbs_merchants, type: :uuid
      add :terminal_code,   :string, size: 8, null: false   # DE 41 terminal ID
      add :terminal_type,   :string, size: 10  # POS | MPOS | ATM | KIOSK | VIRTUAL
      add :serial_number,   :string, size: 30
      add :installed_at,    :date
      add :status,          :string, size: 20, null: false, default: "ACTIVE"

      timestamps()
    end

    create unique_index(:mbs_terminals, [:terminal_code])
    create index(:mbs_terminals, [:merchant_id])
  end
end
