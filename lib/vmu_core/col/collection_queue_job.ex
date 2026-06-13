defmodule VmuCore.COL.CollectionQueueJob do
  @moduledoc """
  Oban job — enqueued by EOD AgeBucketsJob when an account reaches 120 DPD.
  Creates (or updates) a COL collection case and assigns it to the
  appropriate collection queue by DPD bucket.

  Queue assignment rules (configurable via block_parameters):
    30 DPD  → Early collections team (soft dunning)
    60 DPD  → Collections team (firm dunning)
    90 DPD  → Senior collections / workout
    120 DPD → External agency referral
  """

  use Oban.Worker, queue: :collections, max_attempts: 3

  require Logger
  import Ecto.Query
  alias VmuCore.{Repo, CMS.Account, COL.CollectionCase}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id, "reason" => reason}}) do
    account = Repo.get!(Account, account_id)

    existing = Repo.one(
      from c in CollectionCase,
        where: c.account_id == ^account_id and c.status == "OPEN",
        limit: 1
    )

    outstanding = outstanding_balance(account_id)
    queue       = queue_for_dpd(account.delinquency_bucket)

    if existing do
      Repo.update_all(
        from(c in CollectionCase, where: c.case_id == ^existing.case_id),
        set: [dpd_bucket: account.delinquency_bucket,
              outstanding_amount: outstanding,
              assigned_to: queue,
              updated_at: NaiveDateTime.utc_now()]
      )
    else
      Repo.insert!(CollectionCase.changeset(%CollectionCase{}, %{
        account_id:        account_id,
        dpd_bucket:        account.delinquency_bucket,
        outstanding_amount: outstanding,
        assigned_to:       queue,
        status:            "OPEN"
      }))
    end

    Logger.warning("[COL] Case opened/updated: account=#{account_id} DPD=#{account.delinquency_bucket} queue=#{queue} reason=#{reason}")

    if account.delinquency_bucket >= 120 do
      schedule_dunning(account_id, account.delinquency_bucket)
    end

    :ok
  end

  defp outstanding_balance(account_id) do
    Repo.one(
      from b in VmuCore.CMS.BalanceBucket,
        where: b.account_id == ^account_id,
        order_by: [desc: b.balance_date],
        limit: 1,
        select: b.statement_balance
    ) || Decimal.new(0)
  end

  defp queue_for_dpd(dpd) when dpd < 60,  do: "EARLY_COLLECTIONS"
  defp queue_for_dpd(dpd) when dpd < 90,  do: "COLLECTIONS"
  defp queue_for_dpd(dpd) when dpd < 120, do: "SENIOR_COLLECTIONS"
  defp queue_for_dpd(_),                  do: "EXTERNAL_AGENCY"

  defp schedule_dunning(account_id, dpd) do
    %{account_id: account_id, dpd_bucket: dpd}
    |> VmuCore.COL.DunningJob.new()
    |> Oban.insert()
  end
end
