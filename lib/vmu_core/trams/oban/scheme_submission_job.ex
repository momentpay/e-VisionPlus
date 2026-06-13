defmodule VmuCore.TRAMS.Oban.SchemeSubmissionJob do
  @moduledoc """
  Submits a copy/retrieval request to the appropriate card scheme network.
  Enqueued by ITS1 batch extractor for each PENDING copy request.

  In production: writes to scheme SFTP drop zone or posts via scheme API.
  """

  use Oban.Worker, queue: :its, max_attempts: 5

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"request_id" => request_id, "network" => network} = args}) do
    Logger.info("[TRAMS/Submit] Submitting request #{request_id} to #{network} network")

    # Production: route to Mastercard CIS or Visa VisaNet API
    # For now: log and return success (wiring point for scheme connectivity)
    Logger.info("[TRAMS/Submit] type=#{args["type"]} arn=#{args["arn"]} — queued for scheme delivery")
    :ok
  end
end
