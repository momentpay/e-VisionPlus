defmodule VmuCore.Repo.Migrations.CreateCtaTables do
  use Ecto.Migration

  def change do
    # Card stock — one row per physical card batch in vault/branch inventory
    create table(:cta_card_stock, primary_key: false) do
      add :stock_id,        :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :sys_id,          :string, size: 4, null: false
      add :bank_id,         :string, size: 4, null: false
      add :logo_id,         :string, size: 4, null: false
      add :bin_prefix,      :string, size: 6, null: false
      add :batch_number,    :string, size: 30, null: false
      add :quantity_ordered,:integer, null: false
      add :quantity_on_hand,:integer, null: false, default: 0
      add :quantity_issued, :integer, null: false, default: 0
      add :quantity_damaged,:integer, null: false, default: 0
      add :bureau_name,     :string, size: 100  # G+D, Thales, CPI etc.
      add :order_date,      :date, null: false
      add :delivery_date,   :date
      add :expiry_year_month,:string, size: 4  # MMYY stamped on cards
      add :status,          :string, size: 20, null: false, default: "ORDERED"
      # ORDERED | DELIVERED | ACTIVE | DEPLETED | RECALLED

      timestamps()
    end

    create index(:cta_card_stock, [:sys_id, :bank_id, :logo_id])
    create index(:cta_card_stock, [:status])
    create unique_index(:cta_card_stock, [:batch_number])

    # Card embossing orders — one row per card personalisation request to bureau
    create table(:cta_embossing_orders, primary_key: false) do
      add :order_id,        :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :account_id,      :uuid, null: false, references: :cms_accounts, type: :uuid
      add :stock_id,        :uuid, null: false, references: :cta_card_stock, type: :uuid
      add :pan_token,       :string, size: 64, null: false
      add :cardholder_name, :string, size: 26, null: false  # max 26 chars on embossed line
      add :expiry_date,     :string, size: 4,  null: false  # MMYY
      add :order_status,    :string, size: 20, null: false, default: "PENDING"
      # PENDING | SUBMITTED | PRINTED | DISPATCHED | DELIVERED | RETURNED | CANCELLED
      add :bureau_ref,      :string, size: 50   # bureau's tracking reference
      add :submitted_at,    :naive_datetime
      add :dispatched_at,   :naive_datetime
      add :delivered_at,    :naive_datetime

      timestamps()
    end

    create index(:cta_embossing_orders, [:account_id])
    create index(:cta_embossing_orders, [:order_status])
  end
end
