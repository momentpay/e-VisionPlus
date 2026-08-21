defmodule VmuCore.Repo.Migrations.CreateCmsPrepaidAdjustments do
  @moduledoc """
  Card Products UX Parity Phase 2c (2026-07-28) — Prepaid's first manual
  balance-correction capability, mirroring `cms_debit_adjustments`
  exactly. Direction is real banking terminology for a stored-value
  account: CREDIT increases the balance (inserts a new spendable
  ADJUSTMENT ledger row, same shape as a LOAD), DEBIT decreases it
  (consumes ACTIVE loads FIFO via `PrepaidLedger.consume_active_loads/2`
  — the exact same consumption `spend/3` uses).
  """

  use Ecto.Migration

  def change do
    create table(:cms_prepaid_adjustments, primary_key: false) do
      add :id,                 :binary_id, primary_key: true,
                                default: fragment("gen_random_uuid()")
      add :prepaid_account_id, references(:cms_prepaid_accounts,
                                  column: :prepaid_account_id, type: :binary_id),
                                null: false
      # CREDIT increases the balance, DEBIT decreases it
      add :direction,          :string, size: 10, null: false
      add :amount,             :decimal, precision: 18, scale: 2, null: false
      add :reason,             :string, size: 100, null: false
      add :reference_id,       :string, null: false
      add :operator_id,        :string, null: false
      add :supervisor_id,      :string, null: false
      add :ledger_entry_id,    :binary_id

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:cms_prepaid_adjustments, [:prepaid_account_id])
  end
end
