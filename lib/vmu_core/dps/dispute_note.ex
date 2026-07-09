defmodule VmuCore.DPS.DisputeNote do
  @moduledoc """
  Ecto schema for `dps_dispute_notes` (FR-DPS-015 — case notes/investigator
  assignment). An append-only running log of investigator notes on a dispute case.
  See `VmuCore.DPS.CaseNotes` for the write/read API.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:note_id, :binary_id, autogenerate: true}

  schema "dps_dispute_notes" do
    field :dispute_id, :binary_id
    field :author,     :string
    field :note,       :string
    field :created_at, :naive_datetime
  end

  def changeset(dispute_note, attrs) do
    dispute_note
    |> cast(attrs, [:dispute_id, :author, :note, :created_at])
    |> validate_required([:dispute_id, :author, :note, :created_at])
    |> validate_length(:note, min: 1, max: 4000)
  end
end
