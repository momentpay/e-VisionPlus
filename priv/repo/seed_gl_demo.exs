# GL demo data — populates the transaction side of the GL module so the admin
# screens have something real to show.
#
# Every row here is written by `Posting.RuleEngine.execute/1`, the same path
# production will use. Nothing is inserted directly. That matters: if the
# engine has a defect, this seed surfaces it rather than papering over it with
# hand-built rows — which is exactly how 11 unbalanced rows got into
# `cms_ledger_entries` via `insert_all`.
#
# Safe to run repeatedly: idempotency keys are deterministic, so a re-run
# returns `{:ok, :duplicate, set}` instead of doubling the data.
#
#     mix run priv/repo/seed_gl.exs        # config first
#     mix run priv/repo/seed_gl_demo.exs   # then this
#
# This does NOT wire the engine to any live posting path. Phase A remains
# build-only; `InternalGlPoster` is still what production calls.

import Ecto.Query, only: [from: 2]

alias VmuCore.Repo
alias VmuCore.GL.Periods
alias VmuCore.Posting.RuleEngine

Logger.configure(level: :error)

report = fn label, value -> IO.puts(String.pad_trailing(label, 34) <> to_string(value)) end

IO.puts("\n== GL demo data ==")

# Use the first institution that actually has a banking date, rather than
# inventing one — a posting for an unknown institution is refused by design.
institution =
  Repo.one(
    from(b in "gl_banking_dates",
      select: {b.sys_id, b.bank_id},
      order_by: [b.sys_id, b.bank_id],
      limit: 1
    )
  )

