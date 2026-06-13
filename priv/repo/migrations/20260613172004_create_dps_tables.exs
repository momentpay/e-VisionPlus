defmodule VmuCore.Repo.Migrations.CreateDpsTables do
  use Ecto.Migration

  def change do
    create table(:dps_disputes, primary_key: false) do
      add :dispute_id,        :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :account_id,        :uuid, null: false, references: :cms_accounts, type: :uuid
      add :ledger_entry_id,   :uuid  # original transaction being disputed
      add :transaction_date,  :date, null: false
      add :dispute_amount,    :decimal, precision: 18, scale: 2, null: false
      add :currency,          :string, size: 3, null: false, default: "AED"
      add :reason_code,       :string, size: 4, null: false   # Visa/MC reason code
      add :network,           :string, size: 2, null: false, default: "MC"  # MC | VI
      # State machine
      add :status,            :string, size: 30, null: false, default: "FILED"
      # FILED | RETRIEVAL_REQUESTED | CHARGEBACK_FILED | REPRESENTED |
      # PRE_ARB | ARBITRATION | CLOSED_WIN | CLOSED_LOSE | CANCELLED
      add :network_ref,       :string, size: 50   # network case reference
      add :provisional_credit_posted, :boolean, null: false, default: false
      # Deadline tracking (hard cutoffs — missing forfeits the case)
      add :chargeback_deadline,:date  # transaction_date + 120 days (Visa) / 120 days (MC)
      add :representment_deadline,:date
      add :pre_arb_deadline,  :date
      add :filed_at,          :naive_datetime
      add :closed_at,         :naive_datetime

      timestamps()
    end

    create index(:dps_disputes, [:account_id])
    create index(:dps_disputes, [:status])
    create index(:dps_disputes, [:chargeback_deadline])
  end
end
