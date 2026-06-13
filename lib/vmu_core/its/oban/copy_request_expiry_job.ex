defmodule VmuCore.ITS.Oban.CopyRequestExpiryJob do
  @moduledoc "Daily expiry of overdue copy requests. Cron: 30 6 * * * (06:30 each morning)."
  use Oban.Worker, queue: :its, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case VmuCore.ITS.CopyRequestManager.expire_overdue() do
      {:ok, %{expired: n}} ->
        require Logger
        Logger.info("[ITS/Expiry] Expired #{n} overdue copy requests")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
