defmodule VmuCore.CMS.WalletFundingCommand do
  @moduledoc """
  Loads a `WalletAccount` (Digital Wallet Phase W1, 2026-07-28). Mirrors
  `CMS.DebitFundingCommand` exactly.
  """

  import Ecto.Query
  alias VmuCore.{Repo, CMS.WalletAccount, CMS.WalletFunding, CMS.InternalGlPoster}

  @doc """
  attrs = %{wallet_account_id:, amount:, channel:, posted_by:,
            external_reference: (required for external channels)}
  """
  def fund(attrs) do
    account = Repo.get!(WalletAccount, attrs.wallet_account_id)

    if not WalletAccount.active?(account) do
      {:error, :wallet_account_not_active}
    else
      idempotency_key = "wallet_load:#{attrs.wallet_account_id}:#{System.unique_integer([:positive])}"

      Repo.transaction(fn ->
        with {:ok, ledger_entry} <-
               InternalGlPoster.post_wallet_load(
                 attrs.wallet_account_id, attrs.amount, Date.utc_today(),
                 attrs.channel, idempotency_key
               ),
             {:ok, funding} <-
               %WalletFunding{}
               |> WalletFunding.changeset(Map.put(attrs, :ledger_entry_id, ledger_entry.entry_id))
               |> Repo.insert() do
          {1, _} =
            Repo.update_all(
              from(w in WalletAccount, where: w.wallet_account_id == ^account.wallet_account_id),
              inc: [available_balance: attrs.amount]
            )

          %{funding: funding, ledger_entry: ledger_entry}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def balance(wallet_account_id) do
    case Repo.get(WalletAccount, wallet_account_id) do
      nil -> {:error, :not_found}
      account -> {:ok, account.available_balance}
    end
  end
end
