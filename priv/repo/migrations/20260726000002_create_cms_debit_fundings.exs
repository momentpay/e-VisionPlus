defmodule VmuCore.Repo.Migrations.CreateCmsDebitFundings do
  @moduledoc """
  Way4 parity plan Phase 1 item 4 (Debit, D2 — funding/load transactions).

  External channels (`EXTERNAL_BANK_TRANSFER`/`CASH_DEPOSIT`) are modeled
  as real records with a channel tag + external_reference for future
  reconciliation, but with no live rail call — no bank-rail/cash-network
  integration exists in this codebase (confirmed before this decision,
  not assumed). Same "data model now, real integration later" pattern
  already shipped for Avenza's Prepaid `PrepaidLoad.channel`.
  """

  use Ecto.Migration

  def change do
    create table(:cms_debit_fundings, primary_key: false) do
      add :id,                 :binary_id, primary_key: true,
                                default: fragment("gen_random_uuid()")
      add :debit_account_id,   references(:cms_debit_accounts,
                                  column: :debit_account_id, type: :binary_id),
                                null: false
      add :amount,             :decimal, precision: 18, scale: 2, null: false
      # INTERNAL_TRANSFER | ADMIN_MANUAL | EXTERNAL_BANK_TRANSFER | CASH_DEPOSIT
      add :channel,            :string, size: 30, null: false
      add :external_reference, :string
      add :posted_by,          :string, null: false
      add :ledger_entry_id,    :binary_id

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:cms_debit_fundings, [:debit_account_id])
    create unique_index(:cms_debit_fundings, [:external_reference],
      where: "external_reference IS NOT NULL",
      name: :cms_debit_fundings_external_reference_index)
  end
end
