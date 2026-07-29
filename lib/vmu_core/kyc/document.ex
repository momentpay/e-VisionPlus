defmodule VmuCore.Kyc.Document do
  @moduledoc """
  An uploaded file for a `file`-type field on a `Kyc.Request`
  (`docs/kyc/KYC_Implementation_Tracker.md` §3.4). Local-disk-under-`priv/`
  storage, path in a DB column — same convention this codebase already uses
  elsewhere, no new object-storage integration for v1.

  `ocr_result` is populated in KYC-P3; always `nil` for now.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:document_id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{}

  schema "kyc_documents" do
    field :request_id, :binary_id
    field :field_key, :string
    field :storage_path, :string
    field :original_filename, :string
    field :content_type, :string
    field :ocr_result, :map

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @required ~w[request_id field_key storage_path original_filename]a
  @optional ~w[content_type ocr_result]a

  @doc false
  def changeset(document, attrs) do
    document
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
  end
end
