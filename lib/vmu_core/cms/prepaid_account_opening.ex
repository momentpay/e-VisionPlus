defmodule VmuCore.CMS.PrepaidAccountOpening do
  @moduledoc """
  Opens a new `PrepaidAccount` (Way4 parity plan Phase 1 item 5, P1).
  """

  alias VmuCore.{Repo, CMS.PrepaidAccount}

  @doc """
  attrs = %{customer_id:, sys_id:, bank_id:, logo_id:, block_id:,
            currency: (optional, default "AED")}
  """
  def open(attrs) do
    %PrepaidAccount{}
    |> PrepaidAccount.changeset(Map.put_new(attrs, :opened_at, Date.utc_today()))
    |> Repo.insert()
  end
end
