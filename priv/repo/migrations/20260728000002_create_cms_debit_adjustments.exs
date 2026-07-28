defmodule VmuCore.Repo.Migrations.CreateCmsDebitAdjustments do
  @moduledoc """
  Card Products UX Parity Phase 1c (2026-07-28) — Debit's first manual
  balance-correction capability. Debit has always had Fund (increase) but
  no way to correct a funding error or post a goodwill/dispute credit
  without going through Fund again (which has no reversal). Mirrors
  `CMS.TempLimit`'s 4-eyes shape (operator_id/supervisor_id as usernames,
  DB-level "must differ" not enforced here — same convention, checked in
  the schema's changeset), not Credit's `FinancialAdjustment` (which has
  no persisted table of its own, just a GL narrative) — Debit needs a
  real queryable record since this is a genuinely new capability, not an
  established one just adding a table in hindsight.

  Direction is real banking terminology for a deposit/asset account (the
  opposite polarity from Credit's card-side "CREDIT reduces balance"):
  CREDIT increases available_balance (e.g. correcting an under-funding),
  DEBIT decreases it (e.g. reversing an over-funding or posting a
  goodwill charge-back).
  """

  use Ecto.Migration

  def change do
    create table(:cms_debit_adjustments, primary_key: false) do
      add :id,               :binary_id, primary_key: true,
                              default: fragment("gen_random_uuid()")
      add :debit_account_id, references(:cms_debit_accounts,
                                column: :debit_account_id, type: :binary_id),
                              null: false
      # CREDIT increases available_balance, DEBIT decreases it
      add :direction,        :string, size: 10, null: false
      add :amount,           :decimal, precision: 18, scale: 2, null: false
      add :reason,           :string, size: 100, null: false
      add :reference_id,     :string, null: false
      add :operator_id,      :string, null: false
      add :supervisor_id,    :string, null: false
      add :ledger_entry_id,  :binary_id

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:cms_debit_adjustments, [:debit_account_id])
  end
end
