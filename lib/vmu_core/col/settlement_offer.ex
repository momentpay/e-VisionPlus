defmodule VmuCore.COL.SettlementOffer do
  @moduledoc """
  Lump-sum settlement offer (COL-P9, FR-COL-015), authority-tiered by discount
  size. Written by `VmuCore.COL.SettlementCommand`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @statuses ~w[PENDING_APPROVAL APPROVED REJECTED PAID EXPIRED CANCELLED]

  schema "col_settlement_offers" do
    field :case_id,            :binary_id
    field :account_id,         :binary_id
    field :outstanding_amount, :decimal
    field :offer_amount,       :decimal
    field :discount_percent,   :decimal
    field :expiry_date,        :date
    field :status,             :string, default: "PENDING_APPROVAL"
    field :requested_by,       :string
    field :approved_by,        :string
    field :paid_amount,        :decimal
    field :forgiven_amount,    :decimal
    field :paid_at,            :utc_datetime
    field :reference,          :string

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w[case_id account_id outstanding_amount offer_amount discount_percent expiry_date requested_by]a
  @optional ~w[status approved_by paid_amount forgiven_amount paid_at reference]a

  def changeset(offer, attrs) do
    offer
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
  end
end
