defmodule VmuCore.DPS.DisputeEvidence do
  @moduledoc """
  Ecto schema for `dps_dispute_evidence` (DPS-P3 — evidence store scaffolding,
  FR-DPS-014). One row per uploaded document, linked to a `VmuCore.DPS.Dispute`.

  `backend` records which storage backend held this specific file at upload time
  (`"db"`/`"s3"`/`"azure_blob"`) — a bank's `dps.evidence_storage_backend` config can
  change over time, but existing evidence must stay retrievable regardless. `data`
  is populated only for the `db` backend; `storage_ref` (the S3/Azure object key) is
  populated only for cloud backends. See `VmuCore.DPS.Evidence` (context) and
  `VmuCore.DPS.EvidenceStore` (storage behaviour).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:evidence_id, :binary_id, autogenerate: true}

  schema "dps_dispute_evidence" do
    field :dispute_id,   :binary_id
    field :backend,      :string
    field :storage_ref,  :string
    field :filename,     :string
    field :content_type, :string
    field :size_bytes,   :integer
    field :data,         :binary
    field :uploaded_by,  :string
    field :uploaded_at,  :naive_datetime
  end

  @backends ~w[db s3 azure_blob]

  def changeset(evidence, attrs) do
    evidence
    |> cast(attrs, [:dispute_id, :backend, :storage_ref, :filename, :content_type,
                    :size_bytes, :data, :uploaded_by, :uploaded_at])
    |> validate_required([:dispute_id, :backend, :filename, :size_bytes, :uploaded_at])
    |> validate_inclusion(:backend, @backends)
  end
end
