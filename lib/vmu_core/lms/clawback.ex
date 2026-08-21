defmodule VmuCore.LMS.Clawback do
  @moduledoc """
  Reversal-aware accrual — points clawback on a won chargeback
  (FR-LMS-012). The other real gap `LMS_Gap_Implementation_Tracker.md`
  flagged as never addressed.

  ## Trigger and why

  Hooked into `VmuCore.DPS.Dispute.transition/2` on the transition to
  `CLOSED_WIN` only — per that module's own moduledoc, `CLOSED_WIN` means
  "the scheme reimburses; the Disputed Receivable is cleared... no
  customer-balance impact": the cardholder never actually pays for the
  disputed purchase. `CLOSED_LOSE`/`CANCELLED` re-debit the cardholder —
  they still owe for it and rightfully keep any points earned on it, so
  those do NOT claw back.

  ## Linkage: dispute -> transaction -> clearing record -> ledger entries

  `Dispute.trams_transaction_id` (a `TRAMS.Transaction`) is not the same
  identifier `PointsLedger.source_clearing_id` uses (a
  `TRAMS.ClearingRecord.clearing_id`) — earn is driven off MATCHED
  clearing records, not the transaction aggregate directly. The bridge is
  `ClearingRecord.matched_transaction_id`, set when the clearing record
  matched to that transaction.

  ## Scope, honestly limited

  Only claws back ledger entries still `ACTIVE` (not yet redeemed or
  expired) for that clearing record — mirrors `PointsExpiryJob`'s own
  scope exactly, same reasoning: an already-redeemed point can't be
  un-redeemed by this mechanism (the cardholder already received its
  value). This is a real, flagged limitation, not silently ignored — see
  `claw_back_transaction/1`'s return value.
  """

  require Logger
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.TRAMS.ClearingRecord
  alias VmuCore.LMS.{Account, PointsLedger}
  alias Decimal, as: D

  @doc """
  Claws back all still-ACTIVE points earned from clearing records matched
  to `trams_transaction_id`. No-op (`{:ok, %{clawed_back: 0, already_spent: 0}}`)
  if the transaction never earned any points (no LMS enrollment, no
  matched clearing record, or nothing was ever ACTIVE for it).

  Returns `{:ok, %{clawed_back: n, already_spent: n}}` — `already_spent`
  counts ledger entries that WERE earned from this transaction but are no
  longer ACTIVE (already redeemed or expired), logged as a known
  limitation rather than silently skipped.
  """
  @spec claw_back_transaction(Ecto.UUID.t()) :: {:ok, map()}
  def claw_back_transaction(trams_transaction_id) do
    clearing_ids =
      Repo.all(
        from c in ClearingRecord,
          where: c.matched_transaction_id == ^trams_transaction_id,
          select: c.clearing_id
      )

    if clearing_ids == [] do
      {:ok, %{clawed_back: 0, already_spent: 0}}
    else
      all_entries =
        Repo.all(from l in PointsLedger, where: l.source_clearing_id in ^clearing_ids)

      active_entries = Enum.filter(all_entries, &(&1.warehouse_state == "ACTIVE"))
      already_spent = length(all_entries) - length(active_entries)

      Enum.each(active_entries, &claw_back_entry/1)

      if already_spent > 0 do
        Logger.warning(
          "[LMS.Clawback] transaction=#{trams_transaction_id} — #{already_spent} " <>
          "ledger entr#{if already_spent == 1, do: "y was", else: "ies were"} already " <>
          "redeemed/expired, not clawed back (known limitation)"
        )
      end

      {:ok, %{clawed_back: length(active_entries), already_spent: already_spent}}
    end
  end

  defp claw_back_entry(%PointsLedger{} = entry) do
    Repo.transaction(fn ->
      Repo.update_all(
        from(l in PointsLedger, where: l.id == ^entry.id),
        set: [warehouse_state: "HISTORY"]
      )

      clawed_amount = D.negate(D.new(entry.points_amount))
      clawed_equiv = D.negate(D.new(entry.monetary_equiv || 0))

      %PointsLedger{}
      |> PointsLedger.changeset(%{
        lms_account_id:   entry.lms_account_id,
        transaction_type: "CLAWBACK",
        points_amount:    clawed_amount,
        monetary_equiv:   clawed_equiv,
        transaction_date: Date.utc_today(),
        posting_date:     Date.utc_today(),
        warehouse_state:  "HISTORY",
        scheme_id:        entry.scheme_id,
        idempotency_key:  "clawback_#{entry.id}",
        inserted_at:      DateTime.utc_now()
      })
      |> Repo.insert(on_conflict: :nothing, conflict_target: :idempotency_key)

      Repo.update_all(
        from(a in Account, where: a.id == ^entry.lms_account_id),
        inc: [points_balance: clawed_amount, open_to_redeem: clawed_amount]
      )

      Logger.info(
        "[LMS.Clawback] account=#{entry.lms_account_id} ledger_entry=#{entry.id} " <>
        "clawed_back=#{entry.points_amount}"
      )
    end)
  end
end
