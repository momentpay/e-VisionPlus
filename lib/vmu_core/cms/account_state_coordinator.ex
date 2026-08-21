defmodule VmuCore.CMS.AccountStateCoordinator do
  @moduledoc """
  Per-account GenServer registered in the Horde distributed registry.

  Holds live account state in memory:
    - open_to_buy       : remaining total credit available right now
    - cash_open_to_buy  : remaining cash advance sub-limit (ATM / manual cash)
    - credit_limit      : current total credit limit
    - cash_limit        : cash advance sub-limit (typically 30% of credit_limit)
    - account_status    : ACTIVE / BLOCKED / SUSPENDED etc.
    - delinquency_bucket: current DPD bucket (0, 30, 60, 90, 120+)
    - velocity_limits   : JSONB map of per-channel velocity rules

  Authorization calls `authorize/3` which serialises concurrent attempts via
  the GenServer message queue — no DB row locking required on the hot path.

  Cash advance transactions (channel :atm or mcc in
  `OtbReconciliation.cash_mcc_groups/0`) are checked against BOTH
  open_to_buy AND cash_open_to_buy — whichever is smaller is the effective
  limit.

  The process is idle-terminated after 30 minutes and restarted on next access.
  """

  use GenServer
  require Logger

  alias VmuCore.Repo
  alias VmuCore.CMS.{Account, OtbReconciliation}
  alias VmuCore.Shared.ParameterEngine
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
    `{:approved, response_code, updated_otb, updated_cash_otb}`
    `{:declined, response_code, reason}`

  Note the approved arity is 4, not 3 — `updated_cash_otb` is real and
  relied upon by `FAS.IncrementalHandler.extend_hold/7`.
  `FAS.Authorization.run_credit_authorization/1` normalizes down to a
  3-tuple before handing off to its own `handle_asc_result/2`, which is
  shared with Debit/Prepaid's genuinely-3-tuple results.
  """
  def authorize(account_id, amount, opts \\ []) do
    channel   = Keyword.get(opts, :channel, :pos)
    mcc       = Keyword.get(opts, :mcc, nil)
    currency  = Keyword.get(opts, :currency, "AED")
    supp_id   = Keyword.get(opts, :supplementary_account_id)
    sub_limit = Keyword.get(opts, :sub_limit)

    with {:ok, pid} <- ensure_started(account_id) do
      GenServer.call(pid, {:authorize, amount, channel, mcc, currency, supp_id, sub_limit}, 5_000)
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
        schedule_midnight_reset()
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
  def handle_call({:authorize, amount, channel, mcc, _currency, supp_id, sub_limit}, _from, state) do
    # Lazy-initialize supplementary OTB on first appearance (one DB query per supp_id per
    # process lifetime); do it here before do_authorize so both the check and the decrement
    # see the same already-initialized value — avoids double DB calls.
    state =
      if supp_id && sub_limit && not Map.has_key?(state.supplementary_otbs, supp_id) do
        remaining = init_supp_remaining(supp_id, sub_limit)
        %{state | supplementary_otbs: Map.put(state.supplementary_otbs, supp_id, remaining)}
      else
        state
      end

    result = do_authorize(state, amount, channel, mcc, supp_id, sub_limit)

    new_state =
      case result do
        {:approved, _rc, new_otb, new_cash_otb} ->
          supp_otbs =
            if supp_id && sub_limit do
              current = Map.get(state.supplementary_otbs, supp_id, sub_limit)
              Map.put(state.supplementary_otbs, supp_id, Decimal.sub(current, amount))
            else
              state.supplementary_otbs
            end

          %{state |
            open_to_buy:        new_otb,
            cash_open_to_buy:   new_cash_otb,
            daily_debit_count:  state.daily_debit_count + 1,
            daily_debit_amount: Decimal.add(state.daily_debit_amount, amount),
            supplementary_otbs: supp_otbs,
            last_activity:      DateTime.utc_now()
          }

        {:declined, _rc, _reason} ->
          state
      end

    {:reply, result, new_state, @idle_ms}
  end

  @impl true
  def handle_call({:reverse, _stan, amount}, _from, state) do
    new_otb      = Decimal.add(state.open_to_buy, amount)
    new_state    = %{state | open_to_buy: new_otb, last_activity: DateTime.utc_now()}
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
    delta   = Decimal.sub(new_limit, state.credit_limit)
    new_otb = Decimal.add(state.open_to_buy, delta)
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
  def handle_info(:midnight_reset, state) do
    new_state = %{state |
      daily_debit_count:  0,
      daily_debit_amount: Decimal.new(0),
      supplementary_otbs: %{}
    }
    schedule_midnight_reset()
    {:noreply, new_state, @idle_ms}
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.debug("[ASC] Idle timeout for account #{state.account_id} — shutting down")
    {:stop, :normal, state}
  end

  # ---------------------------------------------------------------------------
  # Authorization logic
  # ---------------------------------------------------------------------------

  defp do_authorize(state, amount, channel, mcc, supp_id \\ nil, sub_limit \\ nil) do
    cash_txn = cash_transaction?(channel, mcc)

    with :ok <- check_account_status(state),
         :ok <- check_supplementary_sub_limit(state, supp_id, sub_limit, amount),
         :ok <- check_single_txn_limit(state, amount),
         :ok <- check_daily_limits(state, amount),
         :ok <- check_open_to_buy(state, amount),
         :ok <- check_cash_otb(state, amount, cash_txn),
         :ok <- check_velocity(state, amount, channel),
         :ok <- VmuCore.HCS.LimitController.check_hcs_limits(state.account_id, amount, channel, mcc, cash_txn) do
      new_otb      = Decimal.sub(state.open_to_buy, amount)
      new_cash_otb =
        if cash_txn,
          do:   Decimal.sub(state.cash_open_to_buy || state.cash_limit || new_otb, amount),
          else: state.cash_open_to_buy

      # Debit HCS sub-limit + company pool after successful auth
      VmuCore.HCS.LimitController.debit_limits(state.account_id, amount)
      {:approved, "00", new_otb, new_cash_otb}
    else
      {:error, :account_not_active}          -> {:declined, "62", :account_not_active}
      {:error, :sub_limit_exceeded}          -> {:declined, "61", :sub_limit_exceeded}
      {:error, :single_txn_limit_exceeded}   -> {:declined, "61", :single_txn_limit_exceeded}
      {:error, :daily_count_limit_exceeded}  -> {:declined, "61", :daily_count_limit_exceeded}
      {:error, :daily_amount_limit_exceeded} -> {:declined, "61", :daily_amount_limit_exceeded}
      {:error, :insufficient_otb}            -> {:declined, "51", :insufficient_otb}
      {:error, :insufficient_cash_otb}       -> {:declined, "51", :insufficient_cash_otb}
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

  # A transaction is a cash advance if it comes in on the ATM channel or
  # if the MCC belongs to the cash-equivalent merchant category group
  defp cash_transaction?(:atm, _mcc), do: true
  defp cash_transaction?(_channel, mcc) when is_binary(mcc), do: mcc in OtbReconciliation.cash_mcc_groups()
  defp cash_transaction?(_channel, _mcc), do: false

  defp check_account_status(%{account_status: "ACTIVE"}), do: :ok
  defp check_account_status(_), do: {:error, :account_not_active}

  defp check_supplementary_sub_limit(_state, nil, _sub_limit, _amount), do: :ok
  defp check_supplementary_sub_limit(_state, _supp_id, nil, _amount), do: :ok

  defp check_supplementary_sub_limit(state, supp_id, sub_limit, amount) do
    # supplementary_otbs was already initialized in handle_call before do_authorize was called
    remaining = Map.get(state.supplementary_otbs, supp_id, sub_limit)

    if Decimal.compare(amount, remaining) == :gt,
      do: {:error, :sub_limit_exceeded},
      else: :ok
  end

  defp init_supp_remaining(supp_id, sub_limit) do
    # Query today's approved spend for this supplementary account to derive remaining.
    # One-time DB hit per supplementary account per process lifetime — acceptable
    # since the process was already started (load_state did a DB round-trip).
    today = Date.utc_today()

    spent =
      Repo.one(
        from r in VmuCore.FAS.AuthorizationRecord,
          where: r.account_id == ^supp_id
            and fragment("DATE(inserted_at) = ?", ^today)
            and r.rc == "00",
          select: coalesce(sum(r.amount), 0)
      ) || Decimal.new(0)

    Decimal.sub(sub_limit, spent) |> Decimal.max(Decimal.new(0))
  rescue
    _ -> sub_limit
  end

  defp check_single_txn_limit(%{sys_id: sid, bank_id: bid, logo_id: lid, block_id: blid}, amount) do
    case ParameterEngine.get(sid, bid, lid, blid, :single_txn_max) do
      {:ok, max} when not is_nil(max) ->
        if Decimal.compare(amount, max) == :gt,
          do: {:error, :single_txn_limit_exceeded},
          else: :ok
      _ -> :ok
    end
  end

  defp check_daily_limits(%{sys_id: sid, bank_id: bid, logo_id: lid, block_id: blid,
                             daily_debit_count: count, daily_debit_amount: total}, amount) do
    with :ok <- check_daily_count(ParameterEngine.get(sid, bid, lid, blid, :daily_txn_max_count), count),
         :ok <- check_daily_amount(ParameterEngine.get(sid, bid, lid, blid, :daily_txn_max_amount), total, amount) do
      :ok
    end
  end

  defp check_daily_count({:ok, max}, count) when not is_nil(max) do
    if count >= max, do: {:error, :daily_count_limit_exceeded}, else: :ok
  end
  defp check_daily_count(_, _), do: :ok

  defp check_daily_amount({:ok, max}, total, amount) when not is_nil(max) do
    if Decimal.compare(Decimal.add(total, amount), max) == :gt,
      do: {:error, :daily_amount_limit_exceeded},
      else: :ok
  end
  defp check_daily_amount(_, _, _), do: :ok

  defp check_open_to_buy(state, amount) do
    if Decimal.compare(amount, state.open_to_buy) != :gt do
      :ok
    else
      # OTB insufficient — check overlimit tolerance from logo params
      check_overlimit(state, amount)
    end
  end

  defp check_overlimit(%{sys_id: sid, bank_id: bid, logo_id: lid, block_id: blid,
                          credit_limit: cl, open_to_buy: otb}, amount) do
    with {:ok, true} <- ParameterEngine.get(sid, bid, lid, blid, :overlimit_allowed),
         {:ok, tol_pct} <- ParameterEngine.get(sid, bid, lid, blid, :overlimit_tolerance_pct),
         true <- not is_nil(tol_pct) and not is_nil(cl) do
      # balance_after_txn = current_balance + amount = (credit_limit - open_to_buy) + amount
      # approve if balance_after_txn <= credit_limit × (1 + tolerance_pct / 100)
      current_balance = Decimal.sub(cl, otb)
      balance_after   = Decimal.add(current_balance, amount)
      tolerance_factor = Decimal.add(Decimal.new(1), Decimal.div(tol_pct, Decimal.new(100)))
      max_balance     = Decimal.mult(cl, tolerance_factor)

      if Decimal.compare(balance_after, max_balance) != :gt,
        do: :ok,
        else: {:error, :insufficient_otb}
    else
      _ -> {:error, :insufficient_otb}
    end
  end

  # Only enforce cash OTB when:
  #   (a) this is a cash-equivalent transaction, and
  #   (b) the account has a cash_limit configured (nil means unconstrained)
  defp check_cash_otb(_state, _amount, false), do: :ok
  defp check_cash_otb(%{cash_open_to_buy: nil}, _amount, _cash), do: :ok
  defp check_cash_otb(%{cash_open_to_buy: cotb}, amount, true) do
    if Decimal.compare(amount, cotb) == :gt,
      do: {:error, :insufficient_cash_otb},
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

  defp query_today_totals(account_id) do
    today = Date.utc_today()

    result =
      Repo.one(
        from r in VmuCore.FAS.AuthorizationRecord,
          where: r.account_id == ^account_id
            and fragment("DATE(inserted_at) = ?", ^today)
            and r.rc == "00",
          select: %{count: count(r.id), total: coalesce(sum(r.amount), 0)}
      )

    count  = if result, do: result.count || 0, else: 0
    amount = if result, do: result.total || Decimal.new(0), else: Decimal.new(0)
    {count, amount}
  rescue
    _ -> {0, Decimal.new(0)}
  end

  defp schedule_midnight_reset do
    now = DateTime.utc_now()
    tomorrow = Date.add(DateTime.to_date(now), 1)
    midnight_utc = DateTime.new!(tomorrow, Time.new!(0, 0, 1), "Etc/UTC")
    ms_until_midnight = DateTime.diff(midnight_utc, now, :millisecond)
    Process.send_after(self(), :midnight_reset, ms_until_midnight)
  end

  # ⚠️ DEFECT, found 2026-08-05 during the GL Phase C2 reader migration.
  # NOT migrated to `GL.LedgerQuery` deliberately — migrating a query that can
  # never match would only entrench the bug.
  #
  # This looks for `cms_ledger_entries` rows with `transaction_code`
  # "AUTH_ECOM" / "AUTH_POS" / etc. Two reasons it always returns {0, 0}:
  #
  #   1. `LedgerEntry`'s changeset validates `transaction_code` against a fixed
  #      list of 11 codes. None begins with "AUTH_", so such a row cannot be
  #      inserted. `SELECT count(*) ... WHERE transaction_code LIKE 'AUTH_%'`
  #      returns 0 and always will.
  #
  #   2. More fundamentally, **authorizations never post to the GL** — by
  #      design. An auth is a reservation, not a financial event; only
  #      settlement posts. So the ledger is the wrong source for velocity.
  #
  # Consequence: `enforce_velocity/3` reads today_count = 0 and
  # today_amount = 0 on every call, so the daily COUNT limit never triggers,
  # and the daily AMOUNT check degrades to "is this single transaction over
  # the limit" — cumulative daily spend is not tracked at all.
  #
  # Correct source is `fas_authorizations` (account_id, channel, amount,
  # inserted_at), which is where authorizations actually land. Not changed here
  # because it alters authorization outcomes on the hot path: transactions that
  # pass today would begin to decline. That is a business decision, not a
  # refactor. See docs/gl/Phase_C2_Reader_Migration.md §6.
  # GL Phase C3: the query is gone, the defect is not.
  #
  # It provably returned {0, 0} on every call, so returning that literally is
  # **exactly behaviour-preserving** — no authorization outcome changes. What it
  # also removes is a database round-trip per authorization on the hot path,
  # which `CLAUDE.md` prohibits outright, in service of a result that was always
  # a constant.
  #
  # Keeping the dead query alive purely to preserve a legacy table read would
  # have been the worst of both: the defect, plus the cost, plus a reason not to
  # drop `cms_ledger_entries`.
  #
  # **Fixing velocity properly is still open**, and is still a business
  # decision, because the correct source (`fas_authorizations`) would start
  # declining transactions that pass today.
  defp query_today_velocity(_account_id, _channel_str) do
    {0, Decimal.new(0)}
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
        # Initialize daily counters from today's approved auth records —
        # a startup-only DB read; after this, counters are maintained in memory.
        {daily_count, daily_amount} = query_today_totals(account_id)

        # open_to_buy/cash_open_to_buy are reconstructed from durable holds,
        # not read off the (never-kept-in-sync) stored columns — see
        # OtbReconciliation's moduledoc for why. This is what makes a
        # process crash/restart/idle-timeout safe: the durable source
        # (fas_pending_holds) survives it even though this in-memory state
        # doesn't.
        otb = OtbReconciliation.reconstruct(account)

        {:ok, %{
          account_id:          account_id,
          sys_id:              account.sys_id,
          bank_id:             account.bank_id,
          logo_id:             account.logo_id,
          block_id:            account.block_id,
          account_status:      account.account_status,
          credit_limit:        account.credit_limit,
          open_to_buy:         otb.open_to_buy,
          cash_limit:          account.cash_limit,
          cash_open_to_buy:    otb.cash_open_to_buy,
          delinquency_bucket:  account.delinquency_bucket,
          velocity_limits:     account.velocity_limits,
          campaign_code:       account.campaign_code,
          daily_debit_count:   daily_count,
          daily_debit_amount:  daily_amount,
          supplementary_otbs:  %{},
          last_activity:       DateTime.utc_now()
        }}
    end
  end
end
