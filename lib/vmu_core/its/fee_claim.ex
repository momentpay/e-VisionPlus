defmodule VmuCore.ITS.FeeClaim do
  use Ecto.Schema
  import Ecto.Changeset

  schema "its_fee_claims" do
    field :clearing_record_id,   :integer
    field :network,              :string
    field :claim_type,           :string
    field :mcc,                  :string
    field :interchange_category, :string
    field :gross_amount,         :decimal
    field :interchange_rate,     :decimal
    field :interchange_amount,   :decimal
    field :scheme_fee_amount,    :decimal, default: 0
    field :net_interchange,      :decimal
    field :currency,             :string, default: "AED"
    field :processing_date,      :date
    field :settlement_date,      :date
    field :status,               :string, default: "PENDING"
    field :gl_entry_id,          :integer
    field :idempotency_key,      :string
    field :inserted_at,          :utc_datetime
  end

  @valid_types    ~w(INTERCHANGE_INCOME INTERCHANGE_EXPENSE SCHEME_FEE PROCESSING_FEE)
  @valid_statuses ~w(PENDING SETTLED DISPUTED REVERSED)

  def changeset(claim, attrs) do
    claim
    |> cast(attrs, [:clearing_record_id, :network, :claim_type, :mcc, :interchange_category,
                    :gross_amount, :interchange_rate, :interchange_amount, :scheme_fee_amount,
                    :net_interchange, :currency, :processing_date, :settlement_date,
                    :status, :gl_entry_id, :idempotency_key, :inserted_at])
    |> validate_required([:network, :claim_type, :gross_amount, :interchange_rate,
                          :interchange_amount, :net_interchange, :processing_date])
    |> validate_inclusion(:claim_type, @valid_types)
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:idempotency_key)
  end
end
