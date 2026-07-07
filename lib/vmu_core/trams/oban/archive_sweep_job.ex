defmodule VmuCore.TRAMS.Oban.ArchiveSweepJob do
  @moduledoc """
  Close + archive sweep (TRAM-P6 6F, spec 09 §2.5).

  Two passes, weekly (cron Sunday 02:00):

  1. **Close pass** — terminal-activity states (REVERSED / DECLINED / PAID /
     RESOLVED) idle past `trams_close_after_days` (default 90) →
     `transaction_closed` → CLOSED. Nothing else closes transactions, so this
     is the funnel into archival.
  2. **Archive pass** — CLOSED past `trams_archive_retention_days` (default
     365 since `closed_at`) → `transaction_archived` → ARCHIVED. A transaction
     with an **open dispute case is never archived** regardless of age
     (spec 09 §2.5) — eligibility checks dispute status, not just time.

  Rows stay in `trams_transactions` (state = ARCHIVED, excluded from hot ops
  queries by state filters); physical cold-storage relocation is a later
  infrastructure decision — the state transition is what gates the
  operational path today.
  """

  use Oban.Worker, queue: :clearing, max_attempts: 3

  require Logger
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.TRAMS.{Transaction, EventStore}
  alias VmuCore.DPS.Dispute

  @batch_limit 1000
  @closeable_states ~w[REVERSED DECLINED PAID RESOLVED]
  @open_dispute_statuses ~w[FILED RETRIEVAL_REQUESTED CHARGEBACK_FILED REPRESENTED PRE_ARB ARBITRATION]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    closed   = close_pass()
    archived = archive_pass()

    Logger.info("[TRAMS.ArchiveSweep] closed=#{closed} archived=#{archived}")
    :ok
  end

  # ---------------------------------------------------------------------------
  # Pass 1: terminal states → CLOSED
  # ---------------------------------------------------------------------------

  defp close_pass do
    close_after_days = Application.get_env(:vmu_core, :trams_close_after_days, 90)
    cutoff = DateTime.add(DateTime.utc_now(), -close_after_days * 86_400, :second)

    Repo.all(
      from t in Transaction,
        where: t.state in ^@closeable_states and t.updated_at < ^cutoff,
        limit: @batch_limit
    )
    |> Enum.count(fn txn ->
      append_ok?(txn.transaction_id, "transaction_closed",
                 %{after_days: close_after_days, from_state: txn.state})
    end)
  end

  # ---------------------------------------------------------------------------
  # Pass 2: CLOSED → ARCHIVED (never with an open dispute)
  # ---------------------------------------------------------------------------

  defp archive_pass do
    retention_days = Application.get_env(:vmu_core, :trams_archive_retention_days, 365)
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days * 86_400, :second)

    open_disputes =
      from d in Dispute,
        where: d.status in ^@open_dispute_statuses and not is_nil(d.trams_transaction_id),
        select: d.trams_transaction_id

    Repo.all(
      from t in Transaction,
        where: t.state == "CLOSED"
           and t.closed_at < ^cutoff
           and t.transaction_id not in subquery(open_disputes),
        limit: @batch_limit
    )
    |> Enum.count(fn txn ->
      append_ok?(txn.transaction_id, "transaction_archived",
                 %{retention_days: retention_days})
    end)
  end

  defp append_ok?(transaction_id, event_type, payload) do
    case EventStore.append(transaction_id, event_type, payload, actor: "system") do
      {:ok, _} ->
        true

      {:error, reason} ->
        Logger.warning("[TRAMS.ArchiveSweep] #{event_type} rejected for " <>
                       "#{transaction_id}: #{inspect(reason)}")
        false
    end
  rescue
    e ->
      Logger.error("[TRAMS.ArchiveSweep] #{transaction_id} crashed: #{Exception.message(e)}")
      false
  end
end
