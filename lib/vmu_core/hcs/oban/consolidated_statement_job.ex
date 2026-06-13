defmodule VmuCore.HCS.Oban.ConsolidatedStatementJob do
  @moduledoc """
  Oban job that generates consolidated HCS statements for all companies whose
  billing_cycle_day matches the statement_date.

  Cron: 30 23 * * * (23:30 — after individual EOD statements, before midnight).
  """

  use Oban.Worker, queue: :hcs, max_attempts: 3

  require Logger
  alias VmuCore.HCS.ConsolidatedStatementGenerator

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    statement_date =
      case Map.get(args, "statement_date") do
        nil      -> Date.utc_today()
        date_str -> Date.from_iso8601!(date_str)
      end

    Logger.info("[HCS/Statement] Generating consolidated statements for #{statement_date}")

    case ConsolidatedStatementGenerator.generate_for_date(statement_date) do
      {:ok, counts} ->
        Logger.info("[HCS/Statement] Generated #{counts.generated} statements, #{counts.failed} failed")
        :ok

      {:error, reason} ->
        Logger.error("[HCS/Statement] Failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
