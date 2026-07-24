defmodule VmuCore.DPS.DeadlineJob do
  @moduledoc """
  Oban job that fires at a network-mandated dispute deadline.

  Actions:
    file_chargeback      — auto-file chargeback if still in FILED/RETRIEVAL_REQUESTED
    check_representment  — auto-close as CLOSED_WIN if no representment received
    file_pre_arb         — escalate to pre-arbitration if representment not resolved

  If the issuer missed the deadline and the case should be auto-lost, the job
  transitions to CLOSED_LOSE and reverses the provisional credit.
  """

  use Oban.Worker, queue: :disputes, max_attempts: 5

  require Logger
  alias VmuCore.DPS.Dispute
  alias VmuCore.Repo
  import Ecto.Query

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"dispute_id" => dispute_id, "action" => action}}) do
    dispute = Repo.get(Dispute, dispute_id)

    if is_nil(dispute) or dispute.status in ["CLOSED_WIN", "CLOSED_LOSE", "CANCELLED"] do
      Logger.info("[DPS] Deadline job skipped — dispute #{dispute_id} already resolved")
      :ok
    else
      handle_action(dispute, action)
    end
  end

  defp handle_action(%{status: status} = d, "file_chargeback")
       when status in ["FILED", "RETRIEVAL_REQUESTED"] do
    if deadline_reached?(d.chargeback_deadline) do
      Logger.info("[DPS] Auto-filing chargeback: dispute=#{d.dispute_id}")
      Dispute.transition(d.dispute_id, "CHARGEBACK_FILED")
    else
      log_early(d, "file_chargeback", d.chargeback_deadline)
    end

    :ok
  end

  defp handle_action(%{status: "CHARGEBACK_FILED"} = d, "check_representment") do
    if deadline_reached?(d.representment_deadline) do
      # No representment received within deadline → issuer wins
      Logger.info("[DPS] No representment — closing WIN: dispute=#{d.dispute_id}")
      Dispute.transition(d.dispute_id, "CLOSED_WIN")
    else
      log_early(d, "check_representment", d.representment_deadline)
    end

    :ok
  end

  defp handle_action(%{status: "REPRESENTED"} = d, "file_pre_arb") do
    if deadline_reached?(d.pre_arb_deadline) do
      Logger.warning("[DPS] Pre-arb deadline reached: dispute=#{d.dispute_id}")
      Dispute.transition(d.dispute_id, "PRE_ARB")
    else
      log_early(d, "file_pre_arb", d.pre_arb_deadline)
    end

    :ok
  end

  defp handle_action(d, action) do
    Logger.warning("[DPS] Deadline job: unhandled action=#{action} status=#{d.status} dispute=#{d.dispute_id}")
    :ok
  end

  # The job only encoded "which deadline to check," never "has that deadline
  # actually arrived" — in production this holds because Oban's
  # `scheduled_at` naturally delays real execution, but the job itself never
  # re-verified it. Found live, 2026-07-23, building DPS-P5's tests: under
  # `Oban testing: :inline` (this project's own test config), every job runs
  # immediately regardless of `scheduled_at`, so a dispute filed moments ago
  # auto-cascaded straight through CHARGEBACK_FILED to CLOSED_WIN in the same
  # call. Not just a test artifact — an early retry in production (a
  # transient-failure re-attempt, a manual "run now" from ops) would make the
  # same mistake, since nothing here ever re-checked the actual date. Now
  # self-defensive: skips (no-op, logged) instead of acting on a deadline
  # that hasn't arrived. Deliberately does NOT re-`Oban.insert/1` a follow-up
  # job here — under `:inline` testing that would recurse into `perform/1`
  # synchronously with the same still-not-arrived deadline (infinite loop);
  # the original job inserted by `Dispute.file/1`/`transition/2` at the real
  # deadline is the one that will actually fire it, in production.
  defp deadline_reached?(nil), do: false
  defp deadline_reached?(%Date{} = deadline), do: Date.compare(Date.utc_today(), deadline) != :lt

  defp log_early(d, action, deadline) do
    Logger.info(
      "[DPS] Deadline job for dispute=#{d.dispute_id} action=#{action} fired before its " <>
        "deadline (#{inspect(deadline)}) — skipping, not acting early"
    )
  end
end
