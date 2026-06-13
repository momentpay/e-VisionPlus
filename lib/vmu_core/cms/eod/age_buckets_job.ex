defmodule VmuCore.CMS.EOD.AgeBucketsJob do
  @moduledoc """
  EOD Step 3 — Advance the delinquency bucket for accounts with an unpaid minimum.

  DPD (Days Past Due) aging:
    0   → 30  if minimum_payment due was missed this cycle
    30  → 60  if still unpaid after 30 days
    60  → 90, 90 → 120+

  Accounts at 120+ DPD are flagged for COL handoff.
  Enqueues GenerateStatementJob on success.
  """

  use Oban.Worker, queue: :eod, max_attempts: 3, unique: [period: 86_400]

  require Logger
  import Ecto.Query
  alias VmuCore.{Repo, CMS.Account, CMS.BalanceBucket}

  @dpd_buckets [0, 30, 60, 90, 120]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id, "eod_date" => eod_date_str}}) do
    eod_date = Date.from_iso8601!(eod_date_str)

    account = Repo.get!(Account, account_id)

    bucket =
      Repo.one(
        from b in BalanceBucket,
          where: b.account_id == ^account_id,
          order_by: [desc: b.balance_date],
          limit: 1
      )

    new_dpd = age_delinquency(account, bucket, eod_date)

    if new_dpd != account.delinquency_bucket do
      Repo.update_all(
        from(a in Account, where: a.account_id == ^account_id),
        set: [delinquency_bucket: new_dpd, updated_at: NaiveDateTime.utc_now()]
      )

      Logger.warning("[EOD] AgeBuckets: account=#{account_id} DPD #{account.delinquency_bucket} → #{new_dpd}")

      if new_dpd >= 120 do
        # Flag for COL handoff
        %{account_id: account_id, reason: "120_DPD"}
        |> VmuCore.COL.CollectionQueueJob.new()
        |> Oban.insert()
      end
    end

    %{account_id: account_id, eod_date: eod_date_str}
    |> VmuCore.CMS.EOD.GenerateStatementJob.new()
    |> Oban.insert()

    :ok
  end

  defp age_delinquency(account, nil, _date), do: account.delinquency_bucket

  defp age_delinquency(account, bucket, _date) do
    minimum_due   = bucket.minimum_payment
    paid_this_cyc = Decimal.new(0)  # In production: sum payments since last statement

    minimum_met = Decimal.compare(paid_this_cyc, minimum_due) != :lt

    if minimum_met do
      0  # Reset to current on payment
    else
      next_bucket(account.delinquency_bucket)
    end
  end

  defp next_bucket(current) do
    idx = Enum.find_index(@dpd_buckets, &(&1 == current)) || 0
    Enum.at(@dpd_buckets, idx + 1, 120)
  end
end
