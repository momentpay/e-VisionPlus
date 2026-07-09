defmodule VmuCore.Repo.Migrations.AddCaseManagementToDps do
  use Ecto.Migration

  def change do
    alter table(:dps_disputes) do
      add :assigned_to, :string, size: 40
    end

    create table(:dps_dispute_notes, primary_key: false) do
      add :note_id,    :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :dispute_id, :uuid, null: false, references: :dps_disputes, type: :uuid
      add :author,     :string, size: 40, null: false
      add :note,       :text, null: false
      add :created_at, :naive_datetime, null: false
    end

    create index(:dps_dispute_notes, [:dispute_id])
  end
end
