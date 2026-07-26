defmodule VmuCore.CMS.DebitFundingCommand do
  @moduledoc """
  Deposits/loads a `DebitAccount` (Way4 parity plan Phase 1 item 4, D2).

  Every channel posts a real `cms_ledger_entries` row and increments
  `available_balance` in the same transaction — external channels
  (`EXTERNAL_BANK_TRANSFER`/`CASH_DEPOSIT`) are recorded with a channel
  tag + `external_reference` for future reconciliation, but there is no
  live bank-rail/cash-network call here (none exists anywhere in this
  codebase — confirmed before this decision, not assumed; same "data
  model now, real integration later" shape already shipped for Avenza's
  Prepaid `PrepaidLoad.channel`).
  """

  import Ecto.Query
  alias VmuCore.{Repo, CMS.DebitAccount, CMS.DebitFunding, CMS.InternalGlPoster}

  @doc """
  attrs = %{debit_account_id:, amount:, channel:, posted_by:,
            external_reference: (required for external channels)}
  """
  def fund(attrs) do
    account = Repo.get!(DebitAccount, attrs.debit_account_id)

    if not DebitAccount.active?(account) do
      {:error, :debit_account_not_active}
    else
      idempotency_key = "debit_deposit:#{attrs.debit_account_id}:#{System.unique_integer([:positive])}"

      Repo.transaction(fn ->
        with {:ok, ledger_entry} <-
               InternalGlPoster.post_debit_deposit(
                 attrs.debit_account_id, attrs.amount, Date.utc_today(),
                 attrs.channel, idempotency_key
               ),
             {:ok, funding} <-
               %DebitFunding{}
               |> DebitFunding.changeset(Map.put(attrs, :ledger_entry_id, ledger_entry.entry_id))
               |> Repo.insert() do
          {1, _} =
            Repo.update_all(
              from(d in DebitAccount, where: d.debit_account_id == ^account.debit_account_id),
              inc: [available_balance: attrs.amount]
            )

          %{funding: funding, ledger_entry: ledger_entry}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def balance(debit_account_id) do
    case Repo.get(DebitAccount, debit_account_id) do
      nil -> {:error, :not_found}
      account -> {:ok, account.available_balance}
    end
  end
end
