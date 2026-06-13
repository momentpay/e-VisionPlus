defmodule VmuCore.Repo.Migrations.CreateCmsLedgerAndVelocity do
  use Ecto.Migration

  def change do
    # -------------------------------------------------------------------------
    # Double-entry GL ledger — every debit/credit posted to an account lands here.
    # Idempotency key prevents duplicate postings on retry.
    # -------------------------------------------------------------------------
    create table(:cms_ledger_entries, primary_key: false) do
      add :entry_id,        :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :account_id,      :uuid, null: false, references: :cms_accounts, type: :uuid
      add :idempotency_key, :string, size: 128, null: false
      add :transaction_code,:string, size: 10,  null: false  # PURCHASE, CASH_ADV, INTEREST, FEE, PAYMENT, REVERSAL
      add :dr_amount,       :decimal, precision: 18, scale: 2, null: false, default: 0
      add :cr_amount,       :decimal, precision: 18, scale: 2, null: false, default: 0
      add :gl_account_dr,   :string, size: 20, null: false  # chart-of-accounts code
      add :gl_account_cr,   :string, size: 20, null: false
      add :currency,        :string, size: 3,  null: false, default: "AED"
      add :posting_date,    :date,   null: false
      add :value_date,      :date,   null: false
      add :narrative,       :string, size: 255
      add :source_ref,      :string, size: 64   # e.g. transaction_id, reversal_id

      timestamps()
    end

    create unique_index(:cms_ledger_entries, [:idempotency_key])
    create index(:cms_ledger_entries, [:account_id, :posting_date])
    create index(:cms_ledger_entries, [:transaction_code, :posting_date])

    # -------------------------------------------------------------------------
    # Extend block_parameters with 40-parameter velocity matrix columns.
    # Stored as JSONB for flexibility — validated at application layer.
    # -------------------------------------------------------------------------
    alter table(:block_parameters) do
      add :velocity_matrix,    :map,     default: fragment("'{}'::jsonb"), null: false
      add :allowed_channels,   {:array, :string}, default: fragment("ARRAY['POS','ATM','ECOM','CONTACTLESS']")
      add :allowed_currencies, {:array, :string}, default: fragment("ARRAY['AED']")
      add :mcc_blocked_list,   {:array, :string}, default: fragment("ARRAY[]::text[]")
      add :mcc_allowed_list,   {:array, :string}, default: fragment("ARRAY[]::text[]")
    end
  end
end
