defmodule VmuCore.FAS.STIP do
  @moduledoc """
  Stand-In Processing (STIP) for issuer authorization when the CMS is unreachable.

  VisionPlus behaviour:
    - If AccountStateCoordinator is unavailable (timeout or node failure),
      check the per-logo STIP threshold from ETS.
    - Amount ≤ max_amount  → approve with RC "00" and log for EOD reconciliation.
    - Amount  > max_amount → decline with RC "91" (switch inoperative).

  Thresholds are loaded from `stip_thresholds` at application startup via
  `load_thresholds/1` and cached in `:vmu_stip_cache` ETS table.
  """

  require Logger

  @table :vmu_stip_cache

  @doc "Initialise the ETS cache. Called by Application or test setup."
  def init_cache do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, {:read_concurrency, true}])
    end

    :ok
  end

  @doc """
  Load (or reload) all STIP thresholds from the database into ETS.
  Safe to call at runtime after threshold updates.
  """
  def load_thresholds(repo) do
    import Ecto.Query
    alias VmuCore.CMS.StipThreshold

    repo.all(from s in StipThreshold, select: s)
    |> Enum.each(fn row ->
      :ets.insert(@table, {{row.sys_id, row.logo_id}, row.max_amount})
    end)

    :ok
  end

  @doc """
  Attempt STIP authorization for the given logo and amount.
  Returns `{:stip_approved, "00"}` or `{:stip_declined, "91"}`.
  """
  def authorize(sys_id, logo_id, amount) do
    case :ets.lookup(@table, {sys_id, logo_id}) do
      [{_, threshold}] ->
        if Decimal.compare(amount, threshold) != :gt do
          Logger.warning("[STIP] Offline approval: sys=#{sys_id} logo=#{logo_id} amount=#{amount}")
          {:stip_approved, "00"}
        else
          Logger.warning("[STIP] Exceeds threshold — declining offline: amount=#{amount} threshold=#{threshold}")
          {:stip_declined, "91"}
        end

      [] ->
        # No threshold configured for this logo — decline safely
        {:stip_declined, "91"}
    end
  end
end
