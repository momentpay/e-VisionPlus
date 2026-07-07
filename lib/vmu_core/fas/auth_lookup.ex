defmodule VmuCore.FAS.AuthLookup do
  @moduledoc """
  Auth record lookup for cross-system settlement verification (FAS-P4 4A).

  Called by settlement_core's VmuCoreAdapter over HTTP to verify that a cleared
  dump record's approval_code actually matches the fas_authorization for that RRN.
  Also used by SettlementPostingAdapter internally to find the auth record
  before posting ledger entries and clearing the pending hold.
  """

  alias VmuCore.FAS.AuthorizationRecord
  alias VmuCore.Repo
  import Ecto.Query

  @doc """
  Verify that a dump record's `auth_number` (approval_code in ISO 8583 DE38)
  matches the fas_authorization for the given RRN.

  Returns:
  - `:match`                — RRN found, approval_code agrees
  - `{:mismatch, actual}`   — RRN found, but approval_code differs (exception 5.5)
  - `:not_found`            — no approved auth with this RRN in fas_authorizations
  """
  @spec verify(String.t(), String.t()) :: :match | {:mismatch, String.t()} | :not_found
  def verify(rrn, approval_code) when is_binary(rrn) and is_binary(approval_code) do
    case Repo.one(
      from r in AuthorizationRecord,
        where: r.rrn == ^rrn and r.rc == "00",
        select: r.approval_code
    ) do
      nil            -> :not_found
      ^approval_code -> :match
      actual         -> {:mismatch, actual}
    end
  end

  @doc """
  Find a fas_authorization by (approval_code, rrn). Used by SettlementPostingAdapter
  to locate the record before posting and hold release. Returns nil when not found.
  """
  @spec by_approval_code_and_rrn(String.t(), String.t()) :: AuthorizationRecord.t() | nil
  def by_approval_code_and_rrn(approval_code, rrn)
      when is_binary(approval_code) and is_binary(rrn) do
    Repo.one(
      from r in AuthorizationRecord,
        where: r.approval_code == ^approval_code and r.rrn == ^rrn and r.rc == "00"
    )
  end

  @doc "Find a fas_authorization by approval_code alone. Returns nil when not found."
  @spec by_approval_code(String.t()) :: AuthorizationRecord.t() | nil
  def by_approval_code(code) when is_binary(code) do
    Repo.one(from r in AuthorizationRecord, where: r.approval_code == ^code and r.rc == "00")
  end
end
