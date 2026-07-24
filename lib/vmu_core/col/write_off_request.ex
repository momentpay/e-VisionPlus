defmodule VmuCore.COL.WriteOffRequest do
  @moduledoc """
  Maker-checker parking record for an automatic write-off (COL-P2, FR-COL-020).

  Created by `VmuCore.COL.WriteOffCommand.request/1` once an account crosses
  `col.writeoff_dpd_threshold`; approved/rejected by an operator whose role is
  in `col.writeoff_approval_matrix` via `WriteOffCommand.approve/2`/`reject/2`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @statuses ~w[PENDING_APPROVAL APPROVED REJECTED POSTED]

  schema "col_writeoff_requests" do
    field :account_id,       :binary_id
    field :case_id,          :binary_id
    field :dpd_bucket,       :integer
    field :write_off_amount, :decimal
    field :ifrs9_stage,      :string
    field :reason,           :string
    field :status,           :string, default: "PENDING_APPROVAL"
    field :requested_by,     :string
    field :approved_by,      :string
    field :posted_at,        :utc_datetime

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w[account_id dpd_bucket write_off_amount requested_by]a
  @optional ~w[case_id ifrs9_stage reason status approved_by posted_at]a

  def changeset(req, attrs) do
    req
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
  end
end
