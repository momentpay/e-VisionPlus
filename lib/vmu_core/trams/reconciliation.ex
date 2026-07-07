defmodule VmuCore.TRAMS.Reconciliation do
  @moduledoc """
  Three-way reconciliation: TRAM ↔ clearing files ↔ CMS ledger (TRAM-P6 6E,
  spec 09 §2.6, spec 11).

  Produces counts + amounts per side plus explicit break lists — so ops can
  triage without re-deriving totals (spec 09 §2.6: "a report, not just a
  pass/fail signal").

  ## Sides compared (for a posting-date range)

  - **TRAM**: transactions POSTED-or-later with `posted_at` in range
  - **Clearing**: MATCHED clearing records with `settlement_date` in range,
    plus the EXCEPTION count (unmatched — already a break by definition)
  - **Ledger**: `cms_ledger_entries` settlement postings
    (`idempotency_key LIKE 'settlement:%'`) with `posting_date` in range

  ## Break types

  - `:posted_without_ledger` — TRAM says POSTED but no settlement ledger key
    exists (posting event without the money movement — data integrity issue)
  - `:matched_not_posted` — clearing matched to a transaction that never
    reached POSTED (stuck in the pipeline past the expected cycle)
  """

  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.TRAMS.{Transaction, ClearingRecord}
  alias VmuCore.FAS.AuthorizationRecord
  alias VmuCore.CMS.LedgerEntry

  @break_list_limit 100
  @posted_states ~w[POSTED STATEMENTED PAID DISPUTED CHARGEBACKED RESOLVED CLOSED ARCHIVED]

  @doc """
  Reconciliation report for `[from_date, to_date]`.

  Returns `{:ok, report}` with `:tram` / `:clearing` / `:ledger` totals and
  `:breaks` lists (capped at #{@break_list_limit} each, with full counts).
  """
  @spec report(Date.t(), Date.t()) :: {:ok, map()}
  def report(%Date{} = from_date, %Date{} = to_date) do
    window_from = DateTime.new!(from_date, ~T[00:00:00], "Etc/UTC")
    window_to   = DateTime.new!(to_date, ~T[23:59:59], "Etc/UTC")

    {tram_count, tram_amount} =
      Repo.one(
        from t in Transaction,
          where: t.state in ^@posted_states
             and t.posted_at >= ^window_from
             and t.posted_at <= ^window_to,
          select: {count(t.transaction_id), coalesce(sum(coalesce(t.settled_amount, t.amount)), 0)}
      )

    {clr_count, clr_amount} =
      Repo.one(
        from c in ClearingRecord,
          where: c.match_status in ["MATCHED", "SETTLED"]
             and c.settlement_date >= ^from_date
             and c.settlement_date <= ^to_date,
          select: {count(c.clearing_id), coalesce(sum(c.amount), 0)}
      )

    exception_count =
      Repo.one(
        from c in ClearingRecord,
          where: c.match_status == "EXCEPTION",
          select: count(c.clearing_id)
      )

    {ledger_count, ledger_amount} =
      Repo.one(
        from e in LedgerEntry,
          where: like(e.idempotency_key, "settlement:%")
             and e.posting_date >= ^from_date
             and e.posting_date <= ^to_date,
          select: {count(e.entry_id), coalesce(sum(e.dr_amount), 0)}
      )

    posted_no_ledger = posted_without_ledger(window_from, window_to)
    matched_stale    = matched_not_posted(from_date, to_date)

    {:ok,
     %{
       period: %{from: from_date, to: to_date},
       tram:     %{count: tram_count,   amount: tram_amount},
       clearing: %{count: clr_count,    amount: clr_amount, open_exceptions: exception_count},
       ledger:   %{count: ledger_count, amount: ledger_amount},
       breaks: %{
         posted_without_ledger: %{
           count: length(posted_no_ledger),
           items: Enum.take(posted_no_ledger, @break_list_limit)
         },
         matched_not_posted: %{
           count: length(matched_stale),
           items: Enum.take(matched_stale, @break_list_limit)
         }
       },
       balanced?: tram_count == ledger_count and posted_no_ledger == [] and matched_stale == []
     }}
  end

  # ---------------------------------------------------------------------------
  # Break queries
  # ---------------------------------------------------------------------------

  # TRAM POSTED in window, but the settlement ledger key does not exist
  defp posted_without_ledger(window_from, window_to) do
    Repo.all(
      from t in Transaction,
        join: a in AuthorizationRecord, on: a.id == t.fas_authorization_id,
        where: t.state in ^@posted_states
           and t.posted_at >= ^window_from
           and t.posted_at <= ^window_to
           and not is_nil(a.approval_code)
           and not is_nil(a.rrn),
        left_join: e in LedgerEntry,
          on: e.idempotency_key ==
              fragment("'settlement:' || ? || ':' || ?", a.approval_code, a.rrn),
        where: is_nil(e.entry_id),
        select: %{transaction_id: t.transaction_id, account_id: t.account_id,
                  amount: coalesce(t.settled_amount, t.amount), posted_at: t.posted_at}
    )
  end

  # Clearing matched to a TRAM transaction that never reached POSTED
  defp matched_not_posted(from_date, to_date) do
    Repo.all(
      from c in ClearingRecord,
        join: t in Transaction, on: t.transaction_id == c.matched_transaction_id,
        where: c.match_status == "MATCHED"
           and c.settlement_date >= ^from_date
           and c.settlement_date <= ^to_date
           and t.state not in ^@posted_states,
        select: %{clearing_id: c.clearing_id, transaction_id: t.transaction_id,
                  state: t.state, amount: c.amount, settlement_date: c.settlement_date}
    )
  end
end
