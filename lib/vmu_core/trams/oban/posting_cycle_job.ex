defmodule VmuCore.TRAMS.Oban.PostingCycleJob do
  @moduledoc """
  Posting cycle — CLEARED → POSTED sweep (TRAM-P3 3B, spec 09 §2.2).

  Runs on the `:clearing` Oban queue (schedule via Oban cron, e.g. nightly
  after clearing file ingest):

      {"30 22 * * *", VmuCore.TRAMS.Oban.PostingCycleJob}

  Per run:
  1. `MatchingEngine.run_unmatched_sweep/1` — link any clearing records that
     landed since the last cycle.
  2. For every TRAM transaction in CLEARED state:
     - **Fraud-flagged** (open FLAG maintenance action) → skipped, not
       force-posted (spec 09 §2.2).
     - **Has a matched clearing record** → post through
       `FAS.SettlementPostingAdapter.confirm_one/1` — the SAME path the
       settlement_core HTTP confirm uses, with the same idempotency key
       (`"settlement:<approval_code>:<rrn>"`, ADR-T3), so double-posting is
       structurally impossible. On success append `transaction_posted`.
     - **No clearing record but the ledger already carries the settlement
       key** (settlement_core path posted first) → just append
       `transaction_posted` to sync the aggregate state.
     - **Neither** → still awaiting clearing; left in CLEARED.

  Idempotent and re-runnable: posting is keyed, the state transition is
  guarded by the state machine, and a crashed run resumes where it left off.
  """

  use Oban.Worker, queue: :clearing, max_attempts: 3

  require Logger
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.TRAMS.{Transaction, ClearingRecord, MatchingEngine, MaintenanceAction, EventStore}
  alias VmuCore.FAS.{AuthorizationRecord, SettlementPostingAdapter}
  alias VmuCore.CMS.LedgerEntry

  @batch_limit 500

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    match_stats = MatchingEngine.run_unmatched_sweep()

    post_stats =
      cleared_transactions()
      |> Enum.reduce(%{posted: 0, skipped_flagged: 0, awaiting_clearing: 0, errors: 0},
           fn txn, acc -> post_one(txn, acc) end)

    Logger.info("[TRAMS.PostingCycle] matched=#{match_stats.matched} " <>
                "exceptions=#{match_stats.exceptions} posted=#{post_stats.posted} " <>
                "flagged=#{post_stats.skipped_flagged} " <>
                "awaiting=#{post_stats.awaiting_clearing} errors=#{post_stats.errors}")

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp cleared_transactions do
    Repo.all(
      from t in Transaction,
        where: t.state == "CLEARED" and not is_nil(t.fas_authorization_id),
        order_by: [asc: t.inserted_at],
        limit: @batch_limit
    )
  end

  defp post_one(txn, acc) do
    cond do
      fraud_flagged?(txn.transaction_id) ->
        Map.update!(acc, :skipped_flagged, &(&1 + 1))

      not is_nil(txn.clearing_id) ->
        post_via_settlement_adapter(txn, acc)

      true ->
        sync_if_already_posted(txn, acc)
    end
  rescue
    e ->
      Logger.error("[TRAMS.PostingCycle] #{txn.transaction_id} crashed: #{Exception.message(e)}")
      Map.update!(acc, :errors, &(&1 + 1))
  end

  defp post_via_settlement_adapter(txn, acc) do
    auth     = Repo.get(AuthorizationRecord, txn.fas_authorization_id)
    clearing = Repo.get(ClearingRecord, txn.clearing_id)

    cond do
      is_nil(auth) or is_nil(auth.approval_code) or is_nil(auth.rrn) ->
        Logger.warning("[TRAMS.PostingCycle] #{txn.transaction_id} auth missing " <>
                       "approval_code/rrn — cannot build settlement key")
        Map.update!(acc, :errors, &(&1 + 1))

      true ->
        item = %{
          approval_code:  auth.approval_code,
          rrn:            auth.rrn,
          settled_amount: txn.settled_amount || (clearing && clearing.amount) || txn.amount,
          settled_date:   (clearing && clearing.settlement_date) || Date.utc_today()
        }

        case SettlementPostingAdapter.confirm_one(item) do
          :ok ->
            append_posted(txn, "posting_cycle")
            Map.update!(acc, :posted, &(&1 + 1))

          :not_found ->
            Logger.warning("[TRAMS.PostingCycle] confirm_one :not_found for " <>
                           "#{txn.transaction_id} (key mismatch?)")
            Map.update!(acc, :errors, &(&1 + 1))

          {:error, reason} ->
            Logger.error("[TRAMS.PostingCycle] confirm_one failed for " <>
                         "#{txn.transaction_id}: #{inspect(reason)}")
            Map.update!(acc, :errors, &(&1 + 1))
        end
    end
  end

  # No clearing file yet — but the settlement_core HTTP path may already have
  # posted the ledger entry. If so, sync the aggregate to POSTED.
  defp sync_if_already_posted(txn, acc) do
    auth = Repo.get(AuthorizationRecord, txn.fas_authorization_id)

    if auth && auth.approval_code && auth.rrn &&
         ledger_posted?("settlement:#{auth.approval_code}:#{auth.rrn}") do
      append_posted(txn, "settlement_core_confirm")
      Map.update!(acc, :posted, &(&1 + 1))
    else
      Map.update!(acc, :awaiting_clearing, &(&1 + 1))
    end
  end

  defp ledger_posted?(key) do
    Repo.exists?(from e in LedgerEntry, where: e.idempotency_key == ^key)
  end

  defp append_posted(txn, source) do
    case EventStore.append(txn.transaction_id, "transaction_posted",
           %{source: source}, actor: "system") do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("[TRAMS.PostingCycle] transaction_posted rejected for " <>
                       "#{txn.transaction_id}: #{inspect(reason)}")
    end
  end

  # Open FLAG maintenance action → transaction is held from posting
  defp fraud_flagged?(transaction_id) do
    Repo.exists?(
      from m in MaintenanceAction,
        where: m.transaction_id == ^transaction_id
           and m.action_type == "FLAG"
           and m.status in ["PENDING_APPROVAL", "APPROVED", "APPLIED"]
    )
  end
end
