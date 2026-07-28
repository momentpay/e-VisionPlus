defmodule VmuCore.CMS.WalletTransferCommand do
  @moduledoc """
  Wallet-to-wallet transfer (Digital Wallet Phase W2, 2026-07-28).

  Deliberately doesn't invent new GL posting functions — a transfer is
  exactly the sender leg (`CMS.WalletWithdrawalCommand.withdraw/4`) and
  the receiver leg (`CMS.WalletFundingCommand.fund/1`, `channel:
  "INTERNAL_TRANSFER"` — a value that already existed in the same
  channel taxonomy `CMS.DebitFunding`/`CMS.WalletFunding` share, not a
  new one added for this), composed inside one outer `Repo.transaction`.
  Ecto's nested-transaction semantics make this safe: if either leg
  rolls back, the `with`/`else` below re-raises that failure at the
  outer transaction, so nothing partial is ever committed — verified
  with a real-data "money conservation" test (sum of both balances is
  identical before and after, in both the success and insufficient-funds
  cases).

  The `CMS.WalletTransfer` row is inserted FIRST, before either balance
  movement, so its own id can link the receiver's `WalletFunding` row
  back to it via `external_reference` — the only way to trace "this load
  came from that specific transfer" without adding a new FK column to
  `cms_wallet_fundings` that every other funding channel would carry as
  dead weight.
  """

  alias VmuCore.{Repo, CMS.WalletAccount, CMS.WalletTransfer,
                 CMS.WalletWithdrawalCommand, CMS.WalletFundingCommand}

  @doc """
  attrs = %{from_wallet_account_id:, to_wallet_account_id:, amount:,
            initiated_by:, reason: (optional)}
  """
  def transfer(attrs) do
    from_account = Repo.get!(WalletAccount, attrs.from_wallet_account_id)
    to_account = Repo.get!(WalletAccount, attrs.to_wallet_account_id)

    cond do
      from_account.wallet_account_id == to_account.wallet_account_id ->
        {:error, :cannot_transfer_to_self}

      from_account.currency != to_account.currency ->
        {:error, :currency_mismatch}

      not WalletAccount.active?(from_account) ->
        {:error, :sender_not_active}

      not WalletAccount.active?(to_account) ->
        {:error, :receiver_not_active}

      true ->
        Repo.transaction(fn ->
          with {:ok, wallet_transfer} <-
                 %WalletTransfer{}
                 |> WalletTransfer.changeset(%{
                   from_wallet_account_id: from_account.wallet_account_id,
                   to_wallet_account_id: to_account.wallet_account_id,
                   amount: attrs.amount,
                   currency: from_account.currency,
                   initiated_by: attrs.initiated_by,
                   reason: attrs[:reason]
                 })
                 |> Repo.insert(),
               idempotency_key = "wallet_transfer_out:#{wallet_transfer.id}",
               {:ok, _withdrawal} <-
                 WalletWithdrawalCommand.withdraw(
                   from_account.wallet_account_id, attrs.amount,
                   "Transfer to #{to_account.wallet_account_id}", idempotency_key
                 ),
               {:ok, _funding} <-
                 WalletFundingCommand.fund(%{
                   wallet_account_id: to_account.wallet_account_id, amount: attrs.amount,
                   channel: "INTERNAL_TRANSFER", external_reference: to_string(wallet_transfer.id),
                   posted_by: attrs.initiated_by
                 }) do
            wallet_transfer
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
    end
  end
end
