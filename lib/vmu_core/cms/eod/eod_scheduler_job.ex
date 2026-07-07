defmodule VmuCore.CMS.EOD.EodSchedulerJob do
  @moduledoc """
  EOD Billing Cycle Scheduler — Oban cron job that fires nightly to determine
  which billing cycles are due today and enqueue `LockAccountsJob` for each.

  ## How VisionPlus cycle scheduling works

  Every account has a `cycle_code` (2-digit string "01"–"31") representing the
  day of month on which that account's billing cycle closes and statement is
  generated. Accounts with `cycle_code = "15"` close their cycle on the 15th
  of each month, receive a statement, and start a new cycle on the 16th.

  This job runs at 21:00 each night (before the EOD batch window). It:

  1. Resolves today's date
  2. Calculates which cycle_codes map to today's day of month
  3. For each matching cycle_code, checks there are ACTIVE accounts on that code
  4. Enqueues one `LockAccountsJob` per due cycle_code, passing `eod_date` and
     `cycle_code` as arguments

  ## End-of-month edge case

  For months shorter than 31 days, accounts with `cycle_code` >= the day count
  of the current month have their cycle processed on the last day of the month.
  E.g., cycle_code "31" fires on February 28 (or 29 in leap years).

  ## Oban cron registration

  Add to `config.exs` Oban plugins:

      {Oban.Plugins.Cron, crontab: [
        {"0 21 * * *", VmuCore.CMS.EOD.EodSchedulerJob}
      ]}

  The job is also safe to trigger manually for a specific date:

      Oban.insert(VmuCore.CMS.EOD.EodSchedulerJob.new(%{"eod_date" => "2026-06-15"}))
  """

  use Oban.Worker, queue: :eod, max_attempts: 3

  require Logger
  import Ecto.Query

  alias VmuCore.{Repo, CMS.Account, CMS.EOD.LockAccountsJob, CMS.EOD.ReinstateLimitJob}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    eod_date = resolve_eod_date(args)
    Logger.info("[EODScheduler] Running for date=#{eod_date}")

    due_cycle_codes = due_cycle_codes_for(eod_date)

    if due_cycle_codes == [] do
      Logger.info("[EODScheduler] No active cycle_codes due on #{eod_date}")
      :ok
    else
      Logger.info("[EODScheduler] Enqueuing LockAccountsJob for cycle_codes=#{inspect(due_cycle_codes)}")

      jobs =
        Enum.map(due_cycle_codes, fn cycle_code ->
          LockAccountsJob.new(%{
            "eod_date"   => Date.to_iso8601(eod_date),
            "cycle_code" => cycle_code
          })
        end)

      Oban.insert_all(jobs)

      Logger.info("[EODScheduler] Enqueued #{length(jobs)} LockAccountsJob(s)")

      # Always run daily temp-limit reinstatement regardless of cycle activity
      Oban.insert(ReinstateLimitJob.new(%{"eod_date" => Date.to_iso8601(eod_date)}))

      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Returns the eod_date — from args if provided (manual trigger), else today
  defp resolve_eod_date(%{"eod_date" => date_str}) when is_binary(date_str) do
    Date.from_iso8601!(date_str)
  end

  defp resolve_eod_date(_args), do: Date.utc_today()

  # Returns the list of cycle_codes that have accounts due for EOD today.
  #
  # A cycle_code is "due" when its numeric value equals today's day,
  # OR when it is >= the number of days in this month (end-of-month rule).
  defp due_cycle_codes_for(date) do
    today_day    = date.day
    days_in_month = Date.days_in_month(date)

    # Codes that map to today: exact match + "overflow" codes if today = last day
    matching_codes =
      if today_day == days_in_month do
        # Last day of month — also sweep cycle codes that overflow (e.g., "29"–"31" in Feb)
        for day <- today_day..31//1, do: String.pad_leading(to_string(day), 2, "0")
      else
        [String.pad_leading(to_string(today_day), 2, "0")]
      end

    # Only enqueue for cycle_codes that actually have ACTIVE accounts today
    Repo.all(
      from a in Account,
        where: a.cycle_code in ^matching_codes
          and a.account_status in ["ACTIVE", "DELINQUENT"],
        distinct: true,
        select: a.cycle_code
    )
  end
end
