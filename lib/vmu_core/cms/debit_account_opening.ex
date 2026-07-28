defmodule VmuCore.CMS.DebitAccountOpening do
  @moduledoc """
  Opens a new `DebitAccount` (Way4 parity plan Phase 1 item 4, D1/D2).
  No CMS.Account is created — a debit account never has a credit-card
  row, per the schema decision in `docs/debit/DEBIT_Module_Requirements.md`.

  Also records a `CMS.Arrangement` row in the same transaction (Koṣa
  domain-model alignment, 2026-07-28) — the real cross-product index a
  customer's admin detail page reads from.
  """

  alias VmuCore.{Repo, CMS.DebitAccount, CMS.Arrangements}

  @doc """
  attrs = %{customer_id:, sys_id:, bank_id:, logo_id:, block_id:,
            currency: (optional, default "AED")}
  """
  def open(attrs) do
    Repo.transaction(fn ->
      with {:ok, account} <-
             %DebitAccount{}
             |> DebitAccount.changeset(Map.put_new(attrs, :opened_at, Date.utc_today()))
             |> Repo.insert(),
           {:ok, _arrangement} <-
             Arrangements.record(%{
               customer_id: account.customer_id, product_type: "DEBIT",
               account_ref: account.debit_account_id, opened_at: account.opened_at
             }) do
        account
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end
end
