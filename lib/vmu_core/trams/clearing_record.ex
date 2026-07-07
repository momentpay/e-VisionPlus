defmodule VmuCore.TRAMS.ClearingRecord do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:clearing_id, :binary_id, autogenerate: true}

  schema "trams_clearing_records" do
    field :account_id,       :binary_id
    field :network,          :string
    field :file_name,        :string
    field :record_type,      :string
    field :pan_token,        :string
    field :transaction_date, :date
    field :settlement_date,  :date
    field :amount,           :decimal
    field :currency,         :string
    field :interchange_fee,  :decimal, default: Decimal.new(0)
    field :mcc,              :string
    field :acquirer_id,      :string
    field :rrn,              :string
    field :auth_code,        :string
    field :match_status,     :string, default: "UNMATCHED"
    field :matched_auth_id,  :binary_id
    # De-dup key for file redelivery (IpmPipeline conflict target) — added in
    # TRAM-P1 migration 20260703000001; the pipeline referenced it before the
    # column existed.
    field :idempotency_key,        :string
    # TRAM transaction this clearing record was matched to (TRAM-P3)
    field :matched_transaction_id, :binary_id

    timestamps()
  end

  def changeset(rec, attrs) do
    rec
    |> cast(attrs, [:account_id, :network, :file_name, :record_type, :pan_token,
                    :transaction_date, :settlement_date, :amount, :currency,
                    :interchange_fee, :mcc, :acquirer_id, :rrn, :auth_code,
                    :match_status, :matched_auth_id, :idempotency_key,
                    :matched_transaction_id])
    |> validate_required([:network, :file_name, :match_status])
    |> unique_constraint(:idempotency_key)
  end
end
