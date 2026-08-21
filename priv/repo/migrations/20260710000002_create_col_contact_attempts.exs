defmodule VmuCore.Repo.Migrations.CreateColContactAttempts do
  use Ecto.Migration

  def change do
    # COL-P2 — FR-COL-005 contact history. Append-only log of every collection
    # contact attempt (automated dunning dispatch or a manually logged call),
    # used to enforce col.contact_cap_* / col.contact_cooloff_hours.
    create table(:col_contact_attempts, primary_key: false) do
      add :id,           :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :account_id,   :uuid, null: false, references: :cms_accounts, type: :uuid
      add :channel,      :string, size: 20, null: false
      # sms | email | letter | courier | registered_mail | call
      add :dpd_bucket,   :smallint
      add :outcome,      :string, size: 30
      # right_party_contact | no_answer | promise_to_pay | dispute_raised | refused | ...
      add :notes,        :string, size: 500
      add :attempted_by, :string, size: 50, null: false
      # "SYSTEM_DUNNING" for automated dispatch, operator username for a manual call log

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:col_contact_attempts, [:account_id])
    create index(:col_contact_attempts, [:account_id, :channel, :inserted_at])
  end
end
