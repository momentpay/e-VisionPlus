defmodule VmuCore.Repo.Migrations.AddSanctionsScreeningToCdmCreditApplications do
  use Ecto.Migration

  def change do
    alter table(:cdm_credit_applications) do
      add :sanctions_status,      :string, size: 20   # CLEAR | HIT | UNAVAILABLE
      add :sanctions_reference,   :string, size: 200   # matched name + list_type when HIT
      add :sanctions_screened_at, :naive_datetime
    end

    create index(:cdm_credit_applications, [:sanctions_status])
  end
end
