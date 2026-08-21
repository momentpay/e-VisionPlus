defmodule VmuCore.CMS.EOD.ApplyCycleResegmentationJob do
  @moduledoc """
  EOD daily step (CMS FR-058) — applies any pending cycle_code changes
  whose configured notice period has elapsed (`CycleResegmentation.
  apply_due_changes/1`), then runs auto-rebalance proposals for any
  bank/logo scope configured `resegmentation_mode: "auto"`
  (`CycleResegmentation.run_auto_rebalance/0`).

  Always runs daily, independent of which cycle_codes are due for EOD
  close today — same "always run" slot `ReinstateLimitJob` already uses,
  since resegmentation effective dates are computed from notice-period
  math, not tied to any particular billing cycle's close date.
  """

  use Oban.Worker, queue: :eod, max_attempts: 3, unique: [period: 86_400]

  require Logger
  alias VmuCore.CMS.CycleResegmentation

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    eod_date = resolve_eod_date(args)

    applied = CycleResegmentation.apply_due_changes(eod_date)
    Logger.info("[EOD] Cycle resegmentation: applied #{applied} due change(s) for #{eod_date}")

    auto_proposed = CycleResegmentation.run_auto_rebalance()

    if auto_proposed > 0 do
      Logger.info("[EOD] Cycle resegmentation: auto-scheduled #{auto_proposed} rebalance move(s)")
    end

    :ok
  end

  defp resolve_eod_date(%{"eod_date" => date_str}) when is_binary(date_str), do: Date.from_iso8601!(date_str)
  defp resolve_eod_date(_args), do: Date.utc_today()
end
