defmodule VmuCore.Repo.Migrations.AddSingleTxnMaxToLogoParameters do
  use Ecto.Migration

  def change do
    alter table(:logo_parameters) do
      add :single_txn_max, :decimal, precision: 15, scale: 2
      add :daily_txn_max_count, :integer
      add :daily_txn_max_amount, :decimal, precision: 15, scale: 2
    end
  end
end
