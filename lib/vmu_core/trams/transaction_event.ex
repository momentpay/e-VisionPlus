defmodule VmuCore.TRAMS.TransactionEvent do
  @moduledoc """
  Append-only lifecycle event for a TRAM transaction (TRAM-P1 1C).

  The audit source of truth (spec Section 7.3): current transaction state is
  derivable by folding these events in `seq` order. Rows are never updated or
  deleted — corrections are new events. Insert only via
  `VmuCore.TRAMS.EventStore.append/4`, which owns seq assignment and the
  state-projection update.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:event_id, :binary_id, autogenerate: true}

  schema "trams_transaction_events" do
    field :transaction_id, :binary_id
    field :seq,            :integer
    field :event_type,     :string
    field :payload,        :map, default: %{}
    field :actor,          :string, default: "system"
    field :occurred_at,    :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required ~w[transaction_id seq event_type occurred_at]a
  @optional ~w[payload actor]a

  def changeset(event, attrs) do
    event
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:seq, greater_than: 0)
    |> unique_constraint([:transaction_id, :seq])
  end
end
