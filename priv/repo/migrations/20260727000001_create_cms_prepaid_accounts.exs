defmodule VmuCore.Repo.Migrations.CreateCmsPrepaidAccounts do
  @moduledoc """
  Way4 parity plan Phase 1 item 5 (Prepaid — closed-loop stored value
  card, P1). Deliberately no `available_balance` field, unlike
  `cms_debit_accounts` — Prepaid's balance is derived from
  `cms_prepaid_ledger_entries` (sum of active, unexpired LOAD rows), not
  a mutated counter, because value expires per-load (dormancy) and a
  flat counter can't represent "which portion is expired."
  """

  use Ecto.Migration

  def change do
    create table(:cms_prepaid_accounts, primary_key: false) do
      add :prepaid_account_id, :binary_id, primary_key: true,
                                default: fragment("gen_random_uuid()")
      add :customer_id,        :binary_id, null: false
      add :sys_id,              :string, null: false
      add :bank_id,             :string, null: false
      add :logo_id,             :string, null: false
      add :block_id,            :string, null: false

      add :currency,            :string, size: 3, null: false, default: "AED"
      add :status,              :string, size: 20, null: false, default: "ACTIVE"
      add :opened_at,           :date, null: false
      add :closed_at,           :date

      timestamps(type: :utc_datetime)
    end

    create index(:cms_prepaid_accounts, [:customer_id])
    create index(:cms_prepaid_accounts, [:sys_id, :bank_id, :logo_id, :block_id])
  end
end
