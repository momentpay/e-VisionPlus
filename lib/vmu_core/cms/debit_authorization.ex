defmodule VmuCore.CMS.DebitAuthorization do
  @moduledoc """
  Real-time balance authorization for `DebitAccount` (Way4 parity plan
  Phase 1 item 4, D3).

  No Horde-registered per-account GenServer (unlike `AccountStateCoordinator`
  for credit) — a debit account has a single `available_balance` number,
  not a multi-level OTB cascade to protect, so a single atomic `UPDATE ...
  WHERE available_balance >= amount` is enough: Postgres MVCC handles the
  concurrent-authorization race, no explicit application-level lock
  needed. This is genuinely simpler than credit's model, not a shortcut —
  there's no cascade invariant here to protect with in-memory state.

  `authorize/2` is called from `FAS.Authorization.run_debit_authorization/1`
  on approval; `credit/2` restores balance on reversal/expiry/release,
  called from the same places credit's `AccountStateCoordinator.
  credit_open_to_buy/2` is (e.g. `TRAMS.Oban.AuthExpirySweepJob`).
  """

  import Ecto.Query
  alias VmuCore.{Repo, CMS.DebitAccount}

  @doc """
  Atomically decrements `available_balance` if sufficient funds exist.
  Returns `{:ok, new_balance}`, `{:error, :insufficient_funds}`,
  `{:error, :not_found}`, or `{:error, :not_active}`.
  """
  def authorize(debit_account_id, amount) do
    case Repo.get(DebitAccount, debit_account_id) do
      nil ->
        {:error, :not_found}

      %DebitAccount{status: status} when status != "ACTIVE" ->
        {:error, :not_active}

      _account ->
        {count, rows} =
          Repo.update_all(
            from(d in DebitAccount,
              where: d.debit_account_id == ^debit_account_id and d.available_balance >= ^amount,
              select: d.available_balance
            ),
            inc: [available_balance: Decimal.negate(amount)]
          )

        case {count, rows} do
          # `select:` on an UPDATE compiles to Postgres RETURNING, which
          # reflects the row AFTER the `inc:` has been applied — already
          # the post-decrement balance, not pre-decrement.
          {1, [new_balance]} -> {:ok, new_balance}
          _ -> {:error, :insufficient_funds}
        end
    end
  end

  @doc "Restores balance on reversal/expiry/release. No-op safety: never goes through the ACTIVE/found checks — a restore must always succeed even if the account was suspended after the hold was placed."
  def credit(debit_account_id, amount) do
    Repo.update_all(
      from(d in DebitAccount, where: d.debit_account_id == ^debit_account_id),
      inc: [available_balance: amount]
    )

    :ok
  end

  @doc """
  True if `id` resolves to a `DebitAccount` — used by shared credit-path
  touchpoints (`TRAMS.Oban.AuthExpirySweepJob`, `FAS.ReversalHandler`)
  that need to branch between restoring OTB vs. restoring
  `available_balance` for the same generic `fas_pending_holds.account_id`.
  """
  def debit_account?(id), do: not is_nil(Repo.get(DebitAccount, id))
end
