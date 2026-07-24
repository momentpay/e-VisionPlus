defmodule VmuCore.COL.AgencyPlacement do
  @moduledoc """
  One agency placement lifecycle (COL-P4, FR-COL-018/019): a case handed to an
  external collection agency, from placement through recall/closure. Written
  by `VmuCore.COL.AgencyDesk`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @statuses ~w[PLACED RECALLED CLOSED]

  schema "col_agency_placements" do
    field :case_id,       :binary_id
    field :account_id,    :binary_id
    field :agency_code,   :string
    field :status,        :string, default: "PLACED"
    field :placed_amount, :decimal
    field :placed_at,     :utc_datetime
    field :recalled_at,   :utc_datetime
    field :recall_reason, :string

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w[case_id account_id agency_code placed_amount placed_at]a
  @optional ~w[status recalled_at recall_reason]a

  def changeset(placement, attrs) do
    placement
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
  end
end
