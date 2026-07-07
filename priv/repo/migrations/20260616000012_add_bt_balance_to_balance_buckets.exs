defmodule VmuCore.Repo.Migrations.AddBtBalanceToBalanceBuckets do
  @moduledoc """
  Sprint 3C: Add balance transfer balance pool to cms_balance_buckets.

  Balance transfer (BT) balances are tracked separately from retail and cash
  so that the correct APR (promo or standard) and payment priority can be
  applied independently during billing.
  """

  use Ecto.Migration

  def change do
    alter table(:cms_balance_buckets) do
      add :bt_balance, :decimal, precision: 18, scale: 2, default: 0
    end
  end
end
