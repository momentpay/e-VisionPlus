defmodule VmuCore.Repo.Migrations.AddKycStepSequencing do
  use Ecto.Migration

  def change do
    alter table(:kyc_methods) do
      add :step, :integer, null: false, default: 1
      add :required, :boolean, null: false, default: true
    end

    alter table(:kyc_requests) do
      add :step, :integer, null: false, default: 1
    end

    create index(:kyc_methods, [:product_type, :step])
  end
end
