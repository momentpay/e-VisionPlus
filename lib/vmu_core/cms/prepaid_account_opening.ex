defmodule VmuCore.CMS.PrepaidAccountOpening do
  @moduledoc """
  Opens a new `PrepaidAccount` (Way4 parity plan Phase 1 item 5, P1).

  Also records a `CMS.Arrangement` row in the same transaction (Koṣa
  domain-model alignment, 2026-07-28) — the real cross-product index a
  customer's admin detail page reads from.
  """

  alias VmuCore.{Repo, CMS.PrepaidAccount, CMS.Arrangements}

  @doc """
  attrs = %{customer_id:, sys_id:, bank_id:, logo_id:, block_id:,
            currency: (optional, default "AED")}
  """
  def open(attrs) do
    Repo.transaction(fn ->
      with {:ok, account} <-
             %PrepaidAccount{}
             |> PrepaidAccount.changeset(Map.put_new(attrs, :opened_at, Date.utc_today()))
             |> Repo.insert(),
           {:ok, _arrangement} <-
             Arrangements.record(%{
               customer_id: account.customer_id, product_type: "PREPAID",
               account_ref: account.prepaid_account_id, opened_at: account.opened_at
             }) do
        account
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end
end
