defmodule VmuCore.FAS.GL.TrialBalance do
  @moduledoc """
  GL trial balance and summary report for finance reconciliation (FAS-P8 8E).

  Aggregates `cms_ledger_entries` by GL account code and period (month) to
  produce a standard trial balance showing debit/credit totals and net balance
  per account. Used by finance to reconcile card receivables, credit liability,
  fee revenue, and interchange expense buckets.

  ## Usage

      # Get trial balance for June 2026
      {:ok, rows} = TrialBalance.report(~D[2026-06-01], ~D[2026-06-30])

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
  alias VmuCore.{Repo, CMS.LedgerEntry}

  @account_names %{
    "1001" => "Card Receivables",
    "2001" => "Credit Liability",
    "4001" => "Fee Revenue",
    "5001" => "Interchange / MDR Expense",
    "9001" => "Suspense"
  }

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
  @spec report(Date.t(), Date.t()) :: {:ok, [row()]} | {:error, term()}
  def report(%Date{} = from_date, %Date{} = to_date) do
    rows =
      from(e in LedgerEntry,
        where: e.posting_date >= ^from_date and e.posting_date <= ^to_date,
        group_by: [
          fragment("to_char(?, 'YYYY-MM')", e.posting_date),
          e.gl_account_dr
        ],
        select: %{
          period:        fragment("to_char(?, 'YYYY-MM')", e.posting_date),
          account_code:  e.gl_account_dr,
          total_debits:  sum(e.dr_amount),
          total_credits: type(^Decimal.new(0), :decimal),
          entry_count:   count(e.entry_id)
        }
      )
      |> Repo.all()

    credit_rows =
      from(e in LedgerEntry,
        where: e.posting_date >= ^from_date and e.posting_date <= ^to_date,
        group_by: [
          fragment("to_char(?, 'YYYY-MM')", e.posting_date),
          e.gl_account_cr
        ],
        select: %{
          period:        fragment("to_char(?, 'YYYY-MM')", e.posting_date),
          account_code:  e.gl_account_cr,
          total_credits: sum(e.cr_amount),
          total_debits:  type(^Decimal.new(0), :decimal),
          entry_count:   count(e.entry_id)
        }
      )
      |> Repo.all()

    merged = merge_rows(rows, credit_rows)
    {:ok, Enum.sort_by(merged, &{&1.period, &1.account_code})}
  rescue
    e -> {:error, Exception.message(e)}
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

  defp merge_rows(debit_rows, credit_rows) do
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
        account_name:  Map.get(@account_names, account_code, account_code),
        total_debits:  total_debits,
        total_credits: total_credits,
        net_balance:   Decimal.sub(total_debits, total_credits),
        entry_count:   dr.entry_count + cr.entry_count
      }
    end)
  end
end
