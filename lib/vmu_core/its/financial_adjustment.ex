defmodule VmuCore.ITS.FinancialAdjustment do
  use Ecto.Schema
  import Ecto.Changeset

  schema "its_financial_adjustments" do
    field :network,             :string
    field :adjustment_type,     :string
    field :reference_no,        :string
    field :original_clearing_id,:integer
    field :original_txn_date,   :date
    field :adjustment_amount,   :decimal
    field :currency,            :string, default: "AED"
    field :reason_code,         :string
    field :reason_description,  :string
    field :received_date,       :date
    field :applied_date,        :date
    field :status,              :string, default: "RECEIVED"
    field :gl_entry_id,         :integer

    timestamps(type: :utc_datetime)
  end

  @valid_types    ~w(MISROUTING PROCESSING_ERROR COMPLIANCE INTERCHANGE_CORRECTION)
  @valid_statuses ~w(RECEIVED UNDER_REVIEW ACCEPTED DISPUTED REVERSED)

  def changeset(adj, attrs) do
    adj
    |> cast(attrs, [:network, :adjustment_type, :reference_no, :original_clearing_id,
                    :original_txn_date, :adjustment_amount, :currency, :reason_code,
                    :reason_description, :received_date, :applied_date, :status, :gl_entry_id])
    |> validate_required([:network, :adjustment_type, :reference_no, :adjustment_amount, :received_date])
    |> validate_inclusion(:adjustment_type, @valid_types)
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:reference_no)
  end
end
