defmodule VmuCore.Repo.Migrations.CreateLmsTables do
  use Ecto.Migration

  def change do
    create table(:lms_schemes) do
      add :scheme_code,           :string, size: 5, null: false
      add :scheme_name,           :string, size: 100, null: false
      add :org_id,                :bigint, null: false
      add :currency,              :string, size: 3, null: false, default: "AED"
      add :points_expiry_months,  :integer
      add :warehouse_days,        :integer, null: false, default: 0
      add :cycle_to_date_include, :boolean, null: false, default: true
      add :status,                :string, size: 20, null: false, default: "ACTIVE"
      timestamps(type: :utc_datetime)
    end
    create unique_index(:lms_schemes, [:scheme_code])

    create table(:lms_groups) do
      add :scheme_id,         references(:lms_schemes, on_delete: :restrict), null: false
      add :group_code,        :string, size: 20, null: false
      add :group_type,        :string, size: 10, null: false     # DEFAULT | BONUS
      add :group_name,        :string, size: 100, null: false
      add :settlement_account, :string, size: 30
      add :status,            :string, size: 20, null: false, default: "ACTIVE"
      add :inserted_at,       :utc_datetime, null: false
    end
    create unique_index(:lms_groups, [:scheme_id, :group_code])
    create index(:lms_groups, [:scheme_id])

    # Join table: which merchants belong to which bonus group
    create table(:lms_group_merchants) do
      add :group_id,    references(:lms_groups, on_delete: :restrict), null: false
      add :merchant_id, references(:mbs_merchants, column: :merchant_id, type: :uuid,
                          on_delete: :restrict), null: false
      add :inserted_at, :utc_datetime, null: false
    end
    create unique_index(:lms_group_merchants, [:group_id, :merchant_id])

    create table(:lms_plans) do
      add :group_id,       references(:lms_groups, on_delete: :restrict), null: false
      add :plan_type,      :string, size: 15, null: false   # BASE | SUPPLEMENTARY | OVERRIDE
      add :effective_from, :date, null: false
      add :effective_to,   :date
      add :status,         :string, size: 20, null: false, default: "ACTIVE"
      add :inserted_at,    :utc_datetime, null: false
    end
    create index(:lms_plans, [:group_id])

    create table(:lms_rate_tiers) do
      add :plan_id,               references(:lms_plans, on_delete: :restrict), null: false
      add :tier_order,            :integer, null: false
      add :min_amount,            :decimal, precision: 18, scale: 2, null: false
      add :max_amount,            :decimal, precision: 18, scale: 2
      add :points_per_unit,       :decimal, precision: 10, scale: 4, null: false
      add :min_qualifying_amount, :decimal, precision: 18, scale: 2, null: false, default: "0.01"
      add :inserted_at,           :utc_datetime, null: false
    end
    create unique_index(:lms_rate_tiers, [:plan_id, :tier_order])

    # lms_accounts.ar_account_id references cms_accounts.account_id (UUID PK)
    create table(:lms_accounts) do
      add :lms_account_no,    :string, size: 30, null: false
      add :ar_account_id,     references(:cms_accounts, column: :account_id, type: :uuid,
                                on_delete: :restrict), null: false
      add :scheme_id,         references(:lms_schemes, on_delete: :restrict), null: false
      add :enrollment_date,   :date, null: false
      add :enrollment_method, :string, size: 10, null: false   # AUTO | MANUAL
      add :points_balance,    :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :open_to_redeem,    :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :lifetime_earned,   :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :lifetime_redeemed, :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :status,            :string, size: 20, null: false, default: "ACTIVE"
      timestamps(type: :utc_datetime)
    end
    create unique_index(:lms_accounts, [:lms_account_no])
    create unique_index(:lms_accounts, [:ar_account_id, :scheme_id])
    create index(:lms_accounts, [:ar_account_id])

    create table(:lms_points_ledger) do
      add :lms_account_id,      references(:lms_accounts, on_delete: :restrict), null: false
      add :transaction_type,    :string, size: 20, null: false
        # BASIC_EARNED | BONUS_EARNED | REDEEMED | ADJUSTMENT | EXPIRED
      add :points_amount,       :decimal, precision: 18, scale: 2, null: false
      add :monetary_equiv,      :decimal, precision: 18, scale: 2, null: false
      add :transaction_date,    :date, null: false
      add :posting_date,        :date, null: false
      add :expiry_date,         :date
      add :warehouse_state,     :string, size: 10, null: false, default: "ACTIVE"
        # WAREHOUSE | ACTIVE | HISTORY
      add :plan_id,             references(:lms_plans, on_delete: :nilify_all)
      add :group_id,            references(:lms_groups, on_delete: :nilify_all)
      add :scheme_id,           references(:lms_schemes, on_delete: :restrict), null: false
      add :merchant_id,         references(:mbs_merchants, column: :merchant_id, type: :uuid,
                                  on_delete: :nilify_all)
      add :source_clearing_id,  :bigint
      add :idempotency_key,     :string, size: 64
      add :batch_date,          :date
      add :settled_at,          :utc_datetime
      add :statemented_at,      :utc_datetime
      add :inserted_at,         :utc_datetime, null: false
    end
    create unique_index(:lms_points_ledger, [:idempotency_key])
    create index(:lms_points_ledger, [:lms_account_id, :transaction_date])
    create index(:lms_points_ledger, [:warehouse_state, :posting_date])
    create index(:lms_points_ledger, [:expiry_date])

    create table(:lms_redemptions) do
      add :lms_account_id,      references(:lms_accounts, on_delete: :restrict), null: false
      add :redemption_type,     :string, size: 20, null: false   # ONLINE | THIRD_PARTY | AUTO_DISBURSEMENT
      add :points_redeemed,     :decimal, precision: 18, scale: 2, null: false
      add :monetary_value,      :decimal, precision: 18, scale: 2, null: false
      add :disbursement_method, :string, size: 15    # CHEQUE | CREDIT | VOUCHER
      add :disbursement_date,   :date
      add :third_party_ref,     :string, size: 50
      add :status,              :string, size: 20, null: false, default: "PENDING"
      add :idempotency_key,     :string, size: 64
      add :inserted_at,         :utc_datetime, null: false
    end
    create unique_index(:lms_redemptions, [:idempotency_key])
    create index(:lms_redemptions, [:lms_account_id])

    create table(:lms_merchant_settlement) do
      add :merchant_id,            references(:mbs_merchants, column: :merchant_id, type: :uuid,
                                     on_delete: :restrict), null: false
      add :group_id,               references(:lms_groups, on_delete: :restrict), null: false
      add :settlement_period_from, :date, null: false
      add :settlement_period_to,   :date, null: false
      add :total_bonus_points,     :decimal, precision: 18, scale: 2, null: false
      add :charge_rate_pct,        :decimal, precision: 6, scale: 4, null: false
      add :settlement_amount,      :decimal, precision: 18, scale: 2, null: false
      add :settlement_method,      :string, size: 15, null: false   # DIRECT_DEBIT | INVOICE | BOTH
      add :status,                 :string, size: 20, null: false, default: "PENDING"
      add :gl_entry_id,            :bigint
      add :inserted_at,            :utc_datetime, null: false
    end
    create index(:lms_merchant_settlement, [:merchant_id, :settlement_period_from])
    create index(:lms_merchant_settlement, [:group_id])
  end
end
