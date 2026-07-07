defmodule VmuCore.TRAMS.Adjustment do
  @moduledoc """
  Post-posting amount correction (TRAM-P1 1F, spec 06 §3.4).

  Adjustments apply only to POSTED-or-later transactions (pre-posting
  corrections are reversals). Above-threshold adjustments require maker-checker
  approval before posting — command logic lands in TRAM-P4
  (`adjustment_command.ex`); this is the schema only.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:adjustment_id, :binary_id, autogenerate: true}

  @directions ~w[CREDIT DEBIT]
  @statuses   ~w[PENDING_APPROVAL APPROVED REJECTED POSTED]

  schema "trams_adjustments" do
    field :transaction_id,     :binary_id
    field :old_amount,         :decimal
    field :new_amount,         :decimal
    field :delta,              :decimal
    field :direction,          :string
    field :reason_code,        :string
    field :narrative,          :string
    field :status,             :string, default: "PENDING_APPROVAL"
    field :requested_by,       :string
    field :approved_by,        :string
    field :gl_idempotency_key, :string
    field :posted_at,          :utc_datetime

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w[transaction_id old_amount new_amount delta direction reason_code requested_by]a
  @optional ~w[narrative status approved_by gl_idempotency_key posted_at]a

  def changeset(adj, attrs) do
    adj
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:direction, @directions)
    |> validate_inclusion(:status, @statuses)
  end
end
