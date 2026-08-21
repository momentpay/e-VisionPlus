defmodule VmuCore.Kyc.Documents do
  @moduledoc """
  Context for `Kyc.Document`/`Kyc.DocumentAnnotation` — upload (local disk
  under `priv/`, path in a DB column, same convention this codebase already
  uses elsewhere — no new object-storage integration for v1) + OCR
  extraction + the reviewer annotation trail (KYC-P3, `docs/kyc/
  KYC_Implementation_Tracker.md` §7).

  OCR failure never blocks the upload itself — a document with no OCR
  result is still a real, stored document; `ocr_result` is just `nil`.
  """

  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.Kyc.{Document, DocumentAnnotation}
  alias VmuCore.Kyc.Adapters.OcrHttpAdapter

  @doc """
  Store an uploaded file for `field_key` on `request_id`, then attempt OCR
  extraction. `file` is `%{filename:, content_type:, tmp_path:}` (the path
  LiveView's `consume_uploaded_entries/3` hands the callback).
  """
  @spec upload(binary(), String.t(), map()) :: {:ok, Document.t()} | {:error, term()}
  def upload(request_id, field_key, %{filename: filename, tmp_path: tmp_path} = file) do
    storage_path = persist_to_disk!(request_id, filename, tmp_path)
    ocr_result = run_ocr(tmp_path)

    %Document{}
    |> Document.changeset(%{
      request_id: request_id,
      field_key: field_key,
      storage_path: storage_path,
      original_filename: filename,
      content_type: Map.get(file, :content_type),
      ocr_result: ocr_result
    })
    |> Repo.insert()
  end

  @doc "List documents for a request, most recent first."
  @spec list_for_request(binary()) :: [Document.t()]
  def list_for_request(request_id) do
    Repo.all(
      from d in Document,
        where: d.request_id == ^request_id,
        order_by: [desc: d.inserted_at]
    )
  end

  @doc "Add a reviewer annotation (comment/approval/rejection) to a document."
  @spec annotate(binary(), String.t(), String.t() | nil, binary()) :: {:ok, DocumentAnnotation.t()} | {:error, Ecto.Changeset.t()}
  def annotate(document_id, type, content, created_by) do
    %DocumentAnnotation{}
    |> DocumentAnnotation.changeset(%{
      document_id: document_id,
      type: type,
      content: content,
      created_by: created_by
    })
    |> Repo.insert()
  end

  @doc "List annotations for a document, most recent first."
  @spec list_annotations(binary()) :: [DocumentAnnotation.t()]
  def list_annotations(document_id) do
    Repo.all(
      from a in DocumentAnnotation,
        where: a.document_id == ^document_id,
        order_by: [desc: a.inserted_at]
    )
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp persist_to_disk!(request_id, filename, tmp_path) do
    dir = Path.join([:code.priv_dir(:vmu_core), "uploads", "kyc", request_id])
    File.mkdir_p!(dir)

    safe_name = "#{Ecto.UUID.generate()}-#{Path.basename(filename)}"
    dest = Path.join(dir, safe_name)
    File.cp!(tmp_path, dest)

    dest
  end

  defp run_ocr(tmp_path) do
    case OcrHttpAdapter.extract_text(tmp_path) do
      {:ok, result} -> result
      {:error, _reason} -> nil
    end
  end
end
