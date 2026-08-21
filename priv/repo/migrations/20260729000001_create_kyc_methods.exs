defmodule VmuCore.Repo.Migrations.CreateKycMethods do
  use Ecto.Migration

  def change do
    create table(:kyc_methods, primary_key: false) do
      add :method_id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :title, :string, null: false
      add :product_type, :string, null: false
      add :status, :string, null: false, default: "active"
      add :version, :integer, null: false, default: 1
      add :fields, :map, null: false, default: %{}
      add :conditional_rules, :map
      add :cloned_from_method_id, :binary_id
      add :sys_id, :string
      add :bank_id, :string

      timestamps(type: :utc_datetime)
    end

    create index(:kyc_methods, [:product_type])
    create index(:kyc_methods, [:status])
  end
end
