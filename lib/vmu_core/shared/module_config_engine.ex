defmodule VmuCore.Shared.ModuleConfigEngine do
  @moduledoc """
  ETS-backed cache + cascade resolver for the generic Module Configuration Framework
  (2026-07-08). Mirrors `VmuCore.Shared.ParameterEngine`'s cache-and-cascade shape, but
  for arbitrary per-module JSON config instead of ParameterEngine's fixed columns.

  Cascade: logo → bank → system DB rows, then the key's catalog default
  (`VmuCore.Shared.ModuleConfigCatalog.fetch/2`). Unlike ParameterEngine, an unset key
  is not an error as long as the catalog defines a default — `{:error, :unknown_key}`
  only means the module never registered that key at all.

  Call `refresh_all/0` after any write — `VmuCore.Shared.ModuleConfigWriter` does this
  automatically.
  """

  use GenServer
  require Logger

  import Ecto.Query, only: [from: 2]

  alias VmuCore.Repo
  alias VmuCore.Shared.{ModuleConfigEntry, ModuleConfigCatalog}

  @table_name :vmu_module_config_cache

  # ---------------------------------------------------------------------------
  # Public Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Resolves a module config value, cascading logo → bank → system → catalog default.

  `bank_id`/`logo_id` default to `""` (system-scope lookup only needs `sys_id`).
  """
  @spec get(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, term()} | {:error, :unknown_key}
  def get(module, key, sys_id, bank_id \\ "", logo_id \\ "") do
    case lookup_row(module, key, sys_id, bank_id, logo_id) do
      {:ok, value} ->
        {:ok, value}

      :not_found ->
        case ModuleConfigCatalog.fetch(module, key) do
          nil -> {:error, :unknown_key}
          spec -> {:ok, spec.default}
        end
    end
  end

  @spec refresh_all() :: :ok
  def refresh_all do
    GenServer.call(__MODULE__, :refresh_all)
  end

  @spec cache_size() :: non_neg_integer()
  def cache_size do
    :ets.info(@table_name, :size)
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table_name, [
        :named_table,
        :set,
        :public,
        {:read_concurrency, true}
      ])

    Logger.info("[ModuleConfigEngine] ETS table created: #{@table_name}")

    case load_all() do
      :ok ->
        Logger.info("[ModuleConfigEngine] Cache warm — #{:ets.info(table, :size)} entries loaded")
        {:ok, %{table: table}}

      {:error, reason} ->
        Logger.error("[ModuleConfigEngine] Failed to load config on startup: #{inspect(reason)}")
        {:ok, %{table: table}}
    end
  end

  @impl true
  def handle_call(:refresh_all, _from, state) do
    before_size = :ets.info(@table_name, :size)
    :ets.delete_all_objects(@table_name)

    case load_all() do
      :ok ->
        after_size = :ets.info(@table_name, :size)
        Logger.info("[ModuleConfigEngine] Cache refreshed: #{before_size} → #{after_size} entries")
        {:reply, :ok, state}

      {:error, reason} = err ->
        Logger.error("[ModuleConfigEngine] Refresh failed: #{inspect(reason)}")
        {:reply, err, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Cache Resolution
  # ---------------------------------------------------------------------------

  defp lookup_row(module, key, sys_id, bank_id, logo_id) do
    with :not_found <- ets_get({"logo", sys_id, bank_id, logo_id, module, key}),
         :not_found <- ets_get({"bank", sys_id, bank_id, "", module, key}) do
      ets_get({"system", sys_id, "", "", module, key})
    end
  end

  defp ets_get(cache_key) do
    case :ets.lookup(@table_name, cache_key) do
      [{_, value}] -> {:ok, value}
      [] -> :not_found
    end
  end

  # ---------------------------------------------------------------------------
  # Database Loading
  # ---------------------------------------------------------------------------

  defp load_all do
    try do
      Repo.all(from c in ModuleConfigEntry, select: c)
      |> Enum.each(fn c ->
        key = {c.scope_type, c.sys_id, c.bank_id, c.logo_id, c.module, c.config_key}
        :ets.insert(@table_name, {key, Map.get(c.value, "v")})
      end)

      :ok
    rescue
      e ->
        Logger.error("[ModuleConfigEngine] DB load error: #{inspect(e)}")
        {:error, e}
    end
  end
end
