defmodule VmuCore.FAS.HotCardCache do
  @moduledoc """
  ETS-backed hot-card list for LOST/STOLEN/FRAUD-blocked accounts (FAS-P3 task 3B).

  Loads pan_tokens of all accounts with `block_code` in `["L", "S", "F"]` from
  `cms_accounts` at startup and refreshes every 5 minutes. The authorization hot
  path reads directly from the ETS table — zero GenServer message-passing on the
  critical path (pure `:ets.lookup/2`).

  Block code → RC mapping:
    - `L` (Lost)   → RC "43" (pickup card)
    - `S` (Stolen) → RC "43" (pickup card)
    - `F` (Fraud)  → RC "62" (restricted card)
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias VmuCore.CMS.Account
  alias VmuCore.Repo

  @table :vmu_hotcard_cache
  @refresh_ms :timer.minutes(5)

  # ---------------------------------------------------------------------------
  # Public API — called directly on the auth hot path
  # ---------------------------------------------------------------------------

  @doc """
  Checks whether a pan_token is currently in the hot card list.

  Reads directly from the ETS table — no GenServer message sent. Returns:
    - `:clean`               — not in hot list
    - `{:blocked, :lost_stolen}` — block_code L or S → RC "43"
    - `{:blocked, :fraud}`       — block_code F     → RC "62"
  """
  @spec check(String.t()) :: :clean | {:blocked, :lost_stolen} | {:blocked, :fraud}
  def check(pan_token) do
    case :ets.lookup(@table, pan_token) do
      [{_token, :lost_stolen}] -> {:blocked, :lost_stolen}
      [{_token, :fraud}]       -> {:blocked, :fraud}
      []                       -> :clean
    end
  rescue
    # Table not yet created (race at boot) — fail open, same as cache miss
    _ -> :clean
  end

  @doc "Forces an immediate synchronous refresh. Primarily for tests."
  @spec refresh() :: :ok
  def refresh do
    GenServer.call(__MODULE__, :force_refresh)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    load_blocked_cards()
    schedule_refresh()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:refresh, state) do
    load_blocked_cards()
    schedule_refresh()
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:force_refresh, _from, state) do
    load_blocked_cards()
    {:reply, :ok, state}
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp load_blocked_cards do
    rows =
      Repo.all(
        from a in Account,
          where: a.block_code in ["L", "S", "F"],
          select: {a.pan_token, a.block_code}
      )

    entries =
      Enum.map(rows, fn {token, code} ->
        {token, if(code in ["L", "S"], do: :lost_stolen, else: :fraud)}
      end)

    :ets.delete_all_objects(@table)
    :ets.insert(@table, entries)

    Logger.info("[FAS] HotCardCache loaded #{length(entries)} blocked card(s)")
  rescue
    e ->
      Logger.warning("[FAS] HotCardCache refresh failed: #{inspect(e)}")
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_ms)
  end
end
