defmodule VmuCore.ITS.Oban.Its2BatchJob do
  @moduledoc "Runs ITS2 receive. Cron: 0 2 * * * (after TRAMS clearing is complete)."
  use Oban.Worker, queue: :its, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    batch_date =
      case Map.get(args, "batch_date") do
        nil  -> Date.utc_today()
        date -> Date.from_iso8601!(date)
      end

    # In production: read scheme response records from SFTP / MQ delivery
    # For now: fetch any pending responses that TRAMS has decoded
    incoming = fetch_incoming_responses(batch_date)

    case VmuCore.ITS.Batch.Its2Receiver.run(batch_date, incoming) do
      {:ok, _counts} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_incoming_responses(_batch_date) do
    # Production: query VmuCore.TRAMS.ResponseQueue.fetch_pending(batch_date)
    # For now returns empty list — wiring point for SFTP/MQ integration
    []
  end
end
