# GL Phase B — traffic generator and diff report.
#
# Drives a realistic volume of postings through the **legacy** `InternalGlPoster`
# with shadow mode on, then reports how the two implementations compared. This
# is the evidence Phase C needs: 11 hand-written postings prove the plumbing
# works, they do not prove equivalence.
#
#     mix run priv/repo/gl_shadow_traffic.exs
#     mix run priv/repo/gl_shadow_traffic.exs 500      # posting count
#
# Everything is written through the legacy path, exactly as production does.
# Nothing calls the engine directly — if the shadow disagrees, that is a real
# finding, not an artefact of the harness.
#
# Idempotency keys are prefixed `TRAFFIC-` so this run can be identified and
# removed later:
#
#     DELETE FROM cms_ledger_entries WHERE idempotency_key LIKE 'TRAFFIC-%';

import Ecto.Query, only: [from: 2]

alias VmuCore.{Repo, CMS.InternalGlPoster, GL.Periods, Posting.Shadow, Posting.ShadowDiff}

Logger.configure(level: :error)

target = case System.argv() do
  [n | _] -> String.to_integer(n)
  _ -> 300
end

pad = fn label, value -> IO.puts(String.pad_trailing(label, 26) <> to_string(value)) end

IO.puts("\n=== GL shadow traffic run ===\n")

# --- Preconditions -----------------------------------------------------------
# Shadow mode must be on, or this run proves nothing. Turn it on for the
# duration rather than silently producing an empty diff.
was_enabled = Shadow.enabled?()
unless was_enabled, do: Application.put_env(:vmu_core, Shadow, enabled: true)
pad.("shadow mode", if(was_enabled, do: "already on", else: "enabled for this run"))

accounts = fn table, key ->
  Repo.all(from(a in table, select: {field(a, ^key), a.sys_id, a.bank_id}))
  |> Enum.map(fn {id, sys, bank} -> {Ecto.UUID.cast!(id), sys, bank} end)
end

credit  = accounts.("cms_accounts", :account_id)
debit   = accounts.("cms_debit_accounts", :debit_account_id)
prepaid = accounts.("cms_prepaid_accounts", :prepaid_account_id)
wallet  = accounts.("cms_wallet_accounts", :wallet_account_id)

pad.("accounts available", "#{length(credit)} credit, #{length(debit)} debit, " <>
                           "#{length(prepaid)} prepaid, #{length(wallet)} wallet")

# Every institution that will be posted to needs an open banking date and a
# period covering the dates used.
#
# Dates are drawn from INSIDE the open period. The first run of this script
# spread them over the previous 6 days, which crossed into July — a period
# `seed_gl.exs` closes — so the engine correctly quarantined 290 of 600
# postings and only half the sample could be compared. That is the period gate
# working, but it makes for a poor equivalence measurement, which is what this
# script is for. The closed-period behaviour is exercised deliberately at the
# end instead.
today = Date.utc_today()

institutions =
  (credit ++ debit ++ prepaid ++ wallet)
  |> Enum.map(fn {_id, sys, bank} -> {sys, bank} end)
  |> Enum.uniq()

Enum.each(institutions, fn {sys, bank} ->
  {:ok, _} = Periods.open_banking_date(sys, bank, today)

  # Postings spread over the last few days, so consolidation across dates is
  # exercised; every one of those dates needs an open period.
  if is_nil(Periods.period_for(sys, bank, today)) do
    Periods.create_period(sys, bank, Date.beginning_of_month(today), Date.end_of_month(today))
  end
end)

# The dates available for posting: every day of the current open period up to
# today. Drawing from this rather than a fixed window means the run adapts to
# whatever the period actually is.
{sys0, bank0} = hd(institutions)
open_period = Periods.period_for(sys0, bank0, today)

postable_dates =
  Date.range(open_period.period_start, today)
  |> Enum.to_list()

pad.("institutions prepared", length(institutions))

# --- Traffic -----------------------------------------------------------------
# Weighted so the mix resembles a real card portfolio: mostly purchases and
# funding, with interest, fees and payments at lower volume.
amount = fn min, max ->
  Decimal.new(:rand.uniform(max - min) + min) |> Decimal.div(Decimal.new(100))
end

