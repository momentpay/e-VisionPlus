defmodule VmuCore.Repo.Migrations.AddAccountTypeToCmsAccounts do
  @moduledoc """
  Real bug found live (2026-07-28, Card Products UX Parity Phase 3
  scoping) — `HCS.CompanyOnboarding.onboard_company/1` and
  `add_employee_card/3` have always passed `account_type:
  "CORPORATE_PARENT"`/`"EMPLOYEE_CARD"` into `CMS.Account.changeset/2`,
  but `:account_type` was never a schema field, so `Ecto.Changeset.cast/2`
  silently dropped it. Every HCS-sourced `cms_accounts` row has therefore
  been indistinguishable from a real revolving-credit account to
  `EodSchedulerJob`/`LockAccountsJob`, which sweep purely by
  `cycle_code`/`account_status` — meaning employee-card and
  corporate-parent facility rows have likely already been silently
  accruing interest and generating statements.

  Backfills existing rows to "CREDIT" via the column default (every
  pre-existing `cms_accounts` row genuinely is a Credit account — HCS
  accounts only exist from 2026-06-15 onward and this fixes them going
  forward from here).
  """

  use Ecto.Migration

  def change do
    alter table(:cms_accounts) do
      add :account_type, :string, size: 20, null: false, default: "CREDIT"
    end

    create index(:cms_accounts, [:account_type])
  end
end
