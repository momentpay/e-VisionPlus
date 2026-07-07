defmodule VmuCore.TRAMS.MaintenanceAction do
  @moduledoc """
  Controlled manual correction to a transaction record (TRAM-P1 1F, spec 05).

  Non-financial by definition — anything changing an amount is an
  `VmuCore.TRAMS.Adjustment`. Captures before/after values so every action is
  reversible and auditable; status flow implements maker-checker. Command
  logic lands in TRAM-P6 (`maintenance_command.ex`); this is the schema only.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @action_types ~w[DESCRIPTIVE_CORRECTION LINKAGE_CORRECTION STATUS_OVERRIDE FLAG REDRIVE]
  @reason_codes ~w[DATA_CORRECTION MATCHING_ERROR FRAUD_HOLD MANUAL_REDRIVE OPS_OVERRIDE]
  @statuses     ~w[PENDING_APPROVAL APPROVED REJECTED APPLIED]

  schema "trams_maintenance_actions" do
    field :transaction_id, :binary_id
    field :action_type,    :string
    field :reason_code,    :string
    field :comment,        :string
    field :before_values,  :map, default: %{}
    field :after_values,   :map, default: %{}
    field :status,         :string, default: "PENDING_APPROVAL"
    field :requested_by,   :string
    field :approved_by,    :string
    field :applied_at,     :utc_datetime

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w[transaction_id action_type reason_code requested_by]a
  @optional ~w[comment before_values after_values status approved_by applied_at]a

  def changeset(action, attrs) do
    action
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:action_type, @action_types)
    |> validate_inclusion(:reason_code, @reason_codes)
    |> validate_inclusion(:status, @statuses)
  end

  def reason_codes, do: @reason_codes
end
