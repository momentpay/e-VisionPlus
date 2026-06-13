defmodule VmuCore.ITS.CopyRequest do
  use Ecto.Schema
  import Ecto.Changeset

  schema "its_copy_requests" do
    field :dispute_id,         :integer
    field :account_id,         :binary_id
    field :card_number_token,  :string
    field :transaction_date,   :date
    field :transaction_amount, :decimal
    field :currency,           :string, default: "AED"
    field :merchant_name,      :string
    field :merchant_id,        :string
    field :acquirer_bin,       :string
    field :network,            :string
    field :arn,                :string
    field :request_type,       :string   # COPY_REQUEST | RETRIEVAL_REQUEST | INQUIRY
    field :request_reason,     :string
    field :status,             :string, default: "PENDING"
    field :sent_at,            :utc_datetime
    field :fulfilled_at,       :utc_datetime
    field :response_reason,    :string
    field :deadline_date,      :date
    field :its1_batch_date,    :date
    field :its2_batch_date,    :date
    field :idempotency_key,    :string

    timestamps(type: :utc_datetime)
  end

  @valid_types    ~w(COPY_REQUEST RETRIEVAL_REQUEST INQUIRY)
  @valid_statuses ~w(PENDING SENT FULFILLED DECLINED EXPIRED CANCELLED)
  @valid_networks ~w(MASTERCARD VISA MC VI)

  def changeset(cr, attrs) do
    cr
    |> cast(attrs, [:dispute_id, :account_id, :card_number_token, :transaction_date,
                    :transaction_amount, :currency, :merchant_name, :merchant_id,
                    :acquirer_bin, :network, :arn, :request_type, :request_reason,
                    :status, :sent_at, :fulfilled_at, :response_reason, :deadline_date,
                    :its1_batch_date, :its2_batch_date, :idempotency_key])
    |> validate_required([:account_id, :card_number_token, :transaction_date,
                          :transaction_amount, :network, :request_type])
    |> validate_inclusion(:request_type, @valid_types)
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:idempotency_key)
  end
end
