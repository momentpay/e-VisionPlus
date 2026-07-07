defmodule VmuCore.Repo.Migrations.AddCurrencyToBalanceBuckets do
  @moduledoc """
  Sprint 4B: Add `currency` column to cms_balance_buckets.

  Defaults to "AED" for all existing rows. When a card posts a foreign-currency
  transaction, the converted AED amount goes into the existing bucket while the
  original currency and amount are recorded on the ledger entry (cms_ledger_entries
  already has a `currency` column).

  A future phase can split buckets per-currency if regulatory requirements demand it;
  for now this column marks the functional currency of the account.
  """

  use Ecto.Migration

  def change do
    alter table(:cms_balance_buckets) do
      add :currency, :string, size: 3, null: false, default: "AED"
    end

    create index(:cms_balance_buckets, [:account_id, :currency],
      name: :cms_balance_buckets_currency_idx)
  end
end
