defmodule VmuCore.HCS.ConsolidatedStatementGenerator do
  @moduledoc """
  Generates company-level consolidated billing statements by aggregating
  spend, payments, fees, and interest across all employee card accounts.
  """

  alias VmuCore.HCS.{Company, EmployeeCard, ConsolidatedStatement}
  alias VmuCore.CMS.{Account, LedgerEntry}
  alias VmuCore.Repo
  import Ecto.Query
  import Decimal, as: D

  @doc """
  Generate consolidated statements for all active companies whose billing_cycle_day
  matches the given statement_date's day of month.
  """
  def generate_for_date(statement_date) do
    companies =
      from(c in Company,
        where: c.status == "ACTIVE"
          and c.billing_cycle_day == ^statement_date.day
      )
      |> Repo.all()

    results = Enum.map(companies, fn company ->
      case generate_company_statement(company, statement_date) do
        {:ok, stmt}      -> {:ok, stmt}
        {:error, reason} -> {:error, {company.id, reason}}
      end
    end)

    ok_count = Enum.count(results, &match?({:ok, _}, &1))
    err_count = Enum.count(results, &match?({:error, _}, &1))

    {:ok, %{generated: ok_count, failed: err_count}}
  end

  defp generate_company_statement(company, statement_date) do
    period_to   = statement_date
    period_from = Date.add(statement_date, -30)

    employee_account_ids =
      from(ec in EmployeeCard,
        where: ec.company_id == ^company.id and ec.status == "ACTIVE",
        select: ec.employee_account_id
      )
      |> Repo.all()

    totals = aggregate_period_activity(employee_account_ids, period_from, period_to)

    closing_balance =
      from(a in Account,
        where: a.id in ^employee_account_ids,
        select: coalesce(sum(a.current_balance), 0)
      )
      |> Repo.one()
      |> Kernel.||(D.new(0))

    minimum_payment = D.max(D.mult(closing_balance, D.new("0.05")), D.new(100))

    %ConsolidatedStatement{}
    |> ConsolidatedStatement.changeset(%{
      company_id:       company.id,
      statement_date:   statement_date,
      period_from:      period_from,
      period_to:        period_to,
      total_spend:      totals.spend,
      total_payments:   totals.payments,
      total_fees:       totals.fees,
      total_interest:   totals.interest,
      closing_balance:  closing_balance,
      minimum_payment:  minimum_payment,
      payment_due_date: Date.add(statement_date, 25),
      employee_count:   length(employee_account_ids),
      status:           "GENERATED",
      inserted_at:      DateTime.utc_now()
    })
    |> Repo.insert(
      on_conflict: [set: [status: "GENERATED", closing_balance: closing_balance,
                          total_spend: totals.spend, minimum_payment: minimum_payment]],
      conflict_target: [:company_id, :statement_date]
    )
  end

  defp aggregate_period_activity(account_ids, period_from, period_to) when account_ids != [] do
    start_dt = DateTime.new!(period_from, ~T[00:00:00], "UTC")
    end_dt   = DateTime.new!(period_to,   ~T[23:59:59], "UTC")

    entries =
      from(l in LedgerEntry,
        where: l.account_id in ^account_ids
          and l.inserted_at >= ^start_dt
          and l.inserted_at <= ^end_dt,
        select: %{
          debit_total:  coalesce(sum(l.dr_amount), 0),
          credit_total: coalesce(sum(l.cr_amount), 0)
        }
      )
      |> Repo.one()

    %{
      spend:    (entries && entries.debit_total)  || D.new(0),
      payments: (entries && entries.credit_total) || D.new(0),
      fees:     D.new(0),
      interest: D.new(0)
    }
  end
  defp aggregate_period_activity([], _, _) do
    %{spend: D.new(0), payments: D.new(0), fees: D.new(0), interest: D.new(0)}
  end
end
