defmodule VmuCore.COL.AgencyActivity do
  @moduledoc """
  One line from an agency activity/payment file (COL-P4, FR-COL-018/019).
  `raw_line` preserves the original parsed row for audit/reprocessing.
  Written by `VmuCore.COL.AgencyDesk.import_activity_file/4`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @activity_types ~w[PAYMENT CONTACT PROMISE SKIP_TRACE DISPUTE RECALL_REQUEST]
  @statuses ~w[RECEIVED APPLIED REJECTED]

  schema "col_agency_activity" do
    field :placement_id,      :binary_id
    field :activity_type,     :string
    field :amount,            :decimal
    field :commission_amount, :decimal
    field :activity_date,     :date
    field :raw_line,          :map, default: %{}
    field :status,            :string, default: "RECEIVED"
    field :reject_reason,     :string

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w[placement_id activity_type]a
  @optional ~w[amount commission_amount activity_date raw_line status reject_reason]a

  def changeset(activity, attrs) do
    activity
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:activity_type, @activity_types)
    |> validate_inclusion(:status, @statuses)
  end

  def activity_types, do: @activity_types
end
