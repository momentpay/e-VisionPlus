defmodule VmuCore.CMS.AccountClosure do
  @moduledoc """
  Account closure workflow (CMS-G3.1, FR-CMS-007).

  ## Flow

      request_closure ──► balance zero + no holds + no open disputes?
            │                       │yes                │no
            │                  close now          BLOCKED (no new spend),
            │                                     closure pending until the
            │                                     sweep can zero-verify
            └── cancel_closure re-opens the request window

  - **Close preconditions** (all enforced): outstanding balance zero, no
    active pending holds (`fas_pending_holds`), no open DPS dispute case.
  - **Close effects**: status CLOSED + `close_date`, OTB zeroed, ASC
    notified, autopay mandate cancelled, `account_closed` event + audit.
  - **Reopen** (FR-CMS-007 reopen rules): allowed within
    `:cms_reopen_window_days` (default 30) of `close_date`.
  - `finalize_pending/0` is the sweep entry point
    (`AccountLifecycleSweepJob`) — retries pending closures nightly as
    balances pay down.
  """

  require Logger
  import Ecto.Query

  alias VmuCore.{Repo, CMS.Account, CMS.BalanceBucket, CMS.AccountStateCoordinator,
                 CMS.NonMonetaryEvent, CMS.Autopay}
  alias VmuCore.FAS.PendingHold
  alias VmuCore.DPS.Dispute
  alias VmuCore.ASM.AuditLog
  alias Decimal, as: D

  @system_operator_id "00000000-0000-0000-0000-000000000001"
  @open_dispute_statuses ~w[FILED RETRIEVAL_REQUESTED CHARGEBACK_FILED REPRESENTED PRE_ARB ARBITRATION]

  @doc """
  Request closure. Closes immediately when the account is already clean;
  otherwise blocks new spend and parks the request for the nightly sweep.

  Returns `{:ok, :closed | :pending, account}` or `{:error, reason}`.
  """
  @spec request_closure(Ecto.UUID.t(), String.t(), map() | nil) ::
          {:ok, :closed | :pending, Account.t()} | {:error, term()}
  def request_closure(account_id, reason, operator \\ nil) do
    case Repo.get(Account, account_id) do
      nil ->
        {:error, :account_not_found}

      %Account{account_status: "CLOSED"} ->
        {:error, :already_closed}

      %Account{closure_requested_at: ts} when not is_nil(ts) ->
        {:error, :closure_already_requested}

      %Account{} = account ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        record_event(account, "closure_requested", operator, reason,
          %{"status" => account.account_status}, %{"closure_requested_at" => to_string(now)})
        AuditLog.record(operator, "closure_requested", account_id, %{reason: reason})

        case close_blockers(account) do
          [] ->
            account
            |> stamp_request(now)
            |> do_close(operator)
            |> then(fn acct -> {:ok, :closed, acct} end)

          blockers ->
            Logger.info("[AccountClosure] Pending for #{account_id}: #{inspect(blockers)}")

            Repo.update_all(
              from(a in Account, where: a.account_id == ^account_id),
              set: [closure_requested_at: now, account_status: "BLOCKED",
                    updated_at: NaiveDateTime.utc_now()]
            )

            AccountStateCoordinator.notify_status_change(account_id, "BLOCKED")
            {:ok, :pending, Repo.get!(Account, account_id)}
        end
    end
  end

  @doc "Cancel a pending closure request — restores ACTIVE when we blocked it."
  @spec cancel_closure(Ecto.UUID.t(), map() | nil) :: {:ok, Account.t()} | {:error, term()}
  def cancel_closure(account_id, operator \\ nil) do
    case Repo.get(Account, account_id) do
      nil ->
        {:error, :account_not_found}

      %Account{closure_requested_at: nil} ->
        {:error, :no_pending_closure}

      %Account{account_status: "CLOSED"} ->
        {:error, :already_closed}

      %Account{} = account ->
        new_status = if account.account_status == "BLOCKED", do: "ACTIVE",
                     else: account.account_status

        Repo.update_all(
          from(a in Account, where: a.account_id == ^account_id),
          set: [closure_requested_at: nil, account_status: new_status,
                updated_at: NaiveDateTime.utc_now()]
        )

        AccountStateCoordinator.notify_status_change(account_id, new_status)
        record_event(account, "closure_cancelled", operator, nil, %{}, %{})
        AuditLog.record(operator, "closure_cancelled", account_id)

        {:ok, Repo.get!(Account, account_id)}
    end
  end

  @doc """
  Reopen a CLOSED account within the reopen window
  (`:cms_reopen_window_days`, default 30 days from close_date).
  """
  @spec reopen(Ecto.UUID.t(), map() | nil) :: {:ok, Account.t()} | {:error, term()}
  def reopen(account_id, operator \\ nil) do
    window_days = Application.get_env(:vmu_core, :cms_reopen_window_days, 30)

    case Repo.get(Account, account_id) do
      nil ->
        {:error, :account_not_found}

      %Account{account_status: status} when status != "CLOSED" ->
        {:error, {:not_closed, status}}

      %Account{close_date: close_date} = account ->
        if close_date && Date.diff(Date.utc_today(), close_date) <= window_days do
          Repo.update_all(
            from(a in Account, where: a.account_id == ^account_id),
            set: [account_status: "ACTIVE", close_date: nil,
                  closure_requested_at: nil, open_to_buy: account.credit_limit,
                  updated_at: NaiveDateTime.utc_now()]
          )

          AccountStateCoordinator.notify_status_change(account_id, "ACTIVE")
          record_event(account, "account_reopened", operator, nil,
            %{"close_date" => to_string(close_date)}, %{"status" => "ACTIVE"})
          AuditLog.record(operator, "account_reopened", account_id)

          {:ok, Repo.get!(Account, account_id)}
        else
          {:error, {:reopen_window_expired, close_date, window_days}}
        end
    end
  end

  @doc """
  Sweep entry point: retry every pending closure whose blockers have cleared.
  Returns `%{closed: n, still_blocked: n}`.
  """
  @spec finalize_pending() :: map()
  def finalize_pending do
    Repo.all(
      from a in Account,
        where: not is_nil(a.closure_requested_at) and a.account_status != "CLOSED"
    )
    |> Enum.reduce(%{closed: 0, still_blocked: 0}, fn account, acc ->
      case close_blockers(account) do
        [] ->
          do_close(account, nil)
          Map.update!(acc, :closed, &(&1 + 1))

        _blockers ->
          Map.update!(acc, :still_blocked, &(&1 + 1))
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @doc false
  def close_blockers(account) do
    []
    |> maybe_add(:outstanding_balance, nonzero_balance?(account.account_id))
    |> maybe_add(:active_holds, active_holds?(account.account_id))
    |> maybe_add(:open_dispute, open_dispute?(account.account_id))
  end

  defp maybe_add(list, blocker, true), do: [blocker | list]
  defp maybe_add(list, _blocker, false), do: list

  defp nonzero_balance?(account_id) do
    bucket =
      Repo.one(
        from b in BalanceBucket,
          where: b.account_id == ^account_id,
          order_by: [desc: b.balance_date],
          limit: 1
      )

    case bucket do
      nil -> false
      b -> D.compare(BalanceBucket.total(b), 0) != :eq
    end
  end

  defp active_holds?(account_id) do
    Repo.exists?(
      from h in PendingHold,
        where: h.account_id == ^account_id
           and is_nil(h.cleared_at) and is_nil(h.reversal_at)
    )
  end

  defp open_dispute?(account_id) do
    Repo.exists?(
      from d in Dispute,
        where: d.account_id == ^account_id and d.status in ^@open_dispute_statuses
    )
  end

  defp stamp_request(account, now) do
    Repo.update_all(
      from(a in Account, where: a.account_id == ^account.account_id),
      set: [closure_requested_at: now, updated_at: NaiveDateTime.utc_now()]
    )

    %{account | closure_requested_at: now}
  end

  defp do_close(account, operator) do
    Repo.update_all(
      from(a in Account, where: a.account_id == ^account.account_id),
      set: [account_status: "CLOSED", close_date: Date.utc_today(),
            open_to_buy: D.new(0), updated_at: NaiveDateTime.utc_now()]
    )

    AccountStateCoordinator.notify_status_change(account.account_id, "CLOSED")
    Autopay.cancel(account.account_id)

    record_event(account, "account_closed", operator, nil,
      %{"status" => account.account_status}, %{"status" => "CLOSED"})
    AuditLog.record(operator, "account_closed", account.account_id)

    Logger.info("[AccountClosure] Closed #{account.account_id}")
    Repo.get!(Account, account.account_id)
  end

  defp record_event(account, event_type, operator, reason, old_value, new_value) do
    NonMonetaryEvent.record(%{
      account_id:    account.account_id,
      event_type:    event_type,
      old_value:     old_value,
      new_value:     new_value,
      reason:        reason,
      operator_id:   (operator && operator.operator_id) || @system_operator_id,
      operator_role: if(operator, do: "SUPERVISOR", else: "SYSTEM")
    })
  end
end
