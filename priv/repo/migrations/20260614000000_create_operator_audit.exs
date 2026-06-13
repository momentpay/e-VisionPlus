defmodule VmuCore.Repo.Migrations.CreateOperatorAudit do
  use Ecto.Migration

  def change do
    create table(:cms_operator_audit) do
      add :operator_id,   :string, size: 50, null: false
      add :operator_role, :string, size: 20, null: false
      add :action,        :string, size: 50, null: false
      add :subject,       :string, size: 100, null: false
      add :details,       :text
      add :performed_at,  :naive_datetime, null: false
      add :inserted_at,   :naive_datetime, null: false
    end

    create index(:cms_operator_audit, [:operator_id])
    create index(:cms_operator_audit, [:action, :performed_at])
  end
end
