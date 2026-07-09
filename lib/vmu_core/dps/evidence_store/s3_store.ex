defmodule VmuCore.DPS.EvidenceStore.S3Store do
  @moduledoc """
  S3 evidence storage adapter placeholder (DPS-P3).

  Stub only — this project has no `ex_aws`/`ex_aws_s3` dependency yet. Every callback
  returns `{:error, :not_implemented}` until one is added and wired.

  ## What a real implementation needs

  - Add `{:ex_aws, "~> 2.5"}` and `{:ex_aws_s3, "~> 2.5"}` to `mix.exs`.
  - Read `bucket`/`region` from the bank's `dps.evidence_storage_config` map
    (Module Configuration Framework) — never a raw AWS key/secret; resolve
    credentials via the runtime's IAM role or a secrets-manager reference.
  - `store/5`: `ExAws.S3.put_object(bucket, object_key, data) |> ExAws.request()`,
    object key convention e.g. `"disputes/\#{dispute_id}/\#{filename}"`; return
    `{:ok, object_key}` as `storage_ref`.
  - `fetch/2`/`delete/2`: `ExAws.S3.get_object/2` / `delete_object/2` against the
    stored `storage_ref`.
  """

  @behaviour VmuCore.DPS.EvidenceStore

  require Logger

  @impl true
  def store(_dispute_id, _filename, _content_type, _data, _config) do
    Logger.warning("[DPS.EvidenceStore.S3Store] not implemented — no ex_aws dependency configured")
    {:error, :not_implemented}
  end

  @impl true
  def fetch(_storage_ref, _config) do
    Logger.warning("[DPS.EvidenceStore.S3Store] not implemented — no ex_aws dependency configured")
    {:error, :not_implemented}
  end

  @impl true
  def delete(_storage_ref, _config) do
    Logger.warning("[DPS.EvidenceStore.S3Store] not implemented — no ex_aws dependency configured")
    {:error, :not_implemented}
  end
end
