defmodule VmuCore.Shared.Customer do
  @moduledoc """
  CMS customer record — individual and corporate card holders.

  ## Corporate / Business fields (3F)

  When `customer_tier` is BUSINESS or CORPORATE, the following optional fields
  capture entity-level data required for commercial card onboarding and KYB:

    - `company_name`          — Registered legal entity name
    - `registration_number`   — Company registration / incorporation number
    - `registration_country`  — ISO-2 country code of registration authority
    - `registration_date`     — Date of incorporation

  These fields are optional for RETAIL/PREMIUM tiers and are stored in the same
  table to avoid unnecessary joins on the common case.

  ## Reverse lookup (3G)

  `list_accounts_for/1` returns all CMS accounts linked to a customer_id.
  `find_duplicates/1` detects potential duplicate customers by matching on
  (id_type, id_number) — the issuer identity pair used for deduplication.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias VmuCore.{Repo, CMS.Account}

  @primary_key {:customer_id, :binary_id, autogenerate: true}

  schema "cms_customers" do
    field :sys_id,                :string
    field :bank_id,               :string
    field :first_name,            :string
    field :last_name,             :string
    field :date_of_birth,         :date
    field :nationality,           :string
    field :email,                 :string
    field :mobile_country,        :string
    field :mobile_number,         :string
    field :address_line1,         :string
    field :address_line2,         :string
    field :city,                  :string
    field :postal_code,           :string
    field :country,               :string
    field :id_type,               :string
    field :id_number,             :string
    field :id_expiry,             :date
    field :kyc_status,            :string, default: "PENDING"
    field :kyc_verified_at,       :naive_datetime
    field :customer_tier,         :string, default: "RETAIL"

    # Corporate / business fields (3F)
    field :company_name,          :string
    field :registration_number,   :string
    field :registration_country,  :string
    field :registration_date,     :date

    timestamps()
  end

  @type t :: %__MODULE__{}

  @required [:sys_id, :bank_id, :first_name, :last_name]
  @optional [:date_of_birth, :nationality, :email, :mobile_country, :mobile_number,
             :address_line1, :address_line2, :city, :postal_code, :country,
             :id_type, :id_number, :id_expiry, :kyc_status, :kyc_verified_at, :customer_tier,
             :company_name, :registration_number, :registration_country, :registration_date]

  def changeset(customer, attrs) do
    customer
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:kyc_status, ~w[PENDING VERIFIED REJECTED])
    |> validate_inclusion(:customer_tier, ~w[RETAIL BUSINESS CORPORATE PREMIUM])
    |> validate_corporate_fields()
  end

  # ---------------------------------------------------------------------------
  # Reverse-lookup queries (3G)
  # ---------------------------------------------------------------------------

  @doc """
  Return all CMS accounts for a customer UUID.

  Useful for operator screens (CMS01) and customer 360° views.

  ## Example

      accounts = Customer.list_accounts_for("uuid-here")
      # => [%Account{...}, ...]
  """
  @spec list_accounts_for(binary()) :: [Account.t()]
  def list_accounts_for(customer_id) do
    Repo.all(
      from a in Account,
        where: a.customer_id == ^customer_id,
        order_by: [asc: a.inserted_at]
    )
  end

  @doc """
  Find potential duplicate customer records sharing the same identity document.

  Returns a list of `{customer_id, bank_id}` tuples for any customer with the
  same (id_type, id_number) pair, excluding the querying customer_id itself.
  An empty list means no duplicate detected.

  ## Usage

      case Customer.find_duplicates(new_customer) do
        []   -> # safe to onboard
        dups -> # flag for manual KYB review
      end
  """
  @spec find_duplicates(t() | map()) :: [{binary(), binary()}]
  def find_duplicates(%{customer_id: self_id, id_type: id_type, id_number: id_number})
      when not is_nil(id_type) and not is_nil(id_number) do
    Repo.all(
      from c in __MODULE__,
        where: c.id_type      == ^id_type
           and c.id_number    == ^id_number
           and c.customer_id  != ^self_id,
        select: {c.customer_id, c.bank_id}
    )
  end

  def find_duplicates(_), do: []

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp validate_corporate_fields(changeset) do
    tier = get_field(changeset, :customer_tier)

    if tier in ["BUSINESS", "CORPORATE"] do
      changeset
      |> validate_required([:company_name, :registration_number],
           message: "required for #{tier} customers")
    else
      changeset
    end
  end
end
