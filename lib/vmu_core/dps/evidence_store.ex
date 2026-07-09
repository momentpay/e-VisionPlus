defmodule VmuCore.DPS.EvidenceStore do
  @moduledoc """
  Behaviour contract for dispute evidence storage backends (DPS-P3, FR-DPS-014).

  Mirrors `VmuCore.FAS.HSM`'s shape: a plain `@callback` per operation plus a thin
  delegation function, but the adapter here is selected **per-request** from
  `dps.evidence_storage_backend` (Module Configuration Framework, per-bank) rather
  than a single global `Application.get_env` — see `VmuCore.DPS.Evidence.adapter/1`.

  ## Adapters

  - `VmuCore.DPS.EvidenceStore.DbStore` — real. Evidence bytes live directly in the
    `dps_dispute_evidence.data` column; this adapter is a no-op (the context layer
    owns the actual row).
  - `VmuCore.DPS.EvidenceStore.S3Store` / `AzureBlobStore` — stubs. No cloud SDK
    dependency exists in this project yet (`mix.exs` has no `ex_aws`/`ex_aws_s3` or
    Azure blob client) — every callback returns `{:error, :not_implemented}` until
    one is added and wired, matching `VmuCore.FAS.HSM.ProductionHSM`'s pattern for an
    unconfigured vendor HSM.
  """

  @doc """
  Store evidence bytes for a dispute. `config` is the bank's
  `dps.evidence_storage_config` map (bucket/container/region, credential reference —
  never a raw secret).

  Returns `{:ok, storage_ref}` — `storage_ref` is `nil` for the `db` backend (the
  bytes are the row itself) or the cloud object key for `s3`/`azure_blob`.
  """
  @callback store(dispute_id :: Ecto.UUID.t(), filename :: String.t(),
                  content_type :: String.t() | nil, data :: binary(), config :: map()) ::
              {:ok, storage_ref :: String.t() | nil} | {:error, term()}

  @doc "Fetch evidence bytes by `storage_ref` (unused for `db` — the context reads the row's `data` column directly)."
  @callback fetch(storage_ref :: String.t(), config :: map()) ::
              {:ok, binary()} | {:error, term()}

  @doc "Delete evidence bytes by `storage_ref` (unused for `db` — the context deletes the row directly)."
  @callback delete(storage_ref :: String.t(), config :: map()) ::
              :ok | {:error, term()}

  @adapters %{
    "db"         => __MODULE__.DbStore,
    "s3"         => __MODULE__.S3Store,
    "azure_blob" => __MODULE__.AzureBlobStore
  }

  @doc "Resolves the adapter module for a `dps.evidence_storage_backend` value."
  @spec adapter(String.t()) :: module()
  def adapter(backend), do: Map.get(@adapters, backend, __MODULE__.DbStore)
end
