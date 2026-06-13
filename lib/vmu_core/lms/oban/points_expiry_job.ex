defmodule VmuCore.LMS.Oban.PointsExpiryJob do
  @moduledoc """
  Monthly Oban job — expires ACTIVE points whose expiry_date < today.

  For each expired entry:
    1. Move original entry to HISTORY
    2. Post a negative EXPIRED entry (for audit trail)
    3. Deduct from account points_balance

  Cron: runs on the 1st of each month.
  """

  use Oban.Worker, queue: :lms, max_attempts: 3

  require Logger
  alias VmuCore.LMS.{Account, PointsLedger}
  alias VmuCore.Repo
  import Ecto.Query

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    today = Date.utc_today()
    Logger.info("[LMS/Expiry] Processing expired points as of #{today}")

    expired_entries =
      from(l in PointsLedger,
        where: l.warehouse_state == "ACTIVE"
          and not is_nil(l.expiry_date)
          and l.expiry_date < ^today
          and l.points_amount > 0
      )
      |> Repo.all()

    Logger.info("[LMS/Expiry] #{length(expired_entries)} entries to expire")

    Enum.each(expired_entries, &expire_entry(&1, today))
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp expire_entry(entry, today) do
    Repo.transaction(fn ->
      Repo.update_all(
        from(l in PointsLedger, where: l.id == ^entry.id),
        set: [warehouse_state: "HISTORY"]
      )

      expired_amount = Decimal.negate(Decimal.new(entry.points_amount))
      expired_equiv  = Decimal.negate(Decimal.new(entry.monetary_equiv))

      %PointsLedger{}
      |> PointsLedger.changeset(%{
        lms_account_id:   entry.lms_account_id,
        transaction_type: "EXPIRED",
        points_amount:    expired_amount,
        monetary_equiv:   expired_equiv,
        transaction_date: today,
        posting_date:     today,
        warehouse_state:  "HISTORY",
        scheme_id:        entry.scheme_id,
        idempotency_key:  "expire_#{entry.id}",
        inserted_at:      DateTime.utc_now()
      })
      |> Repo.insert(on_conflict: :nothing, conflict_target: :idempotency_key)

      Repo.update_all(
        from(a in Account, where: a.id == ^entry.lms_account_id),
        inc: [points_balance: expired_amount]
      )
    end)
  end
end
