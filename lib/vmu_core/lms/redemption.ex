defmodule VmuCore.LMS.Redemption do
  use Ecto.Schema
  import Ecto.Changeset

  schema "lms_redemptions" do
    field :lms_account_id,      :integer
    field :redemption_type,     :string    # ONLINE | THIRD_PARTY | AUTO_DISBURSEMENT
    field :points_redeemed,     :decimal
    field :monetary_value,      :decimal
    field :disbursement_method, :string    # CHEQUE | CREDIT | VOUCHER
    field :disbursement_date,   :date
    field :third_party_ref,     :string
    field :status,              :string, default: "PENDING"
    field :idempotency_key,     :string
    field :inserted_at,         :utc_datetime
  end

  @valid_types    ~w(ONLINE THIRD_PARTY AUTO_DISBURSEMENT)
  @valid_methods  ~w(CHEQUE CREDIT VOUCHER)
  @valid_statuses ~w(PENDING PROCESSED SETTLED REVERSED)

  def changeset(redemption, attrs) do
    redemption
    |> cast(attrs, [:lms_account_id, :redemption_type, :points_redeemed, :monetary_value,
                    :disbursement_method, :disbursement_date, :third_party_ref, :status,
                    :idempotency_key, :inserted_at])
    |> validate_required([:lms_account_id, :redemption_type, :points_redeemed, :monetary_value])
    |> validate_inclusion(:redemption_type, @valid_types)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_disbursement_method()
    |> validate_number(:points_redeemed, greater_than: 0)
    |> unique_constraint(:idempotency_key)
  end

  defp validate_disbursement_method(cs) do
    case get_field(cs, :disbursement_method) do
      nil -> cs
      _   -> validate_inclusion(cs, :disbursement_method, @valid_methods)
    end
  end
end
