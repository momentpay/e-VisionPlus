defmodule VmuCore.Shared.Customer do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:customer_id, :binary_id, autogenerate: true}

  schema "cms_customers" do
    field :sys_id,          :string
    field :bank_id,         :string
    field :first_name,      :string
    field :last_name,       :string
    field :date_of_birth,   :date
    field :nationality,     :string
    field :email,           :string
    field :mobile_country,  :string
    field :mobile_number,   :string
    field :address_line1,   :string
    field :address_line2,   :string
    field :city,            :string
    field :postal_code,     :string
    field :country,         :string
    field :id_type,         :string
    field :id_number,       :string
    field :id_expiry,       :date
    field :kyc_status,      :string, default: "PENDING"
    field :kyc_verified_at, :naive_datetime
    field :customer_tier,   :string, default: "RETAIL"

    timestamps()
  end

  @required [:sys_id, :bank_id, :first_name, :last_name]
  @optional [:date_of_birth, :nationality, :email, :mobile_country, :mobile_number,
             :address_line1, :address_line2, :city, :postal_code, :country,
             :id_type, :id_number, :id_expiry, :kyc_status, :kyc_verified_at, :customer_tier]

  def changeset(customer, attrs) do
    customer
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:kyc_status, ~w[PENDING VERIFIED REJECTED])
    |> validate_inclusion(:customer_tier, ~w[RETAIL BUSINESS CORPORATE PREMIUM])
  end
end
