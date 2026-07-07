defmodule VmuCore.CMS.Oban.AutopayRunJob do
  @moduledoc """
  Daily autopay collection run (CMS-G2.2) — cron 06:00, after the previous
  night's EOD chain has finalized statements and aging.

  Delegates to `VmuCore.CMS.Autopay.run_due_mandates/1`. Safe to re-run:
  collection references are `"autopay:<account>:<due_date>"`, so a repeat
  run's collections are `:duplicate_payment` no-ops.
  """

  use Oban.Worker, queue: :eod, max_attempts: 3, unique: [period: 3600]

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    stats = VmuCore.CMS.Autopay.run_due_mandates(Date.utc_today())

    Logger.info("[AutopayRunJob] collected=#{stats.collected} " <>
                "zero=#{stats.skipped_zero} not_due=#{stats.not_due} " <>
                "failed=#{stats.failed}")

    if stats.failed > 0, do: {:error, {:collections_failed, stats.failed}}, else: :ok
  end
end
