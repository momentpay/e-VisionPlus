defmodule VmuCore.Repo.Migrations.CreateCmsBureauSubmissions do
  @moduledoc """
  Sprint 4E: Bureau submission audit log.

  Tracks every Metro 2 file submission attempt for idempotency and audit.
  The BureauAdapter checks this table before re-transmitting to avoid
  duplicate submissions if the EOD job is retried.
  """

  use Ecto.Migration

  def change do
    create table(:cms_bureau_submissions, primary_key: false) do
      add :submission_id,  :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :filename,       :string, size: 200, null: false
      add :submitted_date, :date, null: false
      add :bureau_ref,     :string, size: 100
      add :status,         :string, size: 20, null: false  # success | failure
      add :mode,           :string, size: 10              # stub | sftp | http

      add :inserted_at, :naive_datetime, null: false
    end

    create index(:cms_bureau_submissions, [:filename, :submitted_date, :status],
      name: :cms_bureau_submissions_lookup_idx)
  end
end