case institution do
  nil ->
    IO.puts("\nNo banking dates found. Run `mix run priv/repo/seed_gl.exs` first.\n")

  {sys_id, bank_id} ->
    banking = Periods.banking_date(sys_id, bank_id)
    today = banking.current_banking_date

    report.("institution", "#{sys_id}/#{bank_id}")
    report.("banking date", today)

    # A spread across products, amounts and dates — enough that consolidation,
    # multi-day GL entries and the trial balance all have something to show.
    # day_offset must keep gl_date inside the OPEN period — `seed_gl.exs`
    # closes every prior month, so anything older is refused by the gate.
    # One deliberately-refused posting is added at the end so the Exceptions
    # tab is not empty either.
    events = [
      # Debit funding and spend
      {"DEPOSIT", "DEBIT", "debit-0001", "5000.00", %{"channel" => "SALARY"}, 0},
      {"DEPOSIT", "DEBIT", "debit-0002", "1200.00", %{"channel" => "BANK_TRANSFER"}, 0},
      {"PURCHASE", "DEBIT", "debit-0001", "349.90", %{}, 0},
      {"PURCHASE", "DEBIT", "debit-0001", "89.50", %{}, 1},
      {"ADJUSTMENT_CREDIT", "DEBIT", "debit-0002", "25.00",
       %{"narrative" => "Goodwill credit — disputed ATM fee"}, 1},

      # Prepaid load and spend
      {"DEPOSIT", "PREPAID", "prepaid-0001", "800.00", %{"channel" => "CASH"}, 0},
      {"PURCHASE", "PREPAID", "prepaid-0001", "120.75", %{}, 1},
      {"ADJUSTMENT_DEBIT", "PREPAID", "prepaid-0001", "15.00",
       %{"narrative" => "Reversal of duplicate load"}, 1},

      # Wallet
      {"DEPOSIT", "WALLET", "wallet-0001", "2500.00", %{"channel" => "UPI"}, 0},
      {"WITHDRAWAL", "WALLET", "wallet-0001", "400.00",
       %{"narrative" => "Wallet withdrawal to bank account"}, 1},

      # Credit product: interest and fees
      {"INTEREST", "CREDIT", "credit-0001", "142.37", %{}, 1},
      {"FEE", "CREDIT", "credit-0001", "150.00", %{"fee_type" => "ANNUAL_FEE"}, 1},
      {"FEE", "CREDIT", "credit-0002", "75.00", %{"fee_type" => "LATE_PAYMENT"}, 1},
      {"PAYMENT", "CREDIT", "credit-0001", "1000.00", %{}, 0},

      # Card settlement pairs
      {"PURCHASE", "CREDIT_CARD", "credit-0001", "2750.00", %{}, 0},
      {"CASH_ADV", "CREDIT_CARD", "credit-0002", "500.00", %{}, 1},
      {"INTEREST", "CREDIT_CARD", "credit-0002", "31.25", %{}, 1},
      {"DISPUTE_CREDIT", "CREDIT_CARD", "credit-0001", "220.00", %{}, 0}
    ]

    results =
      Enum.map(events, fn {event_type, product, account_ref, amount, bindings, day_offset} ->
        gl_date = Date.add(today, -day_offset)

        RuleEngine.execute(%{
          event_type: event_type,
          product: product,
          account_ref: account_ref,
          amount: Decimal.new(amount),
          idempotency_key: "GLDEMO-#{product}-#{event_type}-#{account_ref}-#{amount}",
          sys_id: sys_id,
          bank_id: bank_id,
          currency: "AED",
          posting_date: gl_date,
          gl_date: gl_date,
          transaction_date: gl_date,
          bindings: bindings,
          source_module: "seed_gl_demo"
        })
      end)

    posted = Enum.count(results, &match?({:ok, %{}}, &1))
    duplicate = Enum.count(results, &match?({:ok, :duplicate, _}, &1))
    failed = Enum.filter(results, &match?({:error, _}, &1)) ++
               Enum.filter(results, &match?({:error, _, _}, &1))

    report.("posted", posted)
    report.("already present (idempotent)", duplicate)
    report.("failed", length(failed))

    Enum.each(failed, fn
      {:error, :quarantined, e} -> IO.puts("  ! quarantined #{e.reason} gl_date=#{e.attempted_gl_date}")
      {:error, reason} -> IO.puts("  ! #{inspect(reason)}")
      other -> IO.puts("  ! #{inspect(other)}")
    end)

    # One deliberate exception so the Exceptions tab shows the control working.
    # A GL date two years back has no period, which is refused by the gate.
    case RuleEngine.execute(%{
           event_type: "DEPOSIT",
           product: "DEBIT",
           account_ref: "debit-0001",
           amount: Decimal.new("10.00"),
           idempotency_key: "GLDEMO-EXCEPTION-BACKDATED",
           sys_id: sys_id,
           bank_id: bank_id,
           gl_date: Date.add(today, -730),
           posting_date: Date.add(today, -730),
           bindings: %{"channel" => "BACKDATED"},
           source_module: "seed_gl_demo"
         }) do
      {:error, :quarantined, _} -> report.("deliberate exception", "quarantined (expected)")
      other -> report.("deliberate exception", "UNEXPECTED: #{inspect(other)}")
    end

    # --- What the screens will show ------------------------------------------
    counts = fn table ->
      Repo.one(from(t in table, select: count(t.id)))
    end

    IO.puts("\nnow visible in the GL admin screen:")
    report.("  posting sets", counts.("posting_sets"))
    report.("  posting entries", counts.("posting_entries"))
    report.("  posting legs", counts.("posting_legs"))
    report.("  journal entries", counts.("journal_entries"))
    report.("  consolidated GL entries", counts.("gl_ledger_entries"))
    report.("  open exceptions", counts.("gl_posting_exceptions"))

    {dr, cr} =
      Repo.one(
        from(l in "posting_legs",
          select:
            {sum(fragment("CASE WHEN ? = 'debit' THEN ? ELSE 0 END", l.direction, l.amount)),
             sum(fragment("CASE WHEN ? = 'credit' THEN ? ELSE 0 END", l.direction, l.amount))}
        )
      )

    IO.puts("")
    report.("total debits", dr)
    report.("total credits", cr)
    report.("balanced", Decimal.equal?(dr || Decimal.new(0), cr || Decimal.new(0)))

    IO.puts("\ndone.\n")
end
