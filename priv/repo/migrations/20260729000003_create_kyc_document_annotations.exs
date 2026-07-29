defmodule VmuCore.Repo.Migrations.CreateKycDocumentAnnotations do
  use Ecto.Migration

  def change do
    create table(:kyc_document_annotations, primary_key: false) do
      add :annotation_id, :binary_id, primary_key: true
      add :document_id, references(:kyc_documents, column: :document_id, type: :binary_id), null: false
      add :type, :string, null: false
      add :content, :text
      add :created_by, :binary_id

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:kyc_document_annotations, [:document_id])
  end
end
