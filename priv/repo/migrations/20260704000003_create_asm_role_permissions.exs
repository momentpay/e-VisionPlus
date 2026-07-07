defmodule VmuCore.Repo.Migrations.CreateAsmRolePermissions do
  use Ecto.Migration

  # ASM-P2 (ADR-A3): role → permission matrix as DATA, not code.
  # One row per (role, module, action) grant. ADMIN is a code-level
  # short-circuit and has no rows here.
  def change do
    create table(:asm_role_permissions, primary_key: false) do
      add :id,     :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :role,   :string, size: 20, null: false
      add :module, :string, size: 30, null: false  # admin module key (sidebar)
      add :action, :string, size: 20, null: false  # view | create | edit | approve

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:asm_role_permissions, [:role, :module, :action])
    create index(:asm_role_permissions, [:role])
  end
end
