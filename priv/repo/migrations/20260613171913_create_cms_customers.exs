defmodule VmuCore.Repo.Migrations.CreateCmsCustomers do
  use Ecto.Migration

  def change do
    create table(:cms_customers, primary_key: false) do
      add :customer_id,     :uuid,         primary_key: true, default: fragment("gen_random_uuid()")
      add :sys_id,          :string,  size: 4,  null: false
      add :bank_id,         :string,  size: 4,  null: false
      # Identity
      add :first_name,      :string,  size: 100, null: false
      add :last_name,       :string,  size: 100, null: false
      add :date_of_birth,   :date
      add :nationality,     :string,  size: 3    # ISO 3166-1 alpha-3
      # Contact
      add :email,           :string,  size: 255
      add :mobile_country,  :string,  size: 4
      add :mobile_number,   :string,  size: 20
      # Address
      add :address_line1,   :string,  size: 255
      add :address_line2,   :string,  size: 255
      add :city,            :string,  size: 100
      add :postal_code,     :string,  size: 20
      add :country,         :string,  size: 3
      # KYC
      add :id_type,         :string,  size: 20   # PASSPORT | NATIONAL_ID | DRIVING_LICENSE
      add :id_number,       :string,  size: 50
      add :id_expiry,       :date
      add :kyc_status,      :string,  size: 20, null: false, default: "PENDING"
      add :kyc_verified_at, :naive_datetime
      # Classification
      add :customer_tier,   :string,  size: 20, null: false, default: "RETAIL"

      timestamps()
    end

    create index(:cms_customers, [:sys_id, :bank_id])
    create index(:cms_customers, [:email])
    create index(:cms_customers, [:mobile_number])

    # FK to bank_parameters (sys_id, bank_id)
    create constraint(:cms_customers, :fk_cms_customers_bank,
      check: "sys_id IS NOT NULL AND bank_id IS NOT NULL")
  end
end
