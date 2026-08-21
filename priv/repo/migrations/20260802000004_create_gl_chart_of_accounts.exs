defmodule VmuCore.Repo.Migrations.CreateGlChartOfAccounts do
  @moduledoc """
  GL Phase A1 — the Chart of Accounts as data.

  Replaces two conflicting hardcoded code sets:

    * `VmuCore.FAS.GL.CardAccountCodes` — 5 codes in a module docstring
      (1001/2001/4001/5001/9001), used by FAS, TRAMS, COL, ITS, CMS payment intake.
    * `VmuCore.CMS.InternalGlPoster` — a *different* 12-code set in its own
      docstring, used by CMS interest/fee/payment and all Debit/Prepaid/Wallet
      posting.

  Both write to `cms_ledger_entries`. Where they overlap they disagree — see
  `docs/gl/GL_Module_Design_and_Plan.md` §9. This table is the single
  reconciled registry both will be migrated onto in Phase C.

  Nothing reads this table yet (Phase A is build-only, wired to nothing).
  """
  use Ecto.Migration

  def change do
    create table(:gl_accounts, primary_key: false) do
      add :code,           :string, size: 10, primary_key: true
      add :name,           :string, null: false
      add :account_class,  :string, size: 20, null: false   # asset|liability|equity|revenue|expense
      add :normal_balance, :string, size: 6,  null: false   # debit|credit
      add :owner_module,   :string, size: 20, null: false   # vmu_fas|vmu_cms|vmu_col|…
      add :currency,       :string, size: 3                 # nil = multi-currency
      add :active,         :boolean, null: false, default: true
      add :description,    :text

      # Reconciliation bookkeeping — which legacy code set this came from, and
      # whether a live posting path still disagrees about its meaning. Phase C
      # clears these; they exist so the conflict is visible in data, not prose.
      add :legacy_conflict, :text

      timestamps(type: :utc_datetime)
    end

    create constraint(:gl_accounts, :gl_accounts_class_check,
             check: "account_class IN ('asset','liability','equity','revenue','expense')")

    create constraint(:gl_accounts, :gl_accounts_normal_balance_check,
             check: "normal_balance IN ('debit','credit')")

    # Asset/expense are debit-normal; liability/equity/revenue are credit-normal.
    # Enforced in the DB because a wrong normal_balance silently inverts every
    # balance and trial-balance figure derived from the account.
    create constraint(:gl_accounts, :gl_accounts_normal_balance_matches_class_check,
             check: """
             (account_class IN ('asset','expense')    AND normal_balance = 'debit')
             OR
             (account_class IN ('liability','equity','revenue') AND normal_balance = 'credit')
             """)

    create index(:gl_accounts, [:owner_module])
    create index(:gl_accounts, [:account_class])
    create index(:gl_accounts, [:active], where: "active = true", name: :gl_accounts_active_idx)
  end
end
