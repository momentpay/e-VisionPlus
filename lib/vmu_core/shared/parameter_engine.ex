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
      base = {:sys, sys.sys_id}
      sz   = tuple_size(base)
      insert_param(base, sz, :base_currency,      sys.base_currency)
      insert_param(base, sz, :description,        sys.description)
      insert_param(base, sz, :batch_controls,     sys.batch_controls)
      insert_param(base, sz, :cycle_controls,     sys.cycle_controls)
      insert_param(base, sz, :global_status_codes, sys.global_status_codes)
      insert_param(base, sz, :posting_rules,      sys.posting_rules)
    end)
  end

  defp load_bank_parameters do
    Repo.all(from b in BankParameter, select: b)
    |> Enum.each(fn bank ->
      base = {:bank, bank.sys_id, bank.bank_id}
      sz   = tuple_size(base)
      insert_param(base, sz, :country_code,       bank.country_code)
      insert_param(base, sz, :description,        bank.description)
      insert_param(base, sz, :tax_rule,           bank.tax_rule)
      insert_param(base, sz, :gl_mapping_profile, bank.gl_mapping_profile)
      insert_param(base, sz, :delinquency_rules,  bank.delinquency_rules)
      insert_param(base, sz, :settlement_calendar, bank.settlement_calendar)
      insert_param(base, sz, :swift_bic,          bank.swift_bic)
      # Multi-org isolation fields (4C)
      insert_param(base, sz, :base_currency,      bank.base_currency)
      insert_param(base, sz, :billing_timezone,   bank.billing_timezone)
      insert_param(base, sz, :regulatory_regime,  bank.regulatory_regime)
      insert_param(base, sz, :org_name,           bank.org_name)
      # Market-level payment + bureau config (CMS-G1)
      insert_param(base, sz, :payment_channels_enabled, bank.payment_channels_enabled)
      insert_param(base, sz, :credit_reporting_format,  bank.credit_reporting_format)
    end)
  end

  defp load_logo_parameters do
    Repo.all(from l in LogoParameter, select: l)
    |> Enum.each(fn logo ->
      base = {:logo, logo.sys_id, logo.bank_id, logo.logo_id}
      sz   = tuple_size(base)

      # Core identification
      insert_param(base, sz, :bin_prefix,          logo.bin_prefix)
      insert_param(base, sz, :description,         logo.description)

      # Interest rates
      insert_param(base, sz, :purchase_apr,              logo.purchase_apr)
      insert_param(base, sz, :cash_apr,                  logo.cash_apr)
      insert_param(base, sz, :penalty_apr,               logo.penalty_apr)
      insert_param(base, sz, :penalty_apr_dpd_trigger,   logo.penalty_apr_dpd_trigger)
      insert_param(base, sz, :penalty_apr_cure_rule,     logo.penalty_apr_cure_rule)
      insert_param(base, sz, :repayment_hierarchy_order, logo.repayment_hierarchy_order)
      insert_param(base, sz, :promo_apr,                 logo.promo_apr)

      # Fees
      insert_param(base, sz, :annual_fee,          logo.annual_fee)
      insert_param(base, sz, :late_fee,            logo.late_fee)
      insert_param(base, sz, :overlimit_fee,       logo.overlimit_fee)
      insert_param(base, sz, :replacement_fee,     logo.replacement_fee)
      insert_param(base, sz, :returned_payment_fee, logo.returned_payment_fee)

      # Billing behaviour
      insert_param(base, sz, :min_payment_pct,     logo.min_payment_pct)
      insert_param(base, sz, :min_payment_floor,   logo.min_payment_floor)
      insert_param(base, sz, :grace_days,          logo.grace_days)
      insert_param(base, sz, :cash_limit_pct,      logo.cash_limit_pct)
      insert_param(base, sz, :statement_cycle_days, logo.statement_cycle_days)

      # Auth flags
      insert_param(base, sz, :ecom_enabled,        logo.ecom_enabled)
      insert_param(base, sz, :atm_enabled,         logo.atm_enabled)
      insert_param(base, sz, :intl_enabled,        logo.intl_enabled)
      insert_param(base, sz, :contactless_enabled, logo.contactless_enabled)
      insert_param(base, sz, :recurring_enabled,   logo.recurring_enabled)
      insert_param(base, sz, :moto_enabled,        logo.moto_enabled)

      # Transaction limits (3F)
      insert_param(base, sz, :single_txn_max,       logo.single_txn_max)
      insert_param(base, sz, :daily_txn_max_count,  logo.daily_txn_max_count)
      insert_param(base, sz, :daily_txn_max_amount, logo.daily_txn_max_amount)

      # Credit limit bounds
      insert_param(base, sz, :credit_limit_default, logo.credit_limit_default)
      insert_param(base, sz, :credit_limit_max,     logo.credit_limit_max)

      # STIP fields (4H)
      insert_param(base, sz, :stip_enabled,        logo.stip_enabled)
      insert_param(base, sz, :stip_floor_limit,    logo.stip_floor_limit)
      insert_param(base, sz, :stip_max_amount,     logo.stip_max_amount)

      # Card replacement fee (4F)
      insert_param(base, sz, :card_replacement_fee, logo.card_replacement_fee)
    end)
  end

  defp insert_param(_base, _sz, _key, nil), do: :ok
  defp insert_param(base, sz, key, value) do
    :ets.insert(@table_name, {Tuple.insert_at(base, sz, key), value})
  end

  defp load_block_parameters do
    Repo.all(from b in BlockParameter, select: b)
    |> Enum.each(fn blk ->
      base = {:block, blk.sys_id, blk.bank_id, blk.logo_id, blk.block_id}
      sz   = tuple_size(base)
      insert_param(base, sz, :apr_percentage,           blk.apr_percentage)
      insert_param(base, sz, :cash_apr_percentage,      blk.cash_apr_percentage)
      insert_param(base, sz, :cash_advance_fee_percent, blk.cash_advance_fee_percent)
      insert_param(base, sz, :credit_limit_default,     blk.credit_limit_default)
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
