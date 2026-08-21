defmodule VmuCore.COL.CollectionQueueJob do
  @moduledoc """
  Oban job — enqueued by EOD AgeBucketsJob on every DPD bucket change past 0
  (COL-P3: previously only at 120+ DPD). Creates (or updates) a COL collection
  case and assigns it to the appropriate collection queue by DPD bucket.

  Queue assignment (FR-COL-003) reads the `"queue"` field from
  `col.bucket_strategy_matrix` via the shared `VmuCore.COL.BucketStrategy` lookup
  (COL-P6) — the same per-bucket step list `DunningJob` uses for FR-COL-011's
  treatment steps, so the two FRs stay in sync from one config entry instead of
  two hardcoded ladders. Default queue mapping (unchanged from before wiring):
    30 DPD  → EARLY_COLLECTIONS (soft dunning)
    60 DPD  → COLLECTIONS (firm dunning)
    90 DPD  → SENIOR_COLLECTIONS / workout
    120 DPD → EXTERNAL_AGENCY referral
  """

  use Oban.Worker, queue: :collections, max_attempts: 3

  require Logger
  import Ecto.Query
  alias VmuCore.{COL.CollectionCase, COL.WriteOffCommand, COL.BucketStrategy}
  alias VmuCore.Shared.ModuleConfigEngine

  # M2 (2026-07-17): config-injected — CMS isn't extracted yet. %Account{}
  # patterns below are rewritten as plain params (field access only, never
  # re-matched) — see vmu_col's other files for the identical fix.
  @repo Application.compile_env(:vmu_col, :repo, VmuCore.Repo)
  @account_schema Application.compile_env(:vmu_col, :cms_account_schema, VmuCore.CMS.Account)
  @balance_bucket_schema Application.compile_env(:vmu_col, :cms_balance_bucket_schema, VmuCore.CMS.BalanceBucket)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id, "reason" => reason}}) do
    account = @repo.get!(@account_schema, account_id)

    existing = @repo.one(
      from c in CollectionCase,
        where: c.account_id == ^account_id and c.status == "OPEN",
        limit: 1
    )

    outstanding = outstanding_balance(account_id)
    queue       = queue_for_dpd(account)

    if existing do
      @repo.update_all(
        from(c in CollectionCase, where: c.case_id == ^existing.case_id),
        set: [dpd_bucket: account.delinquency_bucket,
              outstanding_amount: outstanding,
              assigned_to: queue,
              updated_at: NaiveDateTime.utc_now()]
      )
    else
      @repo.insert!(CollectionCase.changeset(%CollectionCase{}, %{
        account_id:        account_id,
        dpd_bucket:        account.delinquency_bucket,
        outstanding_amount: outstanding,
        assigned_to:       queue,
        status:            "OPEN"
      }))
    end

    Logger.warning("[COL] Case opened/updated: account=#{account_id} DPD=#{account.delinquency_bucket} queue=#{queue} reason=#{reason}")

    schedule_dunning(account_id, account.delinquency_bucket)

    maybe_request_writeoff(account)

    :ok
  end

  # COL-P2 — once DPD reaches the configured write-off threshold, park an
  # automatic write-off request for approval. WriteOffCommand.request/1 is
  # itself idempotent (no-ops if a PENDING_APPROVAL/POSTED request already
  # exists), so it's safe to call on every EOD run past the threshold.
  defp maybe_request_writeoff(account) do
    {:ok, threshold} =
      ModuleConfigEngine.get("col", "writeoff_dpd_threshold", account.sys_id, account.bank_id)

    if account.delinquency_bucket >= threshold do
      case WriteOffCommand.request(account.account_id,
             reason: "AUTO_DPD_#{account.delinquency_bucket}",
             requested_by: "SYSTEM_AUTO") do
        {:ok, :parked, req} ->
          Logger.warning("[COL] Write-off auto-requested: account=#{account.account_id} " <>
                          "dpd=#{account.delinquency_bucket} request=#{req.id}")

        {:ok, _already, _req} ->
          :ok

        {:error, reason} ->
          Logger.error("[COL] Write-off auto-request failed: account=#{account.account_id} " <>
                       "reason=#{inspect(reason)}")
      end
    end
  end

  defp outstanding_balance(account_id) do
    @repo.one(
      from b in @balance_bucket_schema,
        where: b.account_id == ^account_id,
        order_by: [desc: b.balance_date],
        limit: 1,
        select: b.statement_balance
    ) || Decimal.new(0)
  end

  defp queue_for_dpd(account) do
    case BucketStrategy.step_for_dpd(account, account.delinquency_bucket) do
      %{"queue" => queue} ->
        queue

      _ ->
        Logger.warning("[COL] No bucket_strategy_matrix step for account=#{account.account_id} " <>
                        "dpd=#{account.delinquency_bucket} — defaulting queue to EARLY_COLLECTIONS")
        "EARLY_COLLECTIONS"
    end
  end

  defp schedule_dunning(account_id, dpd) do
    %{account_id: account_id, dpd_bucket: dpd}
    |> VmuCore.COL.DunningJob.new()
    |> Oban.insert()
  end
end
