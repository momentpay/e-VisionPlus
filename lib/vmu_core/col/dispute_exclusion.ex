defmodule VmuCore.COL.DisputeExclusion do
  @moduledoc """
  Cross-module check with DPS (COL-P7): open-dispute transactions should be
  excluded from collection pressure — the cross-cutting concern flagged in
  the module map (`docs/col/COL_Module_Requirements.md` §2, "← DPS |
  Exclusion") but never implemented ("Not found" in the original gap
  analysis).

  ## Scope (simplification, documented not hidden)

  COL escalation (write-off, agency placement) operates on the account's
  aggregate balance, not per-transaction — there is no COL data model for
  "this specific disputed transaction." Rather than attempt partial
  amount-splitting against `CMS.BalanceBucket.disputed_amount`, this is a hard
  gate: **any account with an open (non-terminal-status) dispute is excluded
  from write-off requests and agency placement entirely**, not just for the
  disputed amount. A future refinement could subtract `disputed_amount` from
  the write-off/placement basis instead of blocking the whole account — not
  attempted here.
  """

  import Ecto.Query
  alias VmuCore.DPS.Dispute

  @repo Application.compile_env(:vmu_col, :repo, VmuCore.Repo)

  @terminal_statuses ~w[CLOSED_WIN CLOSED_LOSE CANCELLED]

  @doc "Does this account have any dispute not yet in a terminal status?"
  @spec open_dispute?(Ecto.UUID.t()) :: boolean()
  def open_dispute?(account_id) do
    @repo.exists?(
      from d in Dispute,
        where: d.account_id == ^account_id and d.status not in ^@terminal_statuses
    )
  end
end
