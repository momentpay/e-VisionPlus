defmodule VmuCore.Repo.Migrations.CreateCmsDebitAccounts do
  @moduledoc """
  Way4 parity plan Phase 1 item 4 (Debit — real network-scheme card, D1).

  Deliberately a separate table, not a `cms_accounts` discriminator:
  `cms_accounts.credit_limit` is `NOT NULL` and every downstream
  calculation (OTB, delinquency bucketing, statement minimum-payment)
  assumes it's real — forcing a credit_limit to exist on a balance
  product (or making it nullable for everyone) reopens exactly the
  "field exists, nothing enforces it" bug class this session has hit
  repeatedly (LMS, DPS, HCS). A separate schema closes that whole risk
  class structurally: a debit account never has a `cms_accounts` row,
  so EOD interest/statement jobs (scoped to `cms_accounts`) can't
  accidentally touch it.
  """

  use Ecto.Migration

  def change do
    create table(:cms_debit_accounts, primary_key: false) do
      add :debit_account_id, :binary_id, primary_key: true,
                              default: fragment("gen_random_uuid()")
      add :customer_id,      :binary_id, null: false
      # Parameter cascade identity — same SYS/BANK/LOGO/BLOCK shape every
      # other product in this repo uses, so ParameterEngine/FAS routing
      # work unchanged against a debit account.
      add :sys_id,           :string, null: false
      add :bank_id,          :string, null: false
      add :logo_id,          :string, null: false
      add :block_id,         :string, null: false

      add :available_balance, :decimal, precision: 18, scale: 2, null: false, default: 0
      add :currency,          :string, size: 3, null: false, default: "AED"
      add :status,            :string, size: 20, null: false, default: "ACTIVE"
      add :opened_at,         :date, null: false
      add :closed_at,         :date

      timestamps(type: :utc_datetime)
    end

    create index(:cms_debit_accounts, [:customer_id])
    create index(:cms_debit_accounts, [:sys_id, :bank_id, :logo_id, :block_id])
  end
end
