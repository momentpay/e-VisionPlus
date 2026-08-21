defmodule VmuCore.Repo.Migrations.CreateWalletTables do
  @moduledoc """
  Way4 parity plan Phase 2, Digital Wallet Phase W1 (2026-07-28) —
  account/ledger foundation. See
  `docs/wallet/DIGITAL_WALLET_Module_Requirements.md`.

  `CMS.WalletAccount` mirrors `CMS.DebitAccount`'s shape (balance-based,
  own block-history/non-monetary-event tables), NOT `CMS.Account`'s
  credit-shaped columns — a design correction from the requirements
  doc's original `account_type: "WALLET"` recommendation, made during
  implementation: a wallet has no credit line, it's stored value,
  structurally identical to what Prepaid already is in this codebase.

  `cms_wallet_products` is the new grouping concept (multi-currency
  composition, per the requirements doc's §4 finding from wallet-app's
  own real design) — one product may hold N single-currency
  `cms_wallet_accounts` rows.
  """

  use Ecto.Migration

  def change do
    create table(:cms_wallet_products, primary_key: false) do
      add :wallet_product_id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :customer_id, :binary_id, null: false
      add :name, :string, size: 100, null: false
      add :status, :string, size: 20, null: false, default: "ACTIVE"

      timestamps(type: :utc_datetime)
    end

    create index(:cms_wallet_products, [:customer_id])

    create table(:cms_wallet_accounts, primary_key: false) do
      add :wallet_account_id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :wallet_product_id, references(:cms_wallet_products,
            type: :binary_id, column: :wallet_product_id, on_delete: :restrict), null: false
      add :customer_id, :binary_id, null: false
      add :sys_id, :string, null: false
      add :bank_id, :string, null: false
      add :logo_id, :string, null: false
      add :block_id, :string, null: false

      add :available_balance, :decimal, null: false, default: 0
      add :currency, :string, size: 3, null: false, default: "AED"
      add :status, :string, size: 20, null: false, default: "ACTIVE"
      add :opened_at, :date, null: false
      add :closed_at, :date

      add :block_code, :string, size: 2
      add :block_reason, :string, size: 200
      add :blocked_at, :naive_datetime
      add :velocity_limits, :map, default: %{}
      add :kyc_status, :string, size: 20, default: "PENDING"
      add :kyc_verified_at, :naive_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:cms_wallet_accounts, [:wallet_product_id])
    create index(:cms_wallet_accounts, [:customer_id])
    # One currency per product, matching wallet-app's own real
    # WalletProduct/CurrencyConfig design (exactly one config per
    # currency) — confirmed in the Digital Wallet requirements doc §2.
    create unique_index(:cms_wallet_accounts, [:wallet_product_id, :currency])

    create table(:cms_wallet_fundings, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :wallet_account_id, references(:cms_wallet_accounts,
            type: :binary_id, column: :wallet_account_id, on_delete: :restrict), null: false
      add :amount, :decimal, null: false
      add :channel, :string, size: 30, null: false
      add :external_reference, :string, size: 100
      add :posted_by, :string, null: false
      add :ledger_entry_id, :binary_id

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:cms_wallet_fundings, [:wallet_account_id])
    create unique_index(:cms_wallet_fundings, [:external_reference],
      name: :cms_wallet_fundings_external_reference_index)

    create table(:cms_wallet_block_history, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :wallet_account_id, references(:cms_wallet_accounts,
            type: :binary_id, column: :wallet_account_id, on_delete: :restrict), null: false
      add :block_code, :string, size: 2
      add :action, :string, size: 10, null: false
      add :reason_code, :string, size: 40, null: false
      add :reason_text, :string, size: 200
      add :operator_id, :binary_id, null: false
      add :operator_role, :string, size: 20, null: false, default: "AGENT"
      add :applied_at, :naive_datetime, null: false, default: fragment("NOW()")
    end

    create index(:cms_wallet_block_history, [:wallet_account_id, :applied_at],
      name: :cms_wallet_block_history_account_idx)

    create table(:cms_wallet_non_monetary_events, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :wallet_account_id, references(:cms_wallet_accounts,
            type: :binary_id, column: :wallet_account_id, on_delete: :restrict), null: false
      add :event_type, :string, size: 30, null: false
      add :old_value, :map
      add :new_value, :map
      add :reason, :string, size: 255
      add :reference_id, :string, size: 50
      add :operator_id, :binary_id, null: false
      add :operator_role, :string, size: 20, default: "AGENT"
      add :applied_at, :naive_datetime, null: false

      timestamps(updated_at: false)
    end

    create index(:cms_wallet_non_monetary_events, [:wallet_account_id, :applied_at],
      name: :cms_wallet_nme_account_time_idx)
  end
end
