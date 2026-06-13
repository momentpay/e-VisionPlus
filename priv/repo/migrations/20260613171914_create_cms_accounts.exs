defmodule VmuCore.Repo.Migrations.CreateCmsAccounts do
  use Ecto.Migration

  def change do
    create table(:cms_accounts, primary_key: false) do
      add :account_id,          :uuid,          primary_key: true, default: fragment("gen_random_uuid()")
      add :customer_id,         :uuid,          null: false, references: :cms_customers, type: :uuid
      add :sys_id,              :string, size: 4,  null: false
      add :bank_id,             :string, size: 4,  null: false
      add :logo_id,             :string, size: 4,  null: false
      add :block_id,            :string, size: 4,  null: false
      # Card identity — raw PAN is never stored
      add :pan_token,           :string, size: 64, null: false
      add :last_four,           :string, size: 4,  null: false
      add :expiry_date,         :string, size: 4,  null: false  # MMYY
      # Credit parameters (VisionPlus core)
      add :credit_limit,        :decimal, precision: 18, scale: 2, null: false, default: 0
      add :open_to_buy,         :decimal, precision: 18, scale: 2, null: false, default: 0
      add :cycle_code,          :smallint, null: false, default: 1  # billing day 1-31
      # Account status
      add :account_status,      :string, size: 20, null: false, default: "ACTIVE"
      # Delinquency DPD buckets: 0, 30, 60, 90, 120+
      add :delinquency_bucket,  :smallint, null: false, default: 0
      # Velocity matrix (40 parameters: channel × frequency × dimension) stored as JSONB
      add :velocity_limits,     :map, null: false, default: fragment("'{}'::jsonb")
      add :campaign_code,       :string, size: 20
      # Dates
      add :open_date,           :date, null: false, default: fragment("CURRENT_DATE")
      add :close_date,          :date
      add :next_statement_date, :date
      add :last_payment_date,   :date

      timestamps()
    end

    create unique_index(:cms_accounts, [:pan_token])
    create index(:cms_accounts, [:customer_id])
    create index(:cms_accounts, [:sys_id, :bank_id, :logo_id])

    # -------------------------------------------------------------------------

    create table(:cms_balance_buckets, primary_key: false) do
      add :bucket_id,         :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :account_id,        :uuid, null: false, references: :cms_accounts, type: :uuid
      # VisionPlus standard balance buckets
      add :retail_balance,    :decimal, precision: 18, scale: 2, null: false, default: 0
      add :cash_balance,      :decimal, precision: 18, scale: 2, null: false, default: 0
      add :accrued_interest,  :decimal, precision: 18, scale: 2, null: false, default: 0
      add :unpaid_fees,       :decimal, precision: 18, scale: 2, null: false, default: 0
      add :disputed_amount,   :decimal, precision: 18, scale: 2, null: false, default: 0
      # Statement snapshot
      add :statement_balance, :decimal, precision: 18, scale: 2, null: false, default: 0
      add :minimum_payment,   :decimal, precision: 18, scale: 2, null: false, default: 0
      add :balance_date,      :date,    null: false, default: fragment("CURRENT_DATE")

      timestamps()
    end

    create unique_index(:cms_balance_buckets, [:account_id, :balance_date])

    # -------------------------------------------------------------------------

    create table(:stip_thresholds, primary_key: false) do
      add :sys_id,            :string, size: 4,  null: false
      add :logo_id,           :string, size: 4,  null: false
      add :max_amount,        :decimal, precision: 18, scale: 2, null: false
      add :max_cumulative,    :decimal, precision: 18, scale: 2, null: false
      add :allowed_mcc_groups, {:array, :text}  # NULL = all MCCs allowed

      add :inserted_at, :naive_datetime, null: false, default: fragment("NOW()")
    end

    create constraint(:stip_thresholds, :stip_thresholds_pkey,
      check: "sys_id IS NOT NULL AND logo_id IS NOT NULL")
    execute "ALTER TABLE stip_thresholds ADD PRIMARY KEY (sys_id, logo_id)",
            "ALTER TABLE stip_thresholds DROP CONSTRAINT stip_thresholds_pkey"
  end
end
