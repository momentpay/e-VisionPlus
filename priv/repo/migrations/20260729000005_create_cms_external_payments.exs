defmodule VmuCore.Repo.Migrations.CreateCmsExternalPayments do
  @moduledoc """
  Digital Wallet Phase W6 (2026-07-29) — wallet-out payment to an external
  bank account, covering both A2A (W011) and Instant Payments (W012); same
  domain shape, distinguished by `rail_type`. The actual rail vendor is
  still an external decision — this table + the pluggable `RailProvider`
  behaviour let the domain model, risk gate, and external API contract
  exist now, with a `Stub` adapter until a real one is configured.
  """

  use Ecto.Migration

  def change do
    create table(:cms_external_payments, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :wallet_account_id, references(:cms_wallet_accounts,
            type: :binary_id, column: :wallet_account_id, on_delete: :restrict), null: false
      add :customer_id, :binary_id, null: false
      add :rail_type, :string, size: 20, null: false
      add :rail_provider, :string, size: 255, null: false
      add :amount, :decimal, null: false
      add :currency, :string, size: 3, null: false
      add :destination, :map, null: false, default: %{}
      add :status, :string, size: 20, null: false, default: "initiated"
      add :risk_decision, :map
      add :ledger_entry_id, :binary_id
      add :external_reference, :string, size: 100
      add :failure_reason, :string, size: 255
      add :initiated_by, :string, null: false
      add :submitted_at, :utc_datetime
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:cms_external_payments, [:wallet_account_id])
    create index(:cms_external_payments, [:customer_id])
    create index(:cms_external_payments, [:status])
  end
end
