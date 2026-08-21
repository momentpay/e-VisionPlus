defmodule VmuCore.Repo.Migrations.CreateKycRequests do
  use Ecto.Migration

  def change do
    create table(:kyc_requests, primary_key: false) do
      add :request_id, :binary_id, primary_key: true
      add :application_number, :string, null: false
      add :kyc_method_id, references(:kyc_methods, column: :method_id, type: :binary_id), null: false
      add :method_version, :integer, null: false
      add :fields_snapshot, :map, null: false, default: %{}
      add :customer_id, references(:cms_customers, column: :customer_id, type: :binary_id), null: false
      add :product_type, :string, null: false
      add :arrangement_id, references(:cms_arrangements, column: :id, type: :binary_id)
      add :data, :map, null: false, default: %{}
      add :status, :string, null: false, default: "submitted"
      add :reviewer_id, :binary_id
      add :decision_reason, :string
      add :submitted_at, :utc_datetime
      add :reviewed_at, :utc_datetime
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:kyc_requests, [:application_number])
    create index(:kyc_requests, [:customer_id])
    create index(:kyc_requests, [:product_type])
    create index(:kyc_requests, [:status])
    create index(:kyc_requests, [:kyc_method_id])

    create table(:kyc_documents, primary_key: false) do
      add :document_id, :binary_id, primary_key: true
      add :request_id, references(:kyc_requests, column: :request_id, type: :binary_id), null: false
      add :field_key, :string, null: false
      add :storage_path, :string, null: false
      add :original_filename, :string, null: false
      add :content_type, :string
      add :ocr_result, :map

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:kyc_documents, [:request_id])
  end
end
