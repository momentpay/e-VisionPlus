defmodule VmuCore.DPS.EvidenceStore.DbStore do
  @moduledoc """
  Real, working evidence storage backend — stores nothing itself.

  The `db` backend keeps evidence bytes directly in `dps_dispute_evidence.data`;
  `VmuCore.DPS.Evidence` (the context module) writes/reads that column directly, so
  this adapter has nothing external to do. It exists purely to keep
  `VmuCore.DPS.EvidenceStore`'s three-backend dispatch uniform.
  """

  @behaviour VmuCore.DPS.EvidenceStore

  @impl true
  def store(_dispute_id, _filename, _content_type, _data, _config), do: {:ok, nil}

  @impl true
  def fetch(_storage_ref, _config), do: {:error, :use_row_data_column}

  @impl true
  def delete(_storage_ref, _config), do: :ok
end
