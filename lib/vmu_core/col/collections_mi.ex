defmodule VmuCore.COL.CollectionsMi do
  @moduledoc """
  Collections Management Information (FR-COL-025) — roll rates, cure rates,
  promise-kept %, recovery %, all for a given `[from_date, to_date]` window.

  Two of the four are computed from data that already existed for other
  reasons (`promise_kept_rate/2` from `PromiseVerification`'s
  `CollectionCase.promise_status`, `recovery_rate/2` from
  `WriteOffProcessor`'s `write_off_amount`/`write_off_date` +
  `ChargeOffRecovery`'s ledger). `roll_cure_rates/2` needed a real
  foundational build first — `VmuCore.COL.DpdBucketHistory`, populated by
  `CMS.EOD.AgeBucketsJob` — since nothing tracked bucket transitions over
  time before. Only has data from whenever that table started recording
  forward; an empty/near-empty result for a period before this shipped is
  the honest answer, not a bug.

  ## Roll rate / cure rate definition

  For each DPD bucket `B` in `[30, 60, 90, 120, 150, 180]`: the cohort is
  every account that transitioned INTO `B` during the window. Roll rate is
  the fraction of that cohort with a LATER transition (within the same
  window) to a bucket `> B`. Cure rate is the fraction with a later
  transition to bucket `0`. This is a forward-looking "what happened next
  to accounts that just arrived here" reading — one defensible definition
  among several used in the industry; documented explicitly here rather
  than left ambiguous.
  """

  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.COL.{CollectionCase, DpdBucketHistory}
  alias VmuCore.CMS.ChargeOffRecovery
  alias Decimal, as: D

  @buckets [30, 60, 90, 120, 150, 180]

  @doc """
  Promise-kept % over `[from_date, to_date]`, keyed on `promise_logged_at`.
  Returns `%{kept:, broken:, pending:, rate: Decimal.t() | nil}` — `rate`
  is `nil` when there's nothing resolved yet to divide by (pending-only or
  empty), not `0`, so the UI can distinguish "no data" from "0% kept."
  """
  @spec promise_kept_rate(Date.t(), Date.t()) :: map()
  def promise_kept_rate(from_date, to_date) do
    rows =
      Repo.all(
        from c in CollectionCase,
          where: not is_nil(c.promise_status) and
                 fragment("?::date", c.promise_logged_at) >= ^from_date and
                 fragment("?::date", c.promise_logged_at) <= ^to_date,
          select: c.promise_status
      )

    kept = Enum.count(rows, &(&1 == "KEPT"))
    broken = Enum.count(rows, &(&1 == "BROKEN"))
    pending = Enum.count(rows, &(&1 == "PENDING"))
    resolved = kept + broken

    %{kept: kept, broken: broken, pending: pending, rate: pct(kept, resolved)}
  end

  @doc """
  Recovery % over `[from_date, to_date]` — cohort is every case written off
  in the window (`write_off_date`). Returns
  `%{cohort_size:, written_off_total:, recovered_total:, rate: Decimal.t() | nil}`.
  """
  @spec recovery_rate(Date.t(), Date.t()) :: map()
  def recovery_rate(from_date, to_date) do
    cases =
      Repo.all(
        from c in CollectionCase,
          where: not is_nil(c.write_off_date) and
                 c.write_off_date >= ^from_date and c.write_off_date <= ^to_date,
          select: %{account_id: c.account_id, write_off_amount: c.write_off_amount}
      )

    written_off_total = Enum.reduce(cases, D.new(0), &D.add(&2, &1.write_off_amount || D.new(0)))
    recovered_total = Enum.reduce(cases, D.new(0), &D.add(&2, ChargeOffRecovery.total_recovered(&1.account_id)))

    %{
      cohort_size: length(cases),
      written_off_total: written_off_total,
      recovered_total: recovered_total,
      rate: pct_decimal(recovered_total, written_off_total)
    }
  end

  @doc """
  Roll rate + cure rate per DPD bucket over `[from_date, to_date]`. Returns
  a list of `%{bucket:, cohort_size:, rolled:, cured:, roll_rate:, cure_rate:}`,
  one per bucket in `[30, 60, 90, 120, 150, 180]`. `roll_rate`/`cure_rate`
  are `nil` (not `0`) when `cohort_size` is `0`.
  """
  @spec roll_cure_rates(Date.t(), Date.t()) :: [map()]
  def roll_cure_rates(from_date, to_date) do
    Enum.map(@buckets, &bucket_roll_cure(&1, from_date, to_date))
  end

  defp bucket_roll_cure(bucket, from_date, to_date) do
    cohort =
      Repo.all(
        from h in DpdBucketHistory,
          where: h.new_bucket == ^bucket and h.eod_date >= ^from_date and h.eod_date <= ^to_date,
          select: %{account_id: h.account_id, entry_date: h.eod_date}
      )

    cohort_size = length(cohort)

    if cohort_size == 0 do
      %{bucket: bucket, cohort_size: 0, rolled: 0, cured: 0, roll_rate: nil, cure_rate: nil}
    else
      account_ids = cohort |> Enum.map(& &1.account_id) |> Enum.uniq()

      later_by_account =
        Repo.all(
          from h in DpdBucketHistory,
            where: h.account_id in ^account_ids and h.eod_date <= ^to_date,
            select: %{account_id: h.account_id, eod_date: h.eod_date, new_bucket: h.new_bucket}
        )
        |> Enum.group_by(& &1.account_id)

      {rolled, cured} =
        Enum.reduce(cohort, {0, 0}, fn %{account_id: aid, entry_date: entry_date}, {r, c} ->
          later =
            later_by_account
            |> Map.get(aid, [])
            |> Enum.filter(&(Date.compare(&1.eod_date, entry_date) == :gt))

          rolled? = Enum.any?(later, &(&1.new_bucket > bucket))
          cured? = Enum.any?(later, &(&1.new_bucket == 0))
          {r + bool_to_int(rolled?), c + bool_to_int(cured?)}
        end)

      %{
        bucket: bucket, cohort_size: cohort_size, rolled: rolled, cured: cured,
        roll_rate: pct(rolled, cohort_size), cure_rate: pct(cured, cohort_size)
      }
    end
  end

  defp bool_to_int(true), do: 1
  defp bool_to_int(false), do: 0

  defp pct(_numerator, 0), do: nil
  defp pct(numerator, denominator), do: pct_decimal(D.new(numerator), D.new(denominator))

  defp pct_decimal(numerator, denominator) do
    if D.compare(denominator, D.new(0)) == :gt do
      numerator |> D.div(denominator) |> D.mult(D.new(100)) |> D.round(2)
    else
      nil
    end
  end
end
