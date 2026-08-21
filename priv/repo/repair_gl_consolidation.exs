# Rebuilds `gl_ledger_entries` from `journal_entries`.
#
#     mix run priv/repo/repair_gl_consolidation.exs            # dry run
#     mix run priv/repo/repair_gl_consolidation.exs --apply
#
# ## Why this exists
#
# `Posting.RuleEngine.consolidate/4` accumulated the GL with a read, an add in
# Elixir, and a write. Concurrent postings into the same correspondence on the
# same date both read the same row and the second write overwrote the first, so
# the GL under-reported while `journal_entries` — written once per posting, never
# accumulated — stayed correct. The engine now upserts with a SQL increment; this
# repairs the rows written before that fix.
#
# ## Why rebuilding from journal entries is sound
#
# `journal_entries` is one immutable row per posting and was never subject to the
# lost update. `gl_ledger_entries` is a pure aggregate of it: the sum and count
# per (institution, gl_date, dr, cr, currency, generation). Nothing in the GL row
# is independent information *except* lifecycle state — `status`, `generation` and
# `extracted_at` — which this script refuses to discard: it aborts if any row
# carries any of them, rather than quietly resetting a closed or extracted entry
# back to OPEN.

import Ecto.Query

alias VmuCore.Repo
alias VmuCore.GL.LedgerEntry
alias VmuCore.Posting.{JournalEntry, PostingSet}

apply? = "--apply" in System.argv()

zero = Decimal.new(0)
d = fn nil -> zero
        %Decimal{} = v -> v
        v -> Decimal.new(v)
     end

# --- refuse to touch anything with lifecycle state --------------------------

protected =
  Repo.all(
    from e in LedgerEntry,
      where: e.status != "OPEN" or e.generation != 1 or not is_nil(e.extracted_at),
      select: {e.gl_date, e.dr_account, e.cr_account, e.status, e.generation, e.extracted_at}
  )

if protected != [] do
  IO.puts("""
  ABORTING — #{length(protected)} GL entries carry lifecycle state this script
  cannot reconstruct (a non-OPEN status, a generation above 1, or an extraction
  timestamp). Rebuilding would silently reopen closed books.

  Repair those by hand, or restrict this script to the untouched subset.
  """)

  Enum.each(protected, &IO.puts("  #{inspect(&1)}"))
  System.halt(1)
end

# --- what the GL should be --------------------------------------------------

expected =
  Repo.all(
    from j in JournalEntry,
      join: s in PostingSet,
      on: s.id == j.posting_set_id,
      group_by: [s.sys_id, s.bank_id, j.gl_date, j.dr_gl_account, j.cr_gl_account, j.currency],
      select: %{
        sys_id: s.sys_id,
        bank_id: s.bank_id,
        gl_date: j.gl_date,
        dr_account: j.dr_gl_account,
        cr_account: j.cr_gl_account,
        currency: j.currency,
        amount: sum(j.amount),
        entry_count: count(j.id)
      }
  )

actual =
  Repo.all(from e in LedgerEntry, select: {{e.sys_id, e.bank_id, e.gl_date, e.dr_account, e.cr_account, e.currency}, {e.amount, e.entry_count}})
  |> Map.new()

key = fn r -> {r.sys_id, r.bank_id, r.gl_date, r.dr_account, r.cr_account, r.currency} end

{correct, wrong} =
  Enum.split_with(expected, fn r ->
    case Map.get(actual, key.(r)) do
      nil -> false
      {amt, n} -> Decimal.equal?(d.(amt), d.(r.amount)) and n == r.entry_count
    end
  end)

orphans = Map.keys(actual) -- Enum.map(expected, key)

je_total = Enum.reduce(expected, zero, &Decimal.add(&2, d.(&1.amount)))
gl_total = Repo.one(from e in LedgerEntry, select: coalesce(sum(e.amount), 0)) |> d.()

IO.puts("""

GL consolidation repair#{if apply?, do: " (APPLY)", else: " (dry run)"}
--------------------------------------------------------------
  correspondences expected from journal entries : #{length(expected)}
  already correct                               : #{length(correct)}
  wrong (lost updates)                          : #{length(wrong)}
  GL rows with no journal entries at all        : #{length(orphans)}

  journal entry total : #{je_total}
  GL total            : #{gl_total}
  shortfall           : #{Decimal.sub(je_total, gl_total)}
""")

Enum.each(wrong, fn r ->
  {amt, n} = Map.get(actual, key.(r), {zero, 0})

  IO.puts(
    "  #{r.gl_date} #{r.dr_account}->#{r.cr_account}  " <>
      "gl: #{amt} (n=#{n})  ->  #{d.(r.amount)} (n=#{r.entry_count})"
  )
end)

Enum.each(orphans, &IO.puts("  ORPHAN #{inspect(&1)}"))

if apply? do
  now = DateTime.utc_now()

  {:ok, result} =
    Repo.transaction(fn ->
      # Orphans first: GL rows with no journal entries behind them. On this
      # database they are the residue of the `seed_gl_demo` rows removed during
      # the Phase C2 parity work — the demo journal entries were deleted, their
      # GL contribution was not.
      deleted =
        Enum.reduce(orphans, 0, fn {sys, bank, date, dr, cr, ccy}, acc ->
          {n, _} =
            Repo.delete_all(
              from e in LedgerEntry,
                where:
                  e.sys_id == ^sys and e.bank_id == ^bank and e.gl_date == ^date and
                    e.dr_account == ^dr and e.cr_account == ^cr and e.currency == ^ccy
            )

          acc + n
        end)

      updated =
        Enum.reduce(wrong, 0, fn r, acc ->
          {n, _} =
            Repo.update_all(
              from(e in LedgerEntry,
                where:
                  e.sys_id == ^r.sys_id and e.bank_id == ^r.bank_id and
                    e.gl_date == ^r.gl_date and e.dr_account == ^r.dr_account and
                    e.cr_account == ^r.cr_account and e.currency == ^r.currency
              ),
              set: [amount: d.(r.amount), entry_count: r.entry_count, updated_at: now]
            )

          # A correspondence present in journal entries but missing from the GL
          # entirely needs inserting, not updating.
          if n == 0 do
            Repo.insert!(%LedgerEntry{
              sys_id: r.sys_id,
              bank_id: r.bank_id,
              gl_date: r.gl_date,
              dr_account: r.dr_account,
              cr_account: r.cr_account,
              currency: r.currency,
              amount: d.(r.amount),
              entry_count: r.entry_count,
              generation: 1,
              status: "OPEN",
              inserted_at: now,
              updated_at: now
            })
          end

          acc + 1
        end)

      %{updated: updated, deleted: deleted}
    end)

  new_total = Repo.one(from e in LedgerEntry, select: coalesce(sum(e.amount), 0)) |> d.()

  IO.puts("""

  repaired #{result.updated} correspondences, deleted #{result.deleted} orphan rows
  GL total now : #{new_total}
  journal total: #{je_total}
  reconciled   : #{Decimal.equal?(new_total, je_total)}
  """)
else
  IO.puts("\n  dry run — re-run with --apply to write\n")
end
