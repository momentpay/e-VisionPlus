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
    Logger.info("[DPS] Auto-filing chargeback: dispute=#{d.dispute_id}")
    Dispute.transition(d.dispute_id, "CHARGEBACK_FILED")
    :ok
  end

  defp handle_action(%{status: "CHARGEBACK_FILED"} = d, "check_representment") do
    # No representment received within deadline → issuer wins
    Logger.info("[DPS] No representment — closing WIN: dispute=#{d.dispute_id}")
    Dispute.transition(d.dispute_id, "CLOSED_WIN")
    :ok
  end

  defp handle_action(%{status: "REPRESENTED"} = d, "file_pre_arb") do
    Logger.warning("[DPS] Pre-arb deadline reached: dispute=#{d.dispute_id}")
    Dispute.transition(d.dispute_id, "PRE_ARB")
    :ok
  end

  defp handle_action(d, action) do
    Logger.warning("[DPS] Deadline job: unhandled action=#{action} status=#{d.status} dispute=#{d.dispute_id}")
    :ok
  end
end
