defmodule VmuCore.TRAMS.Oban.AuthExpirySweepJob do
  @moduledoc """
  Authorization auto-expiry sweep (TRAM-P4 4A, spec 06 §3.1 / 09 §2.3).

  An authorization that is never cleared within its hold period permanently
  ties up the cardholder's open-to-buy. This nightly sweep (cron 23:00, after
  the 22:30 posting cycle has consumed any clearing that DID arrive) releases
  them:

  1. Finds `fas_pending_holds` past `expires_at` + grace, still active
     (`cleared_at` and `reversal_at` both null).
  2. Skips holds whose transaction is already in flight to posting — the TRAM
     aggregate is in CLEARED/POSTED (clearing arrived; the posting path owns
     the hold), or the settlement ledger key already exists.
  3. For the rest: sets `reversal_at` on the hold, credits OTB back via
     `AccountStateCoordinator.credit_open_to_buy/2` (outside the DB
     transaction — ASC is an in-memory GenServer), and appends
     `authorization_expired` → REVERSED to the TRAM aggregate.

  Complements (does not replace) `FAS.HoldAgingMonitor`, which only *alerts*
  on expired holds — this job is the actor. The monitor's 60-minute threshold
  fires long before this sweep's grace elapses, so ops see stuck holds before
  they are auto-reversed.

  ## Configuration

      config :vmu_core, :trams_auth_expiry_grace_hours, 24   # default

  Grace is ON TOP of the hold's own `expires_at` (7 days standard at creation).
  """

  use Oban.Worker, queue: :clearing, max_attempts: 3

  require Logger
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.FAS.{PendingHold, AuthorizationRecord}
  alias VmuCore.CMS.{AccountStateCoordinator, LedgerEntry}
  alias VmuCore.TRAMS.EventStore

  @batch_limit 500

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    grace_hours = Application.get_env(:vmu_core, :trams_auth_expiry_grace_hours, 24)
    cutoff      = DateTime.add(DateTime.utc_now(), -grace_hours * 3600, :second)

    stats =
      expired_holds(cutoff)
      |> Enum.reduce(%{reversed: 0, skipped_in_flight: 0, errors: 0}, fn hold, acc ->
        sweep_one(hold, acc)
      end)

    Logger.info("[TRAMS.AuthExpirySweep] reversed=#{stats.reversed} " <>
                "in_flight=#{stats.skipped_in_flight} errors=#{stats.errors}")

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp expired_holds(cutoff) do
    Repo.all(
      from h in PendingHold,
        where: is_nil(h.cleared_at) and is_nil(h.reversal_at) and h.expires_at < ^cutoff,
        order_by: [asc: h.expires_at],
        limit: @batch_limit
    )
  end

  defp sweep_one(hold, acc) do
    auth = Repo.get(AuthorizationRecord, hold.fas_authorization_id)
    txn  = auth && EventStore.by_fas_authorization(auth.id)

    if clearing_in_flight?(auth, txn) do
      Map.update!(acc, :skipped_in_flight, &(&1 + 1))
    else
      do_reverse(hold, auth, txn)
      Map.update!(acc, :reversed, &(&1 + 1))
    end
  rescue
    e ->
      Logger.error("[TRAMS.AuthExpirySweep] hold #{hold.id} crashed: #{Exception.message(e)}")
      Map.update!(acc, :errors, &(&1 + 1))
  end

  # Clearing has arrived (aggregate advanced past auth states) or settlement
  # was already posted — the posting path owns this hold, don't reverse it.
  defp clearing_in_flight?(auth, txn) do
    cond do
      txn && txn.state not in ["AUTHORIZED", "AUTH_MAINTENANCE"] ->
        true

      auth && auth.approval_code && auth.rrn ->
        Repo.exists?(
          from e in LedgerEntry,
            where: e.idempotency_key == ^"settlement:#{auth.approval_code}:#{auth.rrn}"
        )

      true ->
        false
    end
  end

  defp do_reverse(hold, auth, txn) do
    {:ok, _} =
      Repo.transaction(fn ->
        # Re-check under lock — a settlement confirm may have cleared it since
        # the sweep query ran
        locked =
          Repo.one(
            from h in PendingHold,
              where: h.id == ^hold.id and is_nil(h.cleared_at) and is_nil(h.reversal_at),
              lock: "FOR UPDATE"
          )

        if locked do
          locked
          |> PendingHold.reverse_changeset(DateTime.utc_now())
          |> Repo.update!()
        end

        locked
      end)

    # OTB restore outside the DB transaction — ASC is an in-memory GenServer.
    # credit_open_to_buy (not ASC.reverse): the STAN-keyed pending entry in ASC
    # state is long gone after the multi-day hold period.
    if hold.account_id do
      AccountStateCoordinator.credit_open_to_buy(hold.account_id, hold.hold_amount)
    end

    if txn do
      case EventStore.append(txn.transaction_id, "authorization_expired", %{
             hold_id: hold.id,
             released_amount: hold.hold_amount,
             expired_at: hold.expires_at
           }, actor: "system") do
        {:ok, _} -> :ok
        {:error, reason} ->
          Logger.warning("[TRAMS.AuthExpirySweep] authorization_expired rejected " <>
                         "for #{txn.transaction_id}: #{inspect(reason)}")
      end
    end

    Logger.info("[TRAMS.AuthExpirySweep] Released expired hold #{hold.id} " <>
                "amount=#{hold.hold_amount} account=#{hold.account_id}")
  end
end
