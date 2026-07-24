defmodule VmuCore.Repo.Migrations.CreateColWriteoffRequests do
  use Ecto.Migration

  def change do
    # COL-P2 — maker-checker parking table for automatic write-off requests.
    # A row is created when EOD aging crosses the configured
    # col.writeoff_dpd_threshold; a human approver (role gated by
    # col.writeoff_approval_matrix) must approve before WriteOffProcessor
    # actually posts the write-off.
    create table(:col_writeoff_requests, primary_key: false) do
      add :id,               :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :account_id,       :uuid, null: false, references: :cms_accounts, type: :uuid
      add :case_id,          :uuid, references: :col_collection_cases, type: :uuid
      add :dpd_bucket,       :smallint, null: false
      add :write_off_amount, :decimal, precision: 18, scale: 2, null: false
      add :ifrs9_stage,      :string, size: 10
      add :reason,           :string, size: 200
      add :status,           :string, size: 20, null: false, default: "PENDING_APPROVAL"
      # PENDING_APPROVAL | APPROVED | REJECTED | POSTED
      add :requested_by,     :string, size: 50, null: false
      add :approved_by,      :string, size: 50
      add :posted_at,        :utc_datetime

      timestamps(type: :utc_datetime_usec)
    end

    create index(:col_writeoff_requests, [:account_id])
    create index(:col_writeoff_requests, [:status])
  end
end
