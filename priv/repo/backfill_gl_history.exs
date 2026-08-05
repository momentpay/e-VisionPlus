# GL Phase C2 — backfill pre-shadow history into the new posting tables.
#
#     mix run priv/repo/backfill_gl_history.exs          # report only
#     mix run priv/repo/backfill_gl_history.exs --apply  # write
#
# ## Why this is required
#
# Shadow mode only mirrors postings made *after* it was switched on. Everything
# written before that exists solely in `cms_ledger_entries`. Until those rows
# are in `journal_entries` too, `GL.LedgerQuery` cannot see them — and a reader
# migrated onto it would silently under-report. For `AccountStateCoordinator`
# that means understating a balance on the authorization path, with nothing
# raised or logged.
#
# So: no reader migrates until this reports `unmirrored: 0`.
#
# ## Two rules this backfill follows
#
# 1. **Reproduce the stored account pair, never re-derive it.** Historical rows
#    must land exactly as they were. Re-deriving from today's posting rules
#    would "correct" history — including the 16 rows Phase 4A already remapped
#    in place via migration `20260802000008`.
#
# 2. **Closed periods must be allowed.** Backfilled rows are historical by
#    definition and most fall in closed periods. This run forces
#    `on_closed_period: :allow` and restores the previous setting afterwards;
#    without it every row would be quarantined instead of posted.
#
# Backfilled sets carry `source_module: "backfill:InternalGlPoster"`, so they
# remain distinguishable from postings the engine actually made — and
# `ShadowDiff` continues to ignore them, since it only compares `shadow:` rows.

import Ecto.Query, only: [from: 2]

alias VmuCore.{Repo, GL.InstitutionResolver, GL.Periods, Posting.RuleEngine, Posting.Rules}

Logger.configure(level: :error)

apply? = "--apply" in System.argv()
pad = fn l, v -> IO.puts(String.pad_trailing(l, 30) <> to_string(v)) end

IO.puts("\n=== GL history backfill #{if apply?, do: "(APPLYING)", else: "(dry run)"} ===\n")

# --- Rows the engine has never seen -----------------------------------------
mirrored_keys = Repo.all(from(s in "posting_sets", select: s.idempotency_key))

unmirrored =
  Repo.all(
    from(e in "cms_ledger_entries",
      where: e.idempotency_key not in ^mirrored_keys,
      order_by: [asc: e.posting_date],
      select: %{
        idempotency_key: e.idempotency_key,
        account_id: e.account_id,
        transaction_code: e.transaction_code,
        dr_amount: e.dr_amount,
        gl_account_dr: e.gl_account_dr,
        gl_account_cr: e.gl_account_cr,
        currency: e.currency,
        posting_date: e.posting_date,
        value_date: e.value_date,
        narrative: e.narrative
      }
    )
  )

pad.("unmirrored legacy rows", length(unmirrored))

if unmirrored == [] do
  IO.puts("\nNothing to do — every legacy row already has an engine counterpart.\n")
