defmodule VmuCore.Repo.Migrations.CreateCmsPrepaidLedgerEntries do
  @moduledoc """
  Way4 parity plan Phase 1 item 5 (Prepaid, P1). The stored-value ledger
  — LOAD rows carry their own `remaining_amount` (decremented in place
  as that specific load is consumed, never a separate mutated account
  balance) and `expiry_date` (per-load dormancy). SPEND rows record which
  LOAD rows they drew from via `consumed_from` (JSONB breakdown), so a
  reversal restores exactly the right loads instead of guessing.
  """

  use Ecto.Migration

  def change do
    create table(:cms_prepaid_ledger_entries, primary_key: false) do
      add :id,                 :binary_id, primary_key: true,
                                default: fragment("gen_random_uuid()")
      add :prepaid_account_id, references(:cms_prepaid_accounts,
                                  column: :prepaid_account_id, type: :binary_id),
                                null: false
      # LOAD | SPEND | FEE | EXPIRE | REFUND | ADJUSTMENT
      add :entry_type,         :string, size: 20, null: false
      add :amount,             :decimal, precision: 18, scale: 2, null: false
      # LOAD rows only — starts equal to amount, decremented as consumed.
      add :remaining_amount,   :decimal, precision: 18, scale: 2
      # LOAD rows only — per-load dormancy/expiry (FR-005).
      add :expiry_date,        :date
      # ACTIVE | EXPIRED — LOAD rows only.
      add :status,             :string, size: 20, default: "ACTIVE"
      # LOAD rows only — INTERNAL_TRANSFER | ADMIN_MANUAL |
      # EXTERNAL_BANK_TRANSFER | CASH_DEPOSIT.
      add :channel,            :string, size: 30
      add :external_reference, :string
      # SPEND rows only — [%{"load_entry_id" => ..., "amount" => ...}, ...]
      add :consumed_from,      {:array, :map}
      add :posted_by,          :string, null: false
      add :idempotency_key,    :string
      add :posting_date,       :date, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:cms_prepaid_ledger_entries, [:prepaid_account_id])
    create index(:cms_prepaid_ledger_entries, [:prepaid_account_id, :entry_type, :status],
      name: :cms_prepaid_ledger_active_loads_index)
    create unique_index(:cms_prepaid_ledger_entries, [:idempotency_key],
      where: "idempotency_key IS NOT NULL",
      name: :cms_prepaid_ledger_entries_idempotency_key_index)
    create unique_index(:cms_prepaid_ledger_entries, [:external_reference],
      where: "external_reference IS NOT NULL",
      name: :cms_prepaid_ledger_entries_external_reference_index)
  end
end
