defmodule VmuCore.CMS.WalletWithdrawalCommand do
  @moduledoc """
  Atomic, balance-guarded debit from a `WalletAccount` (Digital Wallet
  Phase W1, 2026-07-28). Mirrors `CMS.DebitAuthorization`'s atomic
  `UPDATE ... WHERE available_balance >= amount` pattern — same
  reasoning: a wallet has a single balance number, not a multi-level
  cascade to protect, so Postgres MVCC handles the concurrent-withdrawal
  race without an application-level lock.

  Used directly by account closure (must reach zero balance) and,
  starting Phase W2, by wallet-to-wallet transfer's sender leg.
  """

  import Ecto.Query
  alias VmuCore.{Repo, CMS.WalletAccount, CMS.InternalGlPoster}

  @doc """
  Withdraws `amount`, posting a GL entry and decrementing
  `available_balance` atomically in one transaction. Returns
  `{:ok, %{ledger_entry:, new_balance:}}`, `{:error, :insufficient_funds}`,
  `{:error, :not_found}`, or `{:error, :not_active}`.
  """
  def withdraw(wallet_account_id, amount, narrative, idempotency_key) do
    case Repo.get(WalletAccount, wallet_account_id) do
      nil ->
        {:error, :not_found}

      %WalletAccount{status: status} when status != "ACTIVE" ->
        {:error, :not_active}

      _account ->
        Repo.transaction(fn ->
          {count, rows} =
            Repo.update_all(
              from(w in WalletAccount,
                where: w.wallet_account_id == ^wallet_account_id and w.available_balance >= ^amount,
                select: w.available_balance
              ),
              inc: [available_balance: Decimal.negate(amount)]
            )

          case {count, rows} do
            {1, [new_balance]} ->
              case InternalGlPoster.post_wallet_withdrawal(
                     wallet_account_id, amount, Date.utc_today(), narrative, idempotency_key
                   ) do
                {:ok, ledger_entry} -> %{ledger_entry: ledger_entry, new_balance: new_balance}
                {:error, reason} -> Repo.rollback(reason)
              end

            _ ->
              Repo.rollback(:insufficient_funds)
          end
        end)
    end
  end
end
