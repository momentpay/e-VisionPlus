defmodule VmuCore.ITS.Oban.FeeSettlementJob do
  @moduledoc "Monthly interchange fee settlement. Cron: 0 6 1 * * (1st of month, 06:00)."
  use Oban.Worker, queue: :its, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    settlement_date =
      case Map.get(args, "settlement_date") do
        nil  -> Date.utc_today()
        date -> Date.from_iso8601!(date)
      end

    case VmuCore.ITS.FeeClaimProcessor.settle_claims(settlement_date) do
      {:ok, _counts} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
