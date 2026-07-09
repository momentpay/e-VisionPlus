defmodule VmuCore.DPS.EvidenceStore.AzureBlobStore do
  @moduledoc """
  Azure Blob Storage evidence adapter placeholder (DPS-P3).

  Stub only — this project has no Azure Storage client dependency yet. Every
  callback returns `{:error, :not_implemented}` until one is added and wired.

  ## What a real implementation needs

  - Add an Azure Blob Storage client dependency (e.g. `:azurex`) to `mix.exs`.
  - Read `container`/`account` from the bank's `dps.evidence_storage_config` map
    (Module Configuration Framework) — never a raw storage account key; resolve via
    a secrets-manager reference or managed identity.
  - `store/5`: upload to `container` under a blob path convention e.g.
    `"disputes/\#{dispute_id}/\#{filename}"`; return `{:ok, blob_path}` as
    `storage_ref`.
  - `fetch/2`/`delete/2`: download / delete the blob at the stored `storage_ref`.
  """

  @behaviour VmuCore.DPS.EvidenceStore

  require Logger

  @impl true
  def store(_dispute_id, _filename, _content_type, _data, _config) do
    Logger.warning("[DPS.EvidenceStore.AzureBlobStore] not implemented — no Azure client configured")
    {:error, :not_implemented}
  end

  @impl true
  def fetch(_storage_ref, _config) do
    Logger.warning("[DPS.EvidenceStore.AzureBlobStore] not implemented — no Azure client configured")
    {:error, :not_implemented}
  end

  @impl true
  def delete(_storage_ref, _config) do
    Logger.warning("[DPS.EvidenceStore.AzureBlobStore] not implemented — no Azure client configured")
    {:error, :not_implemented}
  end
end
