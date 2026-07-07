defmodule VmuCore.Repo.Migrations.CreateCmsPaymentsAndAutopay do
  use Ecto.Migration

  # CMS-G2 (docs/cms/CMS_Gap_Implementation_Tracker.md):
  # - cms_payments: the payment register. Persists the bucket-level
  #   distribution breakdown so a bounced payment can be reversed EXACTLY
  #   (G2.1) and unmatched receipts can park in suspense (G2.3).
  # - cms_autopay_mandates: standing payment instructions (G2.2).
  def change do
    create table(:cms_payments, primary_key: false) do
      add :payment_id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :account_id, :uuid   # nil while in SUSPENSE (unmatched receipt)
      add :reference,  :string, size: 64, null: false   # external unique ref
      add :amount,     :decimal, precision: 18, scale: 2, null: false
      add :allocated,  :decimal, precision: 18, scale: 2
      add :remainder,  :decimal, precision: 18, scale: 2
      add :channel,    :string, size: 20, null: false
      add :status,     :string, size: 12, null: false, default: "POSTED"
      # POSTED | REVERSED | SUSPENSE
      add :postings,   :map, null: false, default: %{}
      # bucket_field => amount — the exact distribution, for exact reversal
      add :note,            :string, size: 255
      add :reversal_reason, :string, size: 100
      add :reversed_at,     :utc_datetime

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cms_payments, [:reference])
    create index(:cms_payments, [:account_id, :inserted_at])
    create index(:cms_payments, [:status], where: "status = 'SUSPENSE'")

    create table(:cms_autopay_mandates, primary_key: false) do
      add :mandate_id,        :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :account_id,        :uuid, null: false
      add :mandate_type,      :string, size: 8, null: false  # MIN_DUE | FULL | FIXED
      add :fixed_amount,      :decimal, precision: 18, scale: 2
      add :funding_reference, :string, size: 64  # bank direct-debit mandate ref
      add :active,            :boolean, null: false, default: true
      add :cancelled_at,      :utc_datetime

      timestamps(type: :utc_datetime_usec)
    end

    # One ACTIVE mandate per account
    create unique_index(:cms_autopay_mandates, [:account_id], where: "active = true")
  end
end
