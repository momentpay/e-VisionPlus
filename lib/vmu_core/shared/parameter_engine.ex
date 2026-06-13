defmodule VmuCore.Shared.ParameterEngine do
  @moduledoc """
  VisionPlus-compatible Parameter Engine with ETS-backed hierarchical cache.

  ## Architecture

  Mirrors VisionPlus's multi-tier parameter resolution model:

      Block (most specific)
        └─ Logo  (BIN range / card brand)
              └─ Bank  (institution)
                    └─ System  (global defaults)

  All parameters are loaded from PostgreSQL into a local ETS table on startup
  and refreshed on demand. Lookups execute in sub-millisecond time with zero
  database round-trips on the hot path — critical for the sub-50ms authorization
  SLA mandated by Visa/Mastercard interchange rules.

  ## Usage

      # Resolve APR for a specific cardholder's product
      {:ok, apr} = VmuCore.Shared.ParameterEngine.get("0001", "0010", "0100", "1000", :apr_percentage)

      # Lookup falls back through logo → bank → system if block has no explicit value
      {:ok, limit} = VmuCore.Shared.ParameterEngine.get("0001", "0010", "0100", "1000", :credit_limit_default)

  ## Refresh

  Call `refresh_all/0` after any parameter update to resync ETS from the database.
  """

  use GenServer
  require Logger

  import Ecto.Query, only: [from: 2]

  alias VmuCore.Repo
  alias VmuCore.Shared.{SysParameter, BankParameter, LogoParameter, BlockParameter}

  @table_name :vmu_parameter_cache

  # ---------------------------------------------------------------------------
  # Public Client API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the ParameterEngine GenServer and initialises the ETS cache.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Resolves a parameter value for a given SYS/BANK/LOGO/BLOCK context.

  Fallback cascade (Block → Logo → Bank → System):
  - If a value is explicitly set at Block level, it is returned immediately.
  - Otherwise falls back to Logo, then Bank, then System.
  - Returns `{:error, :parameter_not_found}` only when all four levels lack a value.

  ## Examples

      iex> ParameterEngine.get("0001", "0010", "0100", "1000", :apr_percentage)
      {:ok, #Decimal<24.00>}

      iex> ParameterEngine.get("0001", "0010", "0100", "1000", :unknown_param)
      {:error, :parameter_not_found}
  """
  @spec get(String.t(), String.t(), String.t(), String.t(), atom()) ::
          {:ok, term()} | {:error, :parameter_not_found}
  def get(sys_id, bank_id, logo_id, block_id, param_key) do
    resolve_cascade(sys_id, bank_id, logo_id, block_id, param_key)
  end

  @doc """
  Forces a full reload of all parameters from PostgreSQL into ETS.
  Safe to call at runtime after admin parameter updates.
  """
  @spec refresh_all() :: :ok
  def refresh_all do
    GenServer.call(__MODULE__, :refresh_all)
  end

  @doc """
  Returns the current ETS cache size for diagnostics/health checks.
  """
  @spec cache_size() :: non_neg_integer()
  def cache_size do
    :ets.info(@table_name, :size)
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    table = :ets.new(@table_name, [
      :named_table,
      :set,
      :public,
      {:read_concurrency, true}   # Many concurrent readers (switch workers)
    ])

    Logger.info("[ParameterEngine] ETS table created: #{@table_name}")

    # Load parameters from the database immediately on startup
    case load_all_parameters() do
      :ok ->
        Logger.info("[ParameterEngine] Cache warm — #{:ets.info(table, :size)} entries loaded")
        {:ok, %{table: table}}

      {:error, reason} ->
        Logger.error("[ParameterEngine] Failed to load parameters on startup: #{inspect(reason)}")
        # Still start — cache will be empty; callers get :parameter_not_found
        {:ok, %{table: table}}
    end
  end

  @impl true
  def handle_call(:refresh_all, _from, state) do
    before_size = :ets.info(@table_name, :size)
    :ets.delete_all_objects(@table_name)

    case load_all_parameters() do
      :ok ->
        after_size = :ets.info(@table_name, :size)
        Logger.info("[ParameterEngine] Cache refreshed: #{before_size} → #{after_size} entries")
        {:reply, :ok, state}

      {:error, reason} = err ->
        Logger.error("[ParameterEngine] Refresh failed: #{inspect(reason)}")
        {:reply, err, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Cache Resolution — Block → Logo → Bank → System cascade
  # ---------------------------------------------------------------------------

  defp resolve_cascade(sys_id, bank_id, logo_id, block_id, param_key) do
    # 1. Block level — most specific (product-specific override)
    case :ets.lookup(@table_name, {:block, sys_id, bank_id, logo_id, block_id, param_key}) do
      [{_, value}] ->
        {:ok, value}

      [] ->
        # 2. Logo level — BIN range / card brand defaults
        case :ets.lookup(@table_name, {:logo, sys_id, bank_id, logo_id, param_key}) do
          [{_, value}] ->
            {:ok, value}

          [] ->
            # 3. Bank level — institution-wide defaults
            case :ets.lookup(@table_name, {:bank, sys_id, bank_id, param_key}) do
              [{_, value}] ->
                {:ok, value}

              [] ->
                # 4. System level — global fallback (last resort)
                case :ets.lookup(@table_name, {:sys, sys_id, param_key}) do
                  [{_, value}] -> {:ok, value}
                  []           -> {:error, :parameter_not_found}
                end
            end
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Database Loading — bulk population of ETS from PostgreSQL
  # ---------------------------------------------------------------------------

  defp load_all_parameters do
    try do
      load_sys_parameters()
      load_bank_parameters()
      load_logo_parameters()
      load_block_parameters()
      :ok
    rescue
      e ->
        Logger.error("[ParameterEngine] DB load error: #{inspect(e)}")
        {:error, e}
    end
  end

  defp load_sys_parameters do
    Repo.all(from s in SysParameter, select: s)
    |> Enum.each(fn sys ->
      # Cache every field as a separate ETS entry keyed by {level, sys_id, field}
      :ets.insert(@table_name, {{:sys, sys.sys_id, :base_currency}, sys.base_currency})
      :ets.insert(@table_name, {{:sys, sys.sys_id, :description},   sys.description})
    end)
  end

  defp load_bank_parameters do
    Repo.all(from b in BankParameter, select: b)
    |> Enum.each(fn bank ->
      key = {bank.sys_id, bank.bank_id}
      :ets.insert(@table_name, {{:bank, bank.sys_id, bank.bank_id, :country_code}, bank.country_code})
      :ets.insert(@table_name, {{:bank, bank.sys_id, bank.bank_id, :description},  bank.description})
      _ = key  # suppress unused warning
    end)
  end

  defp load_logo_parameters do
    Repo.all(from l in LogoParameter, select: l)
    |> Enum.each(fn logo ->
      :ets.insert(@table_name, {{:logo, logo.sys_id, logo.bank_id, logo.logo_id, :bin_prefix},   logo.bin_prefix})
      :ets.insert(@table_name, {{:logo, logo.sys_id, logo.bank_id, logo.logo_id, :description},  logo.description})
    end)
  end

  defp load_block_parameters do
    Repo.all(from b in BlockParameter, select: b)
    |> Enum.each(fn blk ->
      key = {:block, blk.sys_id, blk.bank_id, blk.logo_id, blk.block_id}
      size = tuple_size(key)
      :ets.insert(@table_name, {Tuple.insert_at(key, size, :apr_percentage),           blk.apr_percentage})
      :ets.insert(@table_name, {Tuple.insert_at(key, size, :cash_advance_fee_percent), blk.cash_advance_fee_percent})
      :ets.insert(@table_name, {Tuple.insert_at(key, size, :credit_limit_default),     blk.credit_limit_default})
    end)
  end

  # ---------------------------------------------------------------------------
  # BIN-Based Logo Resolution  (used by the FAS switch to route by card number)
  # ---------------------------------------------------------------------------

  @doc """
  Resolves the logo for a given PAN (Primary Account Number) by matching the
  6-digit BIN prefix against cached logo_parameters entries.

  Returns `{:ok, {sys_id, bank_id, logo_id}}` or `{:error, :no_bin_match}`.

  ## Examples

      iex> ParameterEngine.resolve_bin("543210XXXXXX")
      {:ok, {"0001", "0010", "0100"}}
  """
  @spec resolve_bin(String.t()) :: {:ok, {String.t(), String.t(), String.t()}} | {:error, :no_bin_match}
  def resolve_bin(pan) when is_binary(pan) and byte_size(pan) >= 6 do
    bin = String.slice(pan, 0, 6)

    # Iterate ETS for bin_prefix entries — efficient since BIN table is typically small
    match_spec = [
      {{{:logo, :"$1", :"$2", :"$3", :bin_prefix}, bin}, [], [{{:"$1", :"$2", :"$3"}}]}
    ]

    case :ets.select(@table_name, match_spec) do
      [{sys_id, bank_id, logo_id} | _] -> {:ok, {sys_id, bank_id, logo_id}}
      []                               -> {:error, :no_bin_match}
    end
  end

  def resolve_bin(_), do: {:error, :no_bin_match}
end
