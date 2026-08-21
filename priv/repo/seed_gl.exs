# GL seed data — chart of accounts, posting rules, banking dates, periods.
#
# Idempotent: safe to re-run. Uses the real context functions rather than
# `Repo.insert_all`, so every row passes the same validation production does.
# That matters here specifically — `seeds.exs` seeds `cms_ledger_entries` via
# `insert_all`, which bypasses `LedgerEntry.changeset/2`, and 11 rows were
# seeded violating double entry as a result (found and fixed 2026-08-02).
#
#     mix run priv/repo/seed_gl.exs

require Logger

alias VmuCore.GL.{ChartOfAccounts, Periods}
alias VmuCore.Posting.Rules

Logger.configure(level: :info)

IO.puts("\n== GL seed ==")

# --- Chart of accounts -------------------------------------------------------
ChartOfAccounts.seed!()
accounts = ChartOfAccounts.all()
IO.puts("chart of accounts : #{length(accounts)} active")

accounts
|> Enum.group_by(& &1.account_class)
|> Enum.sort()
|> Enum.each(fn {class, list} ->
  IO.puts("  #{String.pad_trailing(class, 10)} #{length(list)}  (#{hd(list).normal_balance}-normal)")
end)

# --- Posting rules -----------------------------------------------------------
Rules.seed!()
IO.puts("posting rules     : #{length(Rules.all())}")

# --- Banking dates and accounting periods ------------------------------------
# Seeded for whichever institutions actually exist in bank_parameters, rather
# than inventing identifiers — a banking date for a bank that does not exist
# would be dead data that quietly fails every period lookup.
import Ecto.Query, only: [from: 2]

banks = VmuCore.Repo.all(from(b in "bank_parameters", select: {b.sys_id, b.bank_id}))

today = Date.utc_today()
month_start = Date.beginning_of_month(today)
month_end = Date.end_of_month(today)

if banks == [] do
  IO.puts("banking dates     : skipped — no rows in bank_parameters")
else
  Enum.each(banks, fn {sys_id, bank_id} ->
    {:ok, _} = Periods.open_banking_date(sys_id, bank_id, today)

    # Current month plus the two before it, so period-close behaviour can be
    # exercised without waiting a month.
    for offset <- 0..2 do
      start = month_start |> Date.add(-offset * 28) |> Date.beginning_of_month()
      finish = Date.end_of_month(start)

      case Periods.period_for(sys_id, bank_id, start) do
        nil ->
          {:ok, period} = Periods.create_period(sys_id, bank_id, start, finish)

          # Everything before the current month is closed — a realistic state,
          # and the only way the closed-period gate gets exercised by seed data.
          if offset > 0, do: {:ok, _} = Periods.close_period(period, "seed")

        _existing ->
          :ok
      end
    end
  end)

  IO.puts("banking dates     : #{length(banks)} institution(s) opened at #{today}")
  IO.puts("periods           : 3 per institution (current OPEN, prior two CLOSED)")
end

# --- Report ------------------------------------------------------------------
conflicts = ChartOfAccounts.conflicts()
pending = Rules.pending_cutover()

IO.puts("\nreconciliation state")
IO.puts("  unresolved account conflicts : #{length(conflicts)}")
IO.puts("  rules pending cutover        : #{length(pending)}")

if conflicts != [] or pending != [] do
  IO.puts("  ^ non-zero means Phase 4A is incomplete")
end

IO.puts("\ndone.\n")
