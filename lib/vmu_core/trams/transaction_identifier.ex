defmodule VmuCore.TRAMS.TransactionIdentifier do
  @moduledoc """
  External identifiers for a TRAM transaction (TRAM-P1 1C, spec Section 6).

  Separates business identity (the internal `transaction_id` UUID) from
  external identity (STAN / RRN / auth code / network reference). One row per
  source message — a transaction accumulates identifier rows as it moves
  through authorization, clearing, and disputes, and the matching engine
  (TRAM-P3) resolves incoming messages through these in hierarchy order:
  RRN → STAN → auth code → PAN/amount/date.

  STAN is NOT unique (rolls over at 999999) and auth codes are not guaranteed
  unique — that's exactly why this is a separate table and none of these
  columns carry unique indexes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @sources ~w[authorization clearing dispute]

  schema "trams_transaction_identifiers" do
    field :transaction_id, :binary_id
    field :stan,           :string
    field :rrn,            :string
    field :auth_code,      :string
    field :network_ref,    :string
    field :source,         :string, default: "authorization"

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(ident, attrs) do
    ident
    |> cast(attrs, ~w[transaction_id stan rrn auth_code network_ref source]a)
    |> validate_required([:transaction_id, :source])
    |> validate_inclusion(:source, @sources)
  end
end
