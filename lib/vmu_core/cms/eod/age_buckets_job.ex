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
  alias VmuCore.{Repo, CMS.Account, CMS.BalanceBucket, CMS.FeeEngine, CMS.LedgerEntry}

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
    minimum_met = minimum_met?(account, bucket, eod_date)

    # ── Fee assessment ─────────────────────────────────────────────────────────
    # Assess late fee if minimum payment was missed
    unless minimum_met or is_nil(bucket) do
      account_map = %{
        sys_id:   account.sys_id,  bank_id: account.bank_id,
        logo_id:  account.logo_id, block_id: account.block_id,
        open_to_buy: account.open_to_buy
      }
      FeeEngine.assess_late_fee(account_id, account_map, eod_date)
      FeeEngine.assess_overlimit_fee(account_id, account_map, eod_date)
    end

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

  defp age_delinquency(account, bucket, eod_date) do
    if minimum_met?(account, bucket, eod_date) do
      0  # Reset DPD bucket on payment
    else
      next_bucket(account.delinquency_bucket)
    end
  end

  # True if the cardholder paid at least the minimum payment since the last
  # statement date (or account open_date if no prior statement).
  defp minimum_met?(_account, nil, _eod_date), do: true

  defp minimum_met?(account, bucket, eod_date) do
    minimum_due = bucket.minimum_payment || Decimal.new(0)

    # Skip aging logic if no minimum is due
    if Decimal.compare(minimum_due, Decimal.new(0)) != :gt do
      true
    else
      # Determine the start of the current cycle: day after last statement date
      # or account open_date, whichever is later
      cycle_start =
        case account.next_statement_date do
          nil  -> account.open_date || Date.add(eod_date, -30)
          date -> Date.add(date, -30)  # approximate: one cycle before next stmt date
        end

      paid_this_cyc = sum_payments_since(account.account_id, cycle_start, eod_date)

      Decimal.compare(paid_this_cyc, minimum_due) != :lt
    end
  end

  # Sum all PAYMENT credits posted since cycle_start (inclusive) through eod_date
  defp sum_payments_since(account_id, cycle_start, eod_date) do
    result =
      Repo.one(
        from e in LedgerEntry,
          where: e.account_id    == ^account_id
             and e.transaction_code == "PAYMENT"
             and e.posting_date  >= ^cycle_start
             and e.posting_date  <= ^eod_date,
          select: coalesce(sum(e.cr_amount), ^Decimal.new(0))
      )

    result || Decimal.new(0)
  end

  defp next_bucket(current) do
    idx = Enum.find_index(@dpd_buckets, &(&1 == current)) || 0
    Enum.at(@dpd_buckets, idx + 1, 120)
  end
end
