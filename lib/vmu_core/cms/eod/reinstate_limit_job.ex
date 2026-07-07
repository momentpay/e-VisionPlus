defmodule VmuCore.CMS.EOD.ReinstateLimitJob do
  @moduledoc """
  EOD job: scan for expired temporary credit limits and reinstate originals.

  Enqueued once per day by `EodSchedulerJob`. Safe to run any time after midnight
  because it compares `expiry_date < today`. If a temp limit expires on 2026-07-31,
  the job running on 2026-08-01 reinstates the original limit.

  Idempotent: records whose status is already REINSTATED or SUPERSEDED are skipped
  by the query filter on `status = 'ACTIVE'`.
  """

  use Oban.Worker, queue: :eod, max_attempts: 3, unique: [period: 86_400]
  require Logger
  alias VmuCore.CMS.TempLimit

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"eod_date" => eod_date_str}}) do
    eod_date = Date.from_iso8601!(eod_date_str)

    Logger.info("[ReinstateLimitJob] Checking expired temp limits as of #{eod_date}")

    case TempLimit.reinstate_expired(eod_date) do
      {:ok, 0} ->
        Logger.info("[ReinstateLimitJob] No expired temp limits to reinstate")
        :ok

      {:ok, count} ->
        Logger.info("[ReinstateLimitJob] Reinstated #{count} temp limit(s)")
        :ok
    end
  end
end
