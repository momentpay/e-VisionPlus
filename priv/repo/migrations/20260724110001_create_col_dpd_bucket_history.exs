defmodule VmuCore.Repo.Migrations.CreateColDpdBucketHistory do
  use Ecto.Migration

  def change do
    # FR-COL-025 — the missing foundation roll rate/cure rate MI needs:
    # AgeBucketsJob has always overwritten cms_accounts.delinquency_bucket
    # in place, with no trail behind it, so there was no way to answer
    # "of accounts that reached 30 DPD in March, what % rolled to 60 by
    # April" or "what % cured to 0." One row per real bucket CHANGE
    # (never per EOD run — most runs are a no-op for most accounts),
    # written by AgeBucketsJob at the same point it already detects
    # old_bucket != new_bucket.
    create table(:col_dpd_bucket_history, primary_key: false) do
      add :id,          :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :account_id,  :uuid, null: false, references: :cms_accounts, type: :uuid
      add :eod_date,    :date, null: false
      add :old_bucket,  :integer, null: false
      add :new_bucket,  :integer, null: false

      timestamps(updated_at: false)
    end

    create index(:col_dpd_bucket_history, [:account_id, :eod_date])
    create index(:col_dpd_bucket_history, [:new_bucket, :eod_date])
  end
end
