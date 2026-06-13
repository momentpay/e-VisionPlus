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

  @doc "Update in-memory credit limit without a full DB reload."
  def refresh_limit(account_id, new_limit) do
    case Horde.Registry.lookup(@registry, account_id) do
      [{pid, _}] -> GenServer.cast(pid, {:set_limit, new_limit})
      []         -> :ok
    end
  end

  @doc "Add amount back to OTB (fee waiver, manual credit)."
  def credit_open_to_buy(account_id, amount) do
    case Horde.Registry.lookup(@registry, account_id) do
      [{pid, _}] -> GenServer.cast(pid, {:credit_otb, amount})
      []         -> :ok
    end
  end

  @doc "Notify in-memory coordinator of a status change (closure, suspension, etc.)."
  def notify_status_change(account_id, new_status) do
    case Horde.Registry.lookup(@registry, account_id) do
      [{pid, _}] -> GenServer.cast(pid, {:set_status, new_status})
      []         -> :ok
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
  def handle_cast({:set_limit, new_limit}, state) do
    new_otb = Decimal.add(state.open_to_buy, Decimal.sub(new_limit, state.credit_limit))
    {:noreply, %{state | credit_limit: new_limit, open_to_buy: new_otb}, @idle_ms}
  end

  @impl true
  def handle_cast({:credit_otb, amount}, state) do
    {:noreply, %{state | open_to_buy: Decimal.add(state.open_to_buy, amount)}, @idle_ms}
  end

  @impl true
  def handle_cast({:set_status, new_status}, state) do
    {:noreply, %{state | account_status: new_status}, @idle_ms}
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.debug("[ASC] Idle timeout for account #{state.account_id} — shutting down")
    {:stop, :normal, state}
  end

  # ---------------------------------------------------------------------------
  # Authorization logic
  # ---------------------------------------------------------------------------

  defp do_authorize(state, amount, channel, mcc) do
    with :ok <- check_account_status(state),
         :ok <- check_open_to_buy(state, amount),
         :ok <- check_velocity(state, amount, channel),
         :ok <- VmuCore.HCS.LimitController.check_hcs_limits(state.account_id, amount, channel, mcc) do
      new_otb = Decimal.sub(state.open_to_buy, amount)
      # Debit HCS sub-limit + company pool after successful auth
      VmuCore.HCS.LimitController.debit_limits(state.account_id, amount)
      {:approved, "00", new_otb}
    else
      {:error, :account_not_active}          -> {:declined, "62", :account_not_active}
      {:error, :insufficient_otb}            -> {:declined, "51", :insufficient_otb}
      {:error, :velocity_count_exceeded}     -> {:declined, "65", :velocity_count_exceeded}
      {:error, :velocity_amount_exceeded}    -> {:declined, "65", :velocity_amount_exceeded}
      {:error, :company_suspended}           -> {:declined, "62", :company_suspended}
      {:error, :individual_limit_exceeded}   -> {:declined, "51", :individual_limit_exceeded}
      {:error, :company_pool_exhausted}      -> {:declined, "51", :company_pool_exhausted}
      {:error, :mcc_blocked}                 -> {:declined, "57", :mcc_blocked}
      {:error, :mcc_not_allowed}             -> {:declined, "57", :mcc_not_allowed}
      {:error, :channel_blocked}             -> {:declined, "57", :channel_blocked}
      {:error, :per_txn_cap_exceeded}        -> {:declined, "61", :per_txn_cap_exceeded}
      {:error, reason}                       -> {:declined, "05", reason}
    end
  end

  defp check_account_status(%{account_status: "ACTIVE"}), do: :ok
  defp check_account_status(_), do: {:error, :account_not_active}

  defp check_open_to_buy(state, amount) do
    if Decimal.compare(amount, state.open_to_buy) == :gt,
      do: {:error, :insufficient_otb},
      else: :ok
  end

  defp check_velocity(%{velocity_limits: nil}, _amount, _channel), do: :ok
  defp check_velocity(%{velocity_limits: limits, account_id: account_id}, amount, channel) do
    channel_str = to_string(channel)
    channel_limits = Map.get(limits, channel_str, %{})

    daily_count_limit  = Map.get(channel_limits, "daily_count")
    daily_amount_limit = Map.get(channel_limits, "daily_amount")

    if is_nil(daily_count_limit) and is_nil(daily_amount_limit) do
      :ok
    else
      {today_count, today_amount} = query_today_velocity(account_id, channel_str)

      cond do
        not is_nil(daily_count_limit) and today_count >= daily_count_limit ->
          {:error, :velocity_count_exceeded}

        not is_nil(daily_amount_limit) and
            Decimal.compare(Decimal.add(today_amount, Decimal.new(amount)),
                            Decimal.new(daily_amount_limit)) == :gt ->
          {:error, :velocity_amount_exceeded}

        true ->
          :ok
      end
    end
  end

  defp query_today_velocity(account_id, channel_str) do
    today = Date.utc_today()

    result =
      Repo.one(
        from e in VmuCore.CMS.LedgerEntry,
          where: e.account_id == ^account_id
            and e.posting_date == ^today
            and e.transaction_code == ^"AUTH_#{String.upcase(channel_str)}",
          select: %{count: count(e.entry_id), total: coalesce(sum(e.dr_amount), 0)}
      )

    count  = if result, do: result.count  || 0, else: 0
    total  = if result, do: result.total  || Decimal.new(0), else: Decimal.new(0)
    {count, total}
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
