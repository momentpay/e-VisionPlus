defmodule VmuCore.FAS.GL.TrialBalance do
  @moduledoc """
  GL trial balance and summary report for finance reconciliation (FAS-P8 8E).

  Aggregates the GL by account code and period (month) to produce a standard
  trial balance showing debit/credit totals and net balance per account. Used
  by finance to reconcile card receivables, credit liability, fee revenue, and
  interchange expense buckets.

  ## Source (GL Phase C2)

  Reads `gl_ledger_entries` — the consolidated general ledger — rather than
  `cms_ledger_entries`. Two things change as a result, both corrections:

  1. **Account names come from `gl_accounts`.** This module carried a
     hardcoded map of five names against a chart that now has thirty, so
     twenty-five accounts rendered as bare codes in a report whose entire
     purpose is naming them.

  2. **`report/3` takes an institution.** The old query summed every
     institution together, which is not a trial balance of anything — a
     multi-bank total does not reconcile against any one bank's books. The
     institution is optional for compatibility, and omitting it now means
     "all institutions, deliberately", not "institution is not a concept".

  `gl_ledger_entries` groups by `gl_date`, the date the books record a
  movement, which is the correct axis for a trial balance. The legacy query
  grouped by `posting_date`. They differ for backdated corrections: a
  reversal posted today against last month's transaction belongs in *this*
  month's trial balance, and under the old grouping it did not.

  ## Usage

      # Get trial balance for June 2026, one institution
      {:ok, rows} = TrialBalance.report(~D[2026-06-01], ~D[2026-06-30], sys_id: "MMPD", bank_id: "MMBD")

      # Export as CSV for finance team
      csv = TrialBalance.to_csv(rows)
      File.write!("trial_balance_jun2026.csv", csv)

  ## Output structure

  Each row in the report:

      %{
        period:        "2026-06",
        account_code:  "1001",
        account_name:  "Card Receivables",
        total_debits:  Decimal.new("142500.00"),
        total_credits: Decimal.new("0.00"),
        net_balance:   Decimal.new("142500.00"),   # debits - credits
        entry_count:   47
      }

  Accounts with zero activity in the period are excluded.
  """

  import Ecto.Query
  alias VmuCore.Repo
  alias VmuCore.GL.{ChartOfAccounts, LedgerEntry}

  @type row :: %{
    period:        String.t(),
    account_code:  String.t(),
    account_name:  String.t(),
    total_debits:  Decimal.t(),
    total_credits: Decimal.t(),
    net_balance:   Decimal.t(),
    entry_count:   non_neg_integer()
  }

  @doc """
  Produce a trial balance for entries with `posting_date` in `[from_date, to_date]`.

  Groups by month so a multi-month range produces one row per account per month.
  """
  @spec report(Date.t(), Date.t(), keyword()) :: {:ok, [row()]} | {:error, term()}
  def report(%Date{} = from_date, %Date{} = to_date, opts \\ []) do
    debit_rows = side(from_date, to_date, opts, :dr_account)
    credit_rows = side(from_date, to_date, opts, :cr_account)

    merged = merge_rows(debit_rows, credit_rows, account_names())
    {:ok, Enum.sort_by(merged, &{&1.period, &1.account_code})}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # One pass per side. `gl_ledger_entries` holds a debit account and a credit
  # account on each row with a single amount, so the debit total for an account
  # is the sum of rows where it is the debit side, and likewise for credit —
  # the same shape the legacy table had, over consolidated rows rather than
  # individual postings.
  defp side(from_date, to_date, opts, field) do
    base =
      from(e in LedgerEntry,
        where: e.gl_date >= ^from_date and e.gl_date <= ^to_date
      )
      |> filter_institution(opts)

    rows =
      from(e in base,
        group_by: [fragment("to_char(?, 'YYYY-MM')", e.gl_date), field(e, ^field)],
        select: %{
          period: fragment("to_char(?, 'YYYY-MM')", e.gl_date),
          account_code: field(e, ^field),
          amount: sum(e.amount),
          # `entry_count` is the number of postings consolidated into the GL
          # row, not the number of GL rows — summing it keeps the report
          # counting the same thing the legacy per-posting query counted.
          entry_count: sum(e.entry_count)
        }
      )
      |> Repo.all()

    Enum.map(rows, fn r ->
      {debits, credits} =
        case field do
          :dr_account -> {r.amount, Decimal.new(0)}
          :cr_account -> {Decimal.new(0), r.amount}
        end

      %{
        period: r.period,
        account_code: r.account_code,
        total_debits: debits,
        total_credits: credits,
        entry_count: r.entry_count
      }
    end)
  end

  defp filter_institution(query, opts) do
    query
    |> then(fn q -> if v = opts[:sys_id], do: where(q, [e], e.sys_id == ^v), else: q end)
    |> then(fn q -> if v = opts[:bank_id], do: where(q, [e], e.bank_id == ^v), else: q end)
  end

  # Names from the chart of accounts, which is the registry Phase A made
  # authoritative. Loaded once per report rather than per row.
  defp account_names do
    ChartOfAccounts.all(active: :all)
    |> Map.new(&{&1.code, &1.name})
  end

  @doc "Render trial balance rows as a UTF-8 CSV string."
  @spec to_csv([row()]) :: String.t()
  def to_csv(rows) do
    header = "Period,Account Code,Account Name,Total Debits,Total Credits,Net Balance,Entry Count\n"

    lines =
      Enum.map(rows, fn r ->
        [
          r.period,
          r.account_code,
          r.account_name,
          Decimal.to_string(r.total_debits),
          Decimal.to_string(r.total_credits),
          Decimal.to_string(r.net_balance),
          to_string(r.entry_count)
        ]
        |> Enum.join(",")
      end)

    header <> Enum.join(lines, "\n")
  end

  @doc "Summary totals across all accounts for the period."
  @spec summary([row()]) :: %{
    total_debits: Decimal.t(),
    total_credits: Decimal.t(),
    entry_count: non_neg_integer()
  }
  def summary(rows) do
    Enum.reduce(rows, %{total_debits: Decimal.new(0), total_credits: Decimal.new(0), entry_count: 0},
      fn r, acc ->
        %{acc |
          total_debits:  Decimal.add(acc.total_debits, r.total_debits),
          total_credits: Decimal.add(acc.total_credits, r.total_credits),
          entry_count:   acc.entry_count + r.entry_count
        }
      end)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp merge_rows(debit_rows, credit_rows, names) do
    # Build a map keyed by {period, account_code} for merging
    debit_map =
      Map.new(debit_rows, fn r -> {{r.period, r.account_code}, r} end)

    credit_map =
      Map.new(credit_rows, fn r -> {{r.period, r.account_code}, r} end)

    all_keys = MapSet.union(MapSet.new(Map.keys(debit_map)), MapSet.new(Map.keys(credit_map)))

    Enum.map(all_keys, fn key ->
      dr = Map.get(debit_map,  key, %{total_debits: Decimal.new(0),  entry_count: 0})
      cr = Map.get(credit_map, key, %{total_credits: Decimal.new(0), entry_count: 0})

      {period, account_code} = key
      total_debits  = dr.total_debits  || Decimal.new(0)
      total_credits = cr.total_credits || Decimal.new(0)

      %{
        period:        period,
        account_code:  account_code,
        account_name:  Map.get(names, account_code, account_code),
        total_debits:  total_debits,
        total_credits: total_credits,
        net_balance:   Decimal.sub(total_debits, total_credits),
        entry_count:   dr.entry_count + cr.entry_count
      }
    end)
  end
end
