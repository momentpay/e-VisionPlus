defmodule VmuCore.ITS.Oban.Its1BatchJob do
  @moduledoc "Runs ITS1 extraction. Cron: 0 21 * * * (before TRAMS at 21:30)."
  use Oban.Worker, queue: :its, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    batch_date =
      case Map.get(args, "batch_date") do
        nil  -> Date.utc_today()
        date -> Date.from_iso8601!(date)
      end

    case VmuCore.ITS.Batch.Its1Extractor.run(batch_date) do
      {:ok, _counts} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
