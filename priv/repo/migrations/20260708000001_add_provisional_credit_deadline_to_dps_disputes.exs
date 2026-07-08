defmodule VmuCore.Repo.Migrations.AddProvisionalCreditDeadlineToDpsDisputes do
  use Ecto.Migration

  def change do
    alter table(:dps_disputes) do
      add :provisional_credit_deadline, :date
    end
  end
end
