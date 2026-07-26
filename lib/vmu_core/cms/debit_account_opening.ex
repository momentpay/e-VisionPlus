defmodule VmuCore.CMS.DebitAccountOpening do
  @moduledoc """
  Opens a new `DebitAccount` (Way4 parity plan Phase 1 item 4, D1/D2).
  No CMS.Account is created — a debit account never has a credit-card
  row, per the schema decision in `docs/debit/DEBIT_Module_Requirements.md`.
  """

  alias VmuCore.{Repo, CMS.DebitAccount}

  @doc """
  attrs = %{customer_id:, sys_id:, bank_id:, logo_id:, block_id:,
            currency: (optional, default "AED")}
  """
  def open(attrs) do
    %DebitAccount{}
    |> DebitAccount.changeset(Map.put_new(attrs, :opened_at, Date.utc_today()))
    |> Repo.insert()
  end
end
