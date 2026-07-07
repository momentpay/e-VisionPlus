defmodule VmuCore.Repo.Migrations.AddCashAprToBlockParameters do
  @moduledoc """
  Sprint 2D: Add cash_apr_percentage to block_parameters.

  Cash advances carry a separate, typically higher APR than retail purchases.
  Previously the BLOCK level only overrode a single `apr_percentage` applied
  to both retail and cash balances. This column allows product-level cash APR
  overrides that cascade correctly through:

      Block.cash_apr_percentage → Logo.cash_apr → Logo.purchase_apr (fallback)
  """

  use Ecto.Migration

  def change do
    alter table(:block_parameters) do
      add :cash_apr_percentage, :decimal, precision: 7, scale: 4
    end
  end
end
