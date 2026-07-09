defmodule VmuCore.Repo.Migrations.CreateDpsDisputeEvidence do
  use Ecto.Migration

  def change do
    create table(:dps_dispute_evidence, primary_key: false) do
      add :evidence_id,  :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :dispute_id,   :uuid, null: false, references: :dps_disputes, type: :uuid
      add :backend,      :string, size: 20, null: false
      add :storage_ref,  :string, size: 255
      add :filename,     :string, size: 255, null: false
      add :content_type, :string, size: 100
      add :size_bytes,   :integer, null: false
      add :data,         :binary
      add :uploaded_by,  :string, size: 40
      add :uploaded_at,  :naive_datetime, null: false
    end

    create index(:dps_dispute_evidence, [:dispute_id])
  end
end
