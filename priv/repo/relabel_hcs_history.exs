# Relabels historical HCS postings from CREDIT onto HCS_FLEET / HCS_CORPORATE.
#
#     mix run priv/repo/relabel_hcs_history.exs            # dry run
#     mix run priv/repo/relabel_hcs_history.exs --apply
#
# ## Why this exists
#
# HCS cards hang off real `cms_accounts` rows, so until 2026-08-06 the posting
# engine labelled them `CREDIT` and they posted to the consumer card accounts
# `1001` / `2001`. They now have their own product labels and their own
# receivables. Without this, the same company's history is split across two sets
# of accounts either side of that date, and the trial balance answers
# "what is our corporate fleet exposure" wrongly for every prior period.
#
# ## ⚠️ This is only safe because the data is test data
#
# **These postings fall in CLOSED accounting periods.** Restating a closed period
# in place is not something a production system may do — the correct treatment
# there is a dated reclassification entry in the current open period, leaving
# history intact, so the prior period's reported figures stay reproducible.
#
# This script exists because the environment it runs in holds seed data and the
# split-brain is not worth carrying. It refuses to run against anything with
# an `extracted_at` timestamp — the one marker that a GL entry has already been
# handed to an external consumer, at which point restating it is a lie to a
# system that has already acted on the old value.
#
# ## How the new accounts are chosen
#
# From `posting_rules`, not from a hardcoded mapping. Every posting is re-derived
# through the same rule the engine would use for that event and the new product,
# so relabelled history is by construction identical to what a fresh posting
# would produce. A hardcoded pair would drift the moment a rule changed.

import Ecto.Query

alias VmuCore.Repo
alias VmuCore.GL
alias VmuCore.Posting.{JournalEntry, PostingSet, Rules}

apply? = "--apply" in System.argv()

# --- who is HCS -------------------------------------------------------------

fleet_ids =
  Repo.all(from f in "hcs_fleet_cards", select: type(f.account_id, Ecto.UUID))
  |> Enum.reject(&is_nil/1)
  |> MapSet.new()

corp_ids =
  Repo.all(from e in "hcs_employee_cards", select: type(e.employee_account_id, Ecto.UUID))
  |> Enum.reject(&is_nil/1)
  |> MapSet.new()

both = MapSet.intersection(fleet_ids, corp_ids)

if MapSet.size(both) > 0 do
  IO.puts("""
  ABORTING — #{MapSet.size(both)} account(s) are claimed by BOTH hcs_fleet_cards
  and hcs_employee_cards, so there is no single correct product for them:

  #{Enum.map_join(both, "\n  ", &to_string/1)}

  `GL.InstitutionResolver` resolves fleet first, but guessing here would silently
  post a corporate balance to the fleet receivable.
  """)

  System.halt(1)
end

product_of = fn ref ->
  cond do
    MapSet.member?(fleet_ids, ref) -> "HCS_FLEET"
    MapSet.member?(corp_ids, ref) -> "HCS_CORPORATE"
    true -> nil
  end
end

all_ids = MapSet.union(fleet_ids, corp_ids) |> MapSet.to_list()

# --- refuse to restate anything already extracted ---------------------------

extracted =
  Repo.one(from e in GL.LedgerEntry, where: not is_nil(e.extracted_at), select: count(e.id))

if extracted > 0 do
  IO.puts("""
  ABORTING — #{extracted} GL entries carry an `extracted_at` timestamp. They have
  already been handed to an external consumer, and restating them would change a
  figure another system has acted on. Post a reclassification entry instead.
  """)

  System.halt(1)
end

# --- what would change ------------------------------------------------------

sets =
  Repo.all(
    from s in PostingSet,
      where: s.account_ref in ^all_ids and s.product == "CREDIT",
      select: %{id: s.id, account_ref: s.account_ref, event_type: s.event_type,
                idempotency_key: s.idempotency_key}
  )

{resolvable, unresolvable} =
  Enum.split_with(sets, fn s ->
    match?({:ok, _}, Rules.fetch(s.event_type, product_of.(s.account_ref)))
  end)

IO.puts("""

HCS history relabel#{if apply?, do: " (APPLY)", else: " (dry run)"}
--------------------------------------------------------------
  HCS accounts                 : #{length(all_ids)} (#{MapSet.size(fleet_ids)} fleet, #{MapSet.size(corp_ids)} corporate)
  posting sets still on CREDIT : #{length(sets)}
  with a rule for the new label: #{length(resolvable)}
  WITHOUT a rule               : #{length(unresolvable)}
""")

if unresolvable != [] do
  IO.puts("  These have no rule under their HCS label and would be left behind:")

  unresolvable
  |> Enum.group_by(& &1.event_type)
  |> Enum.each(fn {event, rows} -> IO.puts("    #{event}: #{length(rows)}") end)

  IO.puts("")
end

# Group the planned changes so the dry run shows accounts moving, not 135 lines.
planned =
  resolvable
  |> Enum.map(fn s ->
    product = product_of.(s.account_ref)
    {:ok, rule} = Rules.fetch(s.event_type, product)
    {s, product, rule}
  end)

planned
|> Enum.group_by(fn {s, product, rule} -> {s.event_type, product, rule.dr_account, rule.cr_account} end)
|> Enum.sort()
|> Enum.each(fn {{event, product, dr, cr}, rows} ->
  ids = Enum.map(rows, fn {s, _, _} -> s.id end)

  current =
    Repo.all(
      from j in JournalEntry,
        where: j.posting_set_id in ^ids,
        group_by: [j.dr_gl_account, j.cr_gl_account],
        select: {j.dr_gl_account, j.cr_gl_account, count(j.id), sum(j.amount)}
    )

  Enum.each(current, fn {old_dr, old_cr, n, amount} ->
    change = if {old_dr, old_cr} == {dr, cr}, do: "label only", else: "#{old_dr}/#{old_cr} -> #{dr}/#{cr}"
    IO.puts("  #{String.pad_trailing(product, 14)} #{String.pad_trailing(event, 16)} n=#{String.pad_trailing(to_string(n), 4)} #{String.pad_trailing(to_string(amount), 14)} #{change}")
  end)
end)

if apply? do
  now = DateTime.utc_now()

  {:ok, counts} =
    Repo.transaction(fn ->
      Enum.reduce(planned, %{sets: 0, entries: 0}, fn {s, product, rule}, acc ->
        {n_set, _} =
          Repo.update_all(
            from(x in PostingSet, where: x.id == ^s.id),
            set: [product: product, updated_at: now]
          )

        {n_je, _} =
          Repo.update_all(
            from(j in JournalEntry, where: j.posting_set_id == ^s.id),
            set: [
              product: product,
              dr_gl_account: rule.dr_account,
              cr_gl_account: rule.cr_account,
              updated_at: now
            ]
          )

        %{acc | sets: acc.sets + n_set, entries: acc.entries + n_je}
      end)
    end)

  IO.puts("""

  relabelled #{counts.sets} posting sets and #{counts.entries} journal entries

  `gl_ledger_entries` is a pure aggregate of `journal_entries` and is now stale.
  Rebuild it:

      mix run priv/repo/repair_gl_consolidation.exs --apply
  """)
else
  IO.puts("\n  dry run — re-run with --apply to write\n")
end
