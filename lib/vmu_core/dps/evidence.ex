defmodule VmuCore.DPS.Evidence do
  @moduledoc """
  Context for dispute evidence attachments (DPS-P3, FR-DPS-014) — the first real
  consumer of `dps.evidence_storage_backend`/`evidence_storage_config`.

  Resolves the dispute's bank/logo scope, dispatches to the configured
  `VmuCore.DPS.EvidenceStore` adapter, and persists the `VmuCore.DPS.DisputeEvidence`
  row. Every write is audited via the existing `VmuCore.ASM.AuditLog` sink — no new
  audit table. Never inserts a row on a storage failure (e.g. `s3`/`azure_blob`
  returning `{:error, :not_implemented}`).
  """

  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.DPS.{Dispute, DisputeEvidence, EvidenceStore}
  alias VmuCore.CMS.Account
  alias VmuCore.Shared.ModuleConfigEngine
  alias VmuCore.ASM.AuditLog

  @doc """
  Attach a document to a dispute. `file` is
  `%{filename:, content_type:, data: binary()}`.

  Returns `{:ok, evidence}` or `{:error, reason}` — `reason` is the storage
  adapter's error (e.g. `:not_implemented`) or an `Ecto.Changeset`.
  """
  @spec attach(Ecto.UUID.t(), map(), VmuCore.ASM.Operator.t() | nil) ::
          {:ok, DisputeEvidence.t()} | {:error, term()}
  def attach(dispute_id, %{filename: filename, data: data} = file, operator) do
    content_type = Map.get(file, :content_type)

    with {:ok, dispute} <- fetch_dispute(dispute_id),
         {:ok, sys_id, bank_id, logo_id} <- resolve_scope(dispute),
         {:ok, backend} <- get_config(sys_id, bank_id, logo_id, "evidence_storage_backend"),
         {:ok, config} <- get_config(sys_id, bank_id, logo_id, "evidence_storage_config"),
         {:ok, storage_ref} <- EvidenceStore.adapter(backend).store(dispute_id, filename, content_type, data, config) do
      attrs = %{
        dispute_id: dispute_id,
        backend: backend,
        storage_ref: storage_ref,
        filename: filename,
        content_type: content_type,
        size_bytes: byte_size(data),
        data: if(backend == "db", do: data, else: nil),
        uploaded_by: operator_name(operator),
        uploaded_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      }

      case %DisputeEvidence{} |> DisputeEvidence.changeset(attrs) |> Repo.insert() do
        {:ok, evidence} ->
          AuditLog.record(operator, "dispute_evidence_attach", dispute_id,
            %{filename: filename, backend: backend, size_bytes: attrs.size_bytes})
          {:ok, evidence}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc "All evidence for a dispute, newest first."
  @spec list(Ecto.UUID.t()) :: [DisputeEvidence.t()]
  def list(dispute_id) do
    Repo.all(
      from e in DisputeEvidence,
        where: e.dispute_id == ^dispute_id,
        order_by: [desc: e.uploaded_at]
    )
  end

  @doc "Fetch an evidence document's raw bytes, regardless of backend."
  @spec fetch_data(Ecto.UUID.t()) :: {:ok, binary()} | {:error, term()}
  def fetch_data(evidence_id) do
    case Repo.get(DisputeEvidence, evidence_id) do
      nil ->
        {:error, :not_found}

      %DisputeEvidence{backend: "db", data: data} ->
        {:ok, data}

      %DisputeEvidence{backend: backend, storage_ref: ref} = evidence ->
        with {:ok, dispute} <- fetch_dispute(evidence.dispute_id),
             {:ok, sys_id, bank_id, logo_id} <- resolve_scope(dispute),
             {:ok, config} <- get_config(sys_id, bank_id, logo_id, "evidence_storage_config") do
          EvidenceStore.adapter(backend).fetch(ref, config)
        end
    end
  end

  @doc "Delete an evidence document, regardless of backend."
  @spec delete(Ecto.UUID.t(), VmuCore.ASM.Operator.t() | nil) :: :ok | {:error, term()}
  def delete(evidence_id, operator) do
    case Repo.get(DisputeEvidence, evidence_id) do
      nil ->
        {:error, :not_found}

      %DisputeEvidence{backend: "db"} = evidence ->
        finish_delete(evidence, operator)

      %DisputeEvidence{} = evidence ->
        with {:ok, dispute} <- fetch_dispute(evidence.dispute_id),
             {:ok, sys_id, bank_id, logo_id} <- resolve_scope(dispute),
             {:ok, config} <- get_config(sys_id, bank_id, logo_id, "evidence_storage_config"),
             :ok <- EvidenceStore.adapter(evidence.backend).delete(evidence.storage_ref, config) do
          finish_delete(evidence, operator)
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp finish_delete(%DisputeEvidence{} = evidence, operator) do
    {:ok, _} = Repo.delete(evidence)
    AuditLog.record(operator, "dispute_evidence_delete", evidence.dispute_id, %{filename: evidence.filename})
    :ok
  end

  defp fetch_dispute(dispute_id) do
    case Repo.get(Dispute, dispute_id) do
      nil -> {:error, :dispute_not_found}
      dispute -> {:ok, dispute}
    end
  end

  defp resolve_scope(%Dispute{account_id: account_id}) do
    case Repo.get(Account, account_id) do
      %Account{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id} -> {:ok, sys_id, bank_id, logo_id}
      nil -> {:error, :account_not_found}
    end
  end

  defp get_config(sys_id, bank_id, logo_id, key) do
    case ModuleConfigEngine.get("dps", key, sys_id, bank_id, logo_id) do
      {:ok, value} -> {:ok, value}
      {:error, _} = err -> err
    end
  end

  defp operator_name(nil), do: "system"
  defp operator_name(%{username: username}), do: username
end
