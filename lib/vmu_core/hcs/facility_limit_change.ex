defmodule VmuCore.HCS.FacilityLimitChange do
  @moduledoc """
  Maker-checker request to change an HCS company's facility credit limit
  (Way4 parity plan Phase 1 item 2, 2026-07-25) — parked for approval via
  the unified Approval Inbox, same shape as COL's WorkoutPlan/
  SettlementOffer (COL-P9).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @statuses ~w[PENDING_APPROVAL APPROVED REJECTED]

  schema "hcs_facility_limit_changes" do
    field :company_id,      :integer
    field :current_limit,   :decimal
    field :requested_limit, :decimal
    field :reason,          :string
    field :status,          :string, default: "PENDING_APPROVAL"
    field :requested_by,    :string
    field :approved_by,     :string

    timestamps(type: :utc_datetime)
  end

  @required ~w[company_id current_limit requested_limit requested_by]a
  @optional ~w[reason status approved_by]a

  def changeset(change, attrs) do
    change
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:requested_limit, greater_than: 0)
  end

  @type t :: %__MODULE__{}
end
