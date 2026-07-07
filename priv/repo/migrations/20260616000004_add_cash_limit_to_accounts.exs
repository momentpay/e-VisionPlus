defmodule VmuCore.Repo.Migrations.AddCashLimitToAccounts do
  @moduledoc """
  P1-C: Add cash sub-limit tracking to cms_accounts.

  VisionPlus requires a distinct cash advance sub-limit (typically 30% of the
  total credit limit) and a separate open-to-buy counter for cash transactions.
  Without this, the AccountStateCoordinator cannot enforce the cash limit during
  ATM/cash-advance authorisations.

  cash_limit      — maximum cash advance balance allowed (derived from logo.cash_limit_pct)
  cash_open_to_buy — remaining cash advance capacity at runtime
  """

  use Ecto.Migration

  def change do
    alter table(:cms_accounts) do
      add :cash_limit,       :decimal, precision: 18, scale: 2
      add :cash_open_to_buy, :decimal, precision: 18, scale: 2
    end

    # Index for EOD queries that need to find accounts by logo for cash limit recalculation
    create index(:cms_accounts, [:logo_id, :bank_id, :sys_id],
             name: :cms_accounts_logo_idx)
  end
end
