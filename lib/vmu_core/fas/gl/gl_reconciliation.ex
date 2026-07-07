defmodule VmuCore.FAS.GL.GlReconciliation do
  @moduledoc """
  Detects GL posting gaps for the FAS-P5 reconciliation requirement (5E).

  A settlement gap exists when a fas_authorization is approved (rc="00")
  but no corresponding `cms_ledger_entry` row with
  `idempotency_key = "settlement:<approval_code>:<rrn>"` exists.

  This indicates the settlement confirm call (from settlement_core) either
  never arrived, was rejected, or the GL post failed and rolled back.

  ## Usage

      {:ok, gaps} = GlReconciliation.find_unposted_settlements(~D[2026-07-01], ~D[2026-07-02])
      # => [{%AuthorizationRecord{}, nil | %LedgerEntry{}}]

  The second tuple element is always `nil` for now (no partial-post case) —
  kept for future extension where a LedgerEntry exists but is flagged invalid.
  """

  require Logger
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.FAS.AuthorizationRecord
  alias VmuCore.CMS.LedgerEntry

  @type gap :: {AuthorizationRecord.t(), nil}

  @doc """
  Returns approved authorizations in `[from_date, to_date]` that have no
  matching settlement LedgerEntry.

  Both dates are compared against `fas_authorizations.inserted_at` (UTC).
  """
  @spec find_unposted_settlements(Date.t(), Date.t()) :: {:ok, [gap()]}
  def find_unposted_settlements(%Date{} = from_date, %Date{} = to_date) do
    from_dt = DateTime.new!(from_date, ~T[00:00:00], "Etc/UTC")
    to_dt   = DateTime.new!(to_date,   ~T[23:59:59], "Etc/UTC")

    approved_auths =
      Repo.all(
        from a in AuthorizationRecord,
          where: a.rc == "00"
            and a.inserted_at >= ^from_dt
            and a.inserted_at <= ^to_dt
      )

    posted_keys =
      approved_auths
      |> Enum.map(fn a -> "settlement:#{a.approval_code}:#{a.rrn}" end)
      |> then(fn keys ->
        Repo.all(
          from e in LedgerEntry,
            where: e.idempotency_key in ^keys,
            select: e.idempotency_key
        )
      end)
      |> MapSet.new()

    gaps =
      Enum.filter(approved_auths, fn auth ->
        key = "settlement:#{auth.approval_code}:#{auth.rrn}"
        not MapSet.member?(posted_keys, key)
      end)
      |> Enum.map(fn auth -> {auth, nil} end)

    Logger.debug("[GlReconciliation] #{from_date}..#{to_date}: " <>
                 "#{length(approved_auths)} approved, #{length(gaps)} unposted")

    {:ok, gaps}
  end

  @doc """
  Summary counts for monitoring/alerting use.

      {:ok, %{approved: 150, posted: 148, unposted: 2}} =
        GlReconciliation.summary(~D[2026-07-01], ~D[2026-07-02])
  """
  @spec summary(Date.t(), Date.t()) :: {:ok, map()}
  def summary(%Date{} = from_date, %Date{} = to_date) do
    {:ok, gaps} = find_unposted_settlements(from_date, to_date)

    from_dt = DateTime.new!(from_date, ~T[00:00:00], "Etc/UTC")
    to_dt   = DateTime.new!(to_date,   ~T[23:59:59], "Etc/UTC")

    approved_count =
      Repo.one(
        from a in AuthorizationRecord,
          where: a.rc == "00"
            and a.inserted_at >= ^from_dt
            and a.inserted_at <= ^to_dt,
          select: count(a.id)
      ) || 0

    unposted_count = length(gaps)

    {:ok, %{
      approved: approved_count,
      posted:   approved_count - unposted_count,
      unposted: unposted_count
    }}
  end
end
