defmodule VmuCore.Repo.Migrations.AddCompanyFieldsToCustomers do
  @moduledoc """
  Sprint 3F: Add corporate / business entity fields to cms_customers.

  These fields are required for commercial card onboarding (KYB):
    - company_name          — Legal entity name
    - registration_number   — Company registration / incorporation number
    - registration_country  — ISO-2 country code of registration authority
    - registration_date     — Date of incorporation

  All fields are nullable so existing retail customer rows are unaffected.
  A composite index on (id_type, id_number) is added to support the
  `find_duplicates/1` deduplication query efficiently (3G).
  """

  use Ecto.Migration

  def change do
    alter table(:cms_customers) do
      add :company_name,         :string, size: 200
      add :registration_number,  :string, size: 50
      add :registration_country, :string, size: 2
      add :registration_date,    :date
    end

    # Duplicate detection index (3G)
    create index(:cms_customers, [:id_type, :id_number],
      name: :cms_customers_id_dedup_idx,
      where: "id_type IS NOT NULL AND id_number IS NOT NULL"
    )
  end
end
