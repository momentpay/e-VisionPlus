defmodule VmuCore.Repo.Migrations.CreateSharedModuleConfigs do
  use Ecto.Migration

  def change do
    create table(:shared_module_configs, primary_key: false) do
      add :id,         :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :scope_type, :string, size: 10, null: false
      add :sys_id,     :string, size: 10, null: false
      add :bank_id,    :string, size: 10, null: false, default: ""
      add :logo_id,    :string, size: 10, null: false, default: ""
      add :module,     :string, size: 20, null: false
      add :config_key, :string, size: 60, null: false
      add :value,      :map, null: false
      add :updated_by, :string, size: 40

      timestamps()
    end

    create unique_index(:shared_module_configs,
      [:scope_type, :sys_id, :bank_id, :logo_id, :module, :config_key],
      name: :shared_module_configs_scope_key_idx)

    create index(:shared_module_configs, [:module])
  end
end
