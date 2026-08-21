defmodule VmuCore.Kyc.DocumentAnnotation do
  @moduledoc """
  A reviewer mark on an uploaded KYC document (KYC-P3, `docs/kyc/
  KYC_Implementation_Tracker.md` §7) — comment/approval/rejection, ported
  from the MMS reference's genuinely good annotation workflow
  (`docs/kyc/MMS_KYC_Feature_Reference.md` §6), simplified: no position/
  page/dimensions (this module has no in-browser document viewer with
  coordinate overlays), just a per-document note trail.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:annotation_id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{}

  @types ~w[comment approval rejection]

  schema "kyc_document_annotations" do
    field :document_id, :binary_id
    field :type, :string
    field :content, :string
    field :created_by, :binary_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @required ~w[document_id type created_by]a
  @optional ~w[content]a

  @doc false
  def changeset(annotation, attrs) do
    annotation
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:type, @types)
  end

  @doc "The fixed annotation types."
  def types, do: @types
end
