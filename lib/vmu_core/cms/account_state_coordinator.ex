defmodule VmuCore.CMS.AccountStateCoordinator do
  @moduledoc """
  Per-account GenServer registered in the Horde distributed registry.

  Holds live account state in memory:
    - open_to_buy      : remaining credit available right now
    - account_status   : ACTIVE / BLOCKED / SUSPENDED etc.
    - delinquency_bucket: current DPD bucket (0, 30, 60, 90, 120+)
    - velocity_limits  : JSONB map of per-channel velocity rules

  Authorization calls `authorize/3` which serialises concurrent attempts via
  the GenServer message queue — no DB row locking required on the hot path.

  The process is idle-terminated after 30 minutes and restarted on next access.
  """

  use GenServer
  require Logger

  alias VmuCore.Repo
  alias VmuCore.CMS.Account
  import Ecto.Query

  @registry  VmuCore.Shared.Registry
  @supervisor VmuCore.Shared.AccountSupervisor
  @idle_ms    30 * 60 * 1_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Ensure the coordinator for `account_id` is running.
  Returns `{:ok, pid}` whether the process already existed or was just started.
  """
  def ensure_started(account_id) do
    case Horde.Registry.lookup(@registry, account_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        child_spec = %{
          id:      account_id,
          start:   {__MODULE__, :start_link, [account_id]},
          restart: :transient
        }
        case Horde.DynamicSupervisor.start_child(@supervisor, child_spec) do
          {:ok, pid}                      -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error                           -> error
        end
    end
  end

  @doc """
  Authorize a transaction for the account.

  Options:
    - `:channel`  — :pos | :atm | :contactless | :ecom  (default :pos)
    - `:mcc`      — 4-digit MCC string (optional)
    - `:currency` — ISO 4217 currency code (default "AED")

  Returns:
    `{:approved, response_code, updated_otb}`
    `{:declined, response_code, reason}`
  """
  def authorize(account_id, amount, opts \\ []) do
    channel  = Keyword.get(opts, :channel, :pos)
    mcc      = Keyword.get(opts, :mcc, nil)
    currency = Keyword.get(opts, :currency, "AED")

    with {:ok, pid} <- ensure_started(account_id) do
      GenServer.call(pid, {:authorize, amount, channel, mcc, currency}, 5_000)
    end
  end

  @doc "Restore OTB for a previously authorised but reversed/expired amount."
  def reverse(account_id, stan, amount) do
    with {:ok, pid} <- ensure_started(account_id) do
      GenServer.call(pid, {:reverse, stan, amount}, 5_000)
    end
  end

  @doc "Force-reload state from DB — call after EOD or manual limit adjustment."
  def refresh(account_id) do
    with {:ok, pid} <- ensure_started(account_id) do
      GenServer.call(pid, :refresh, 10_000)
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer lifecycle
  # ---------------------------------------------------------------------------

  def start_link(account_id) do
    GenServer.start_link(__MODULE__, account_id,
      name: {:via, Horde.Registry, {@registry, account_id}})
  end

  @impl true
  def init(account_id) do
    Logger.debug("[ASC] Starting coordinator for account #{account_id}")

    case load_state(account_id) do
      {:ok, state} ->
        {:ok, state, @idle_ms}

      {:error, reason} ->
        Logger.error("[ASC] Failed to load account #{account_id}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def handle_call({:authorize, amount, channel, mcc, _currency}, _from, state) do
    result = do_authorize(state, amount, channel, mcc)

    new_state =
      case result do
        {:approved, _rc, new_otb} ->
          %{state | open_to_buy: new_otb, last_activity: DateTime.utc_now()}

        {:declined, _rc, _reason} ->
          state
      end

    {:reply, result, new_state, @idle_ms}
  end

  @impl true
  def handle_call({:reverse, _stan, amount}, _from, state) do
    new_otb   = Decimal.add(state.open_to_buy, amount)
    new_state = %{state | open_to_buy: new_otb, last_activity: DateTime.utc_now()}
    {:reply, {:ok, new_otb}, new_state, @idle_ms}
  end

  @impl true
  def handle_call(:refresh, _from, %{account_id: account_id} = state) do
    case load_state(account_id) do
      {:ok, new_state} -> {:reply, :ok, new_state, @idle_ms}
      error            -> {:reply, error, state, @idle_ms}
    end
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.debug("[ASC] Idle timeout for account #{state.account_id} — shutting down")
    {:stop, :normal, state}
  end

  # ---------------------------------------------------------------------------
  # Authorization logic
  # ---------------------------------------------------------------------------

  defp do_authorize(state, amount, _channel, _mcc) do
    cond do
      state.account_status != "ACTIVE" ->
        {:declined, "62", :account_not_active}

      Decimal.compare(amount, state.open_to_buy) == :gt ->
        {:declined, "51", :insufficient_otb}

      true ->
        new_otb = Decimal.sub(state.open_to_buy, amount)
        {:approved, "00", new_otb}
    end
  end

  # ---------------------------------------------------------------------------
  # DB state load — only called on process start or explicit refresh
  # ---------------------------------------------------------------------------

  defp load_state(account_id) do
    query =
      from a in Account,
        where: a.account_id == ^account_id,
        limit: 1

    case Repo.one(query) do
      nil ->
        {:error, :account_not_found}

      account ->
        {:ok, %{
          account_id:         account_id,
          sys_id:             account.sys_id,
          bank_id:            account.bank_id,
          logo_id:            account.logo_id,
          block_id:           account.block_id,
          account_status:     account.account_status,
          credit_limit:       account.credit_limit,
          open_to_buy:        account.open_to_buy,
          delinquency_bucket: account.delinquency_bucket,
          velocity_limits:    account.velocity_limits,
          campaign_code:      account.campaign_code,
          last_activity:      DateTime.utc_now()
        }}
    end
  end
end
