defmodule VmuCore.LMS.Oban.PointsCalculationJob do
  @moduledoc """
  Daily LMS batch — calculates points earned from clearing records posted on batch_date.

  Reads MATCHED clearing records for the batch date and processes each through
  PointsEngine. Enqueued by CmsInterface.trigger_points_calculation/1 at end of EOD.

  Cron: runs at 23:30 daily after EOD GL flush.
  """

  use Oban.Worker, queue: :lms, max_attempts: 3,
    unique: [fields: [:args], period: 86_400]

  require Logger
  alias VmuCore.LMS.PointsEngine
  alias VmuCore.TRAMS.ClearingRecord
  alias VmuCore.Repo
  import Ecto.Query

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"batch_date" => batch_date_str}}) do
    batch_date = Date.from_iso8601!(batch_date_str)
    Logger.info("[LMS/PointsCalc] Processing batch for #{batch_date}")

    clearing_records =
      from(c in ClearingRecord,
        where: c.transaction_date == ^batch_date and c.match_status == "MATCHED",
        select: %{
          clearing_record_id: c.clearing_id,
          ar_account_id:      c.account_id,
          amount:             c.amount,
          transaction_date:   c.transaction_date,
          merchant_id:        nil,   # to be wired via terminal→merchant lookup
          currency:           c.currency
        }
      )
      |> Repo.all()

    Logger.info("[LMS/PointsCalc] #{length(clearing_records)} matched records")

    Enum.each(clearing_records, fn txn ->
      try do
        PointsEngine.process_transaction(txn.ar_account_id, txn)
      rescue
        e -> Logger.error("[LMS/PointsCalc] Failed for clearing=#{txn.clearing_record_id}: #{inspect(e)}")
      end
    end)

    :ok
  end
end