seq = :erlang.unique_integer([:positive])

work =
  Enum.map(1..target, fn i ->
    key = "TRAFFIC-#{seq}-#{i}"
    date = Enum.random(postable_dates)

    case :rand.uniform(100) do
      n when n <= 25 and debit != [] ->
        {id, _, _} = Enum.random(debit)
        {"debit purchase", fn -> InternalGlPoster.post_debit_purchase(id, amount.(500, 50_000), date, "AED", key) end}

      n when n <= 40 and debit != [] ->
        {id, _, _} = Enum.random(debit)
        {"debit deposit", fn -> InternalGlPoster.post_debit_deposit(id, amount.(10_000, 500_000), date, "SALARY", key) end}

      n when n <= 45 and debit != [] ->
        {id, _, _} = Enum.random(debit)
        dir = Enum.random(["CREDIT", "DEBIT"])
        {"debit adjustment", fn -> InternalGlPoster.post_debit_adjustment(id, amount.(100, 5_000), dir, date, "Adjustment", key) end}

      n when n <= 57 and prepaid != [] ->
        {id, _, _} = Enum.random(prepaid)
        {"prepaid spend", fn -> InternalGlPoster.post_prepaid_spend(id, amount.(200, 20_000), date, "AED", key) end}

      n when n <= 65 and prepaid != [] ->
        {id, _, _} = Enum.random(prepaid)
        {"prepaid load", fn -> InternalGlPoster.post_prepaid_load(id, amount.(5_000, 100_000), date, "CASH", key) end}

      n when n <= 72 and wallet != [] ->
        {id, _, _} = Enum.random(wallet)
        {"wallet load", fn -> InternalGlPoster.post_wallet_load(id, amount.(5_000, 200_000), date, "UPI", key) end}

      n when n <= 78 and wallet != [] ->
        {id, _, _} = Enum.random(wallet)
        {"wallet withdrawal", fn -> InternalGlPoster.post_wallet_withdrawal(id, amount.(1_000, 30_000), date, "To bank", key) end}

      n when n <= 88 ->
        {id, _, _} = Enum.random(credit)
        {"credit interest", fn -> InternalGlPoster.post_interest(id, amount.(50, 5_000), date, key) end}

      n when n <= 95 ->
        {id, _, _} = Enum.random(credit)
        fee = Enum.random(~w[ANNUAL LATE_PAYMENT OVERLIMIT CASH_ADVANCE])
        {"credit fee", fn -> InternalGlPoster.post_fee(id, amount.(2_500, 30_000), fee, date, key) end}

      _ ->
        {id, _, _} = Enum.random(credit)
        {"credit payment", fn -> InternalGlPoster.post_payment(id, amount.(10_000, 300_000), date, "REF", key) end}
    end
  end)

IO.puts("")
pad.("open period", "#{open_period.period_start} .. #{open_period.period_end}")
pad.("posting dates", "#{length(postable_dates)} day(s), #{hd(postable_dates)} .. #{List.last(postable_dates)}")
pad.("posting", "#{target} transactions via InternalGlPoster...")

started = System.monotonic_time(:millisecond)

results =
  Enum.map(work, fn {label, f} ->
    case f.() do
      {:ok, _} -> {:ok, label}
      other -> {:error, label, other}
    end
  end)

elapsed = System.monotonic_time(:millisecond) - started

ok = Enum.count(results, &match?({:ok, _}, &1))
failed = Enum.filter(results, &match?({:error, _, _}, &1))

pad.("posted ok", ok)
pad.("posting failures", length(failed))
pad.("elapsed", "#{elapsed} ms (#{Float.round(target / max(elapsed, 1) * 1000, 1)}/s incl. shadow)")

Enum.take(failed, 5)
|> Enum.each(fn {:error, label, r} -> IO.puts("  ! #{label}: #{inspect(r, limit: 2)}") end)

# --- Idempotency: replay a sample --------------------------------------------
# A retried Oban job must not double-post on either side.
replay_keys = work |> Enum.take(10) |> Enum.with_index(1)
IO.puts("")
pad.("replaying", "10 postings to check idempotency")

