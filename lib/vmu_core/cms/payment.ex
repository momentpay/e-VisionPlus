defmodule VmuCore.CMS.Payment do
  @moduledoc """
  Payment register row (CMS-G2).

  One row per received payment. `postings` stores the exact bucket-level
  distribution (`%{"retail_balance" => "30.00", ...}`) so
  `VmuCore.CMS.PaymentReversal` can re-debit precisely what was credited —
  no reverse-hierarchy guessing. `account_id` is nil while an unmatched
  receipt sits in SUSPENSE.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:payment_id, :binary_id, autogenerate: true}

  @statuses ~w[POSTED REVERSED SUSPENSE]

  schema "cms_payments" do
    field :account_id,      :binary_id
    field :reference,       :string
    field :amount,          :decimal
    field :allocated,       :decimal
    field :remainder,       :decimal
    field :channel,         :string
    field :status,          :string, default: "POSTED"
    field :postings,        :map, default: %{}
    field :note,            :string
    field :reversal_reason, :string
    field :reversed_at,     :utc_datetime

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w[reference amount channel status]a
  @optional ~w[account_id allocated remainder postings note reversal_reason reversed_at]a

  def changeset(payment, attrs) do
    payment
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:reference)
  end
end
