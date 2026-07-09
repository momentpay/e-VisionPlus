defmodule VmuCore.Repo.Migrations.AddOrgSizeToBankParameters do
  use Ecto.Migration

  def change do
    alter table(:bank_parameters) do
      add :org_size, :string, size: 10
    end
  end
end
