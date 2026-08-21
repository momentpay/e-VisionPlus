defmodule VmuCore.Repo.Migrations.CreateWalletTransfers do
  @moduledoc """
  Digital Wallet Phase W2 (2026-07-28) — wallet-to-wallet transfer.
  `cms_wallet_transfers` is the single authoritative record of a
  transfer, inserted before either leg's balance movement so its own id
  can link the receiver's `cms_wallet_fundings` row back to it (via
  `external_reference`).
  """

  use Ecto.Migration

  def change do
    create table(:cms_wallet_transfers, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :from_wallet_account_id, references(:cms_wallet_accounts,
            type: :binary_id, column: :wallet_account_id, on_delete: :restrict), null: false
      add :to_wallet_account_id, references(:cms_wallet_accounts,
            type: :binary_id, column: :wallet_account_id, on_delete: :restrict), null: false
      add :amount, :decimal, null: false
      add :currency, :string, size: 3, null: false
      add :status, :string, size: 20, null: false, default: "COMPLETED"
      add :reason, :string, size: 255
      add :initiated_by, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:cms_wallet_transfers, [:from_wallet_account_id])
    create index(:cms_wallet_transfers, [:to_wallet_account_id])
  end
end