else
  dates = Enum.map(unmirrored, & &1.posting_date)
  pad.("date range", "#{Enum.min(dates)} .. #{Enum.max(dates)}")

  # Legacy transaction_code -> posting-rule event type. Same translation
  # `Posting.Shadow` uses: wallet withdrawals post as PURCHASE in the legacy
  # enum, and both adjustment directions share the ADJUSTMENT code, so the
  # direction is recovered from which side the stored liability sits on.
  event_type_for = fn row, product ->
    liability =
      case product do
        "DEBIT" -> "2004"
        "PREPAID" -> "2005"
        "WALLET" -> "2006"
        _ -> nil
      end

    case {row.transaction_code, product} do
      {"PURCHASE", "WALLET"} ->
        "WITHDRAWAL"

      {"ADJUSTMENT", _} ->
        if row.gl_account_dr == liability, do: "ADJUSTMENT_DEBIT", else: "ADJUSTMENT_CREDIT"

      {code, _} ->
        code
    end
  end

  # --- Classify ---------------------------------------------------------------
  # A row can only be replayed if its account still resolves to a product and
  # institution, and if its transaction_code maps to a posting rule.
  classified =
    Enum.map(unmirrored, fn row ->
      account_ref = Ecto.UUID.cast!(row.account_id)

      with {:ok, product} <- InstitutionResolver.resolve_product(account_ref),
           {:ok, {sys_id, bank_id}} <- InstitutionResolver.resolve(account_ref, product),
           event_type <- event_type_for.(row, product),
           {:ok, rule} <- Rules.fetch(event_type, product) do
        {:ok, Map.merge(row, %{
           account_ref: account_ref,
           product: product,
           sys_id: sys_id,
           bank_id: bank_id,
           event_type: event_type,
           rule: rule
         })}
      else
        {:error, reason} -> {:skip, row, reason}
        other -> {:skip, row, other}
      end
    end)

  replayable = for {:ok, r} <- classified, do: r
  skipped = for {:skip, r, reason} <- classified, do: {r, reason}

  pad.("replayable", length(replayable))
  pad.("not replayable", length(skipped))

  skipped
  |> Enum.group_by(fn {_r, reason} -> reason end)
  |> Enum.each(fn {reason, rows} -> IO.puts("    #{length(rows)}x #{inspect(reason)}") end)

  if apply? do
    # --- Preconditions --------------------------------------------------------
    previous_policy = Application.get_env(:vmu_core, RuleEngine, [])
    Application.put_env(:vmu_core, RuleEngine, on_closed_period: :allow)

    # Historical rows need a banking date on their institution, or normalise/1
    # refuses before the period gate is even reached.
    replayable
    |> Enum.map(&{&1.sys_id, &1.bank_id})
    |> Enum.uniq()
    |> Enum.each(fn {sys, bank} ->
      if is_nil(Periods.banking_date(sys, bank)) do
        {:ok, _} = Periods.open_banking_date(sys, bank, Date.utc_today())
      end
    end)

    IO.puts("")
    pad.("posting", "#{length(replayable)} rows...")

    results =
      Enum.map(replayable, fn row ->
        RuleEngine.execute(%{
          event_type: row.event_type,
          product: row.product,
          account_ref: row.account_ref,
          amount: row.dr_amount,
          idempotency_key: row.idempotency_key,
          sys_id: row.sys_id,
          bank_id: row.bank_id,
          currency: row.currency || "AED",
          posting_date: row.posting_date,
          gl_date: row.posting_date,
          transaction_date: row.value_date,
          # Rule 1: the stored pair, verbatim.
          accounts: {row.gl_account_dr, row.gl_account_cr},
          narrative: row.narrative,
          source_module: "backfill:InternalGlPoster"
        })
      end)

    Application.put_env(:vmu_core, RuleEngine, previous_policy)

    ok = Enum.count(results, &match?({:ok, %{}}, &1))
    dup = Enum.count(results, &match?({:ok, :duplicate, _}, &1))
    failed = Enum.reject(results, &(match?({:ok, %{}}, &1) or match?({:ok, :duplicate, _}, &1)))

    pad.("posted", ok)
    pad.("already present", dup)
    pad.("failed", length(failed))

    failed
    |> Enum.group_by(&elem(&1, 1))
    |> Enum.take(5)
    |> Enum.each(fn {reason, rows} -> IO.puts("    #{length(rows)}x #{inspect(reason, limit: 3)}") end)

    remaining_keys = Repo.all(from(s in "posting_sets", select: s.idempotency_key))

    remaining =
      Repo.one(
        from(e in "cms_ledger_entries",
          where: e.idempotency_key not in ^remaining_keys,
          select: count(e.entry_id)
        )
      )

    IO.puts("")
    pad.("remaining unmirrored", remaining)
    pad.("ready for reader migration", remaining == 0)
  else
    IO.puts("\nDry run — pass --apply to write.\n")
  end
end

IO.puts("")