replayed = Enum.map(replay_keys, fn {{_label, f}, _i} -> f.() end)
dupes = Enum.count(replayed, &match?({:error, :duplicate}, &1))
pad.("reported duplicate", "#{dupes}/10")

# --- The diff ----------------------------------------------------------------
since = Date.add(today, -7)
summary = ShadowDiff.summary(since: since)
rows = ShadowDiff.compare(since: since, limit: 5000)

IO.puts("\n--- diff (postings since #{since}) ---\n")
pad.("shadow-written sets", summary.shadow_written)
pad.("match", summary.match)
pad.("mismatch", summary.mismatch)
pad.("missing shadow", summary.missing_shadow)
pad.("orphan shadow", summary.orphan_shadow)
pad.("equivalent?", summary.equivalent?)

traffic = Enum.filter(rows, &String.starts_with?(&1.idempotency_key, "TRAFFIC-"))
matched = Enum.count(traffic, &(&1.status == :match))
mismatched = Enum.filter(traffic, &(&1.status == :mismatch))
missing = Enum.filter(traffic, &(&1.status == :missing_shadow))

IO.puts("")
pad.("this run: compared", length(traffic))
pad.("this run: matched", "#{matched}#{if length(traffic) > 0, do: " (#{Float.round(matched / length(traffic) * 100, 1)}%)", else: ""}")
pad.("this run: mismatched", length(mismatched))
pad.("this run: missing", length(missing))

if mismatched != [] do
  IO.puts("\nMISMATCHES — these are real findings:\n")

  mismatched
  |> Enum.take(15)
  |> Enum.each(fn r -> IO.puts("  #{r.idempotency_key}\n    #{Enum.join(r.differences, "\n    ")}") end)
end

if missing != [] do
  IO.puts("\nMISSING FROM SHADOW — the engine refused or skipped these:\n")

  missing
  |> Enum.take(15)
  |> Enum.each(fn r ->
    IO.puts("  #{r.idempotency_key}  legacy #{r.legacy.transaction_code} " <>
              "#{r.legacy.gl_account_dr}/#{r.legacy.gl_account_cr} #{r.legacy.dr_amount}")
  end)
end

# --- Deliberate closed-period probe ------------------------------------------
# The legacy poster has no concept of an accounting period and will post into a
# closed one without complaint. The engine refuses. Demonstrated explicitly
# rather than left to chance, because it is the single biggest behavioural
# difference between the two implementations and Phase C has to plan for it.
closed_date = Date.add(open_period.period_start, -1)
probe_key = "TRAFFIC-CLOSEDPERIOD-#{seq}"

{id, _, _} = Enum.random(credit)
legacy_took_it = match?({:ok, _}, InternalGlPoster.post_interest(id, Decimal.new("12.34"), closed_date, probe_key))

shadow_took_it =
  Repo.exists?(from(s in "posting_sets", where: s.idempotency_key == ^probe_key))

IO.puts("")
pad.("closed-period probe", "gl_date #{closed_date} (prior, closed period)")
pad.("  legacy accepted", legacy_took_it)
pad.("  shadow accepted", shadow_took_it)
pad.("  -> divergence", legacy_took_it and not shadow_took_it)

# --- Quarantine + balance ----------------------------------------------------
quarantined =
  Repo.one(from(e in "gl_posting_exceptions", where: e.resolved == false, select: count(e.id)))

{dr, cr} =
  Repo.one(
    from(l in "posting_legs",
      select:
        {sum(fragment("CASE WHEN ? = 'debit' THEN ? ELSE 0 END", l.direction, l.amount)),
         sum(fragment("CASE WHEN ? = 'credit' THEN ? ELSE 0 END", l.direction, l.amount))}
    )
  )

IO.puts("")
pad.("open exceptions", quarantined)
pad.("shadow total debits", dr)
pad.("shadow total credits", cr)
pad.("shadow balanced", Decimal.equal?(dr || Decimal.new(0), cr || Decimal.new(0)))

unless was_enabled, do: Application.put_env(:vmu_core, Shadow, enabled: false)

IO.puts("""

verdict: #{if summary.mismatch == 0 and length(mismatched) == 0,
  do: "no disagreements across #{length(traffic)} compared postings",
  else: "#{length(mismatched)} MISMATCHES — do not cut over"}
""")
