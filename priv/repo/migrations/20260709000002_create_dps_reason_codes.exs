defmodule VmuCore.Repo.Migrations.CreateDpsReasonCodes do
  use Ecto.Migration

  def change do
    create table(:dps_reason_codes, primary_key: false) do
      add :id,                  :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :network,             :string, size: 4, null: false
      add :reason_code,         :string, size: 10, null: false
      add :description,         :string, size: 255, null: false
      add :category,            :string, size: 30
      add :dispute_window_days, :integer, null: false
      add :evidence_required,   {:array, :string}, default: fragment("ARRAY[]::text[]")

      timestamps()
    end

    create unique_index(:dps_reason_codes, [:network, :reason_code])
  end
end
