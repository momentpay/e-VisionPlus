defmodule VmuCore.HCS.ConsolidatedStatementGenerator do
  @moduledoc """
  Generates company-level consolidated billing statements by aggregating
  spend, payments, fees, and interest across all employee card accounts.
  """

  alias VmuCore.HCS.{Company, EmployeeCard, ConsolidatedStatement}
  alias VmuCore.CMS.BalanceBucket
  alias VmuCore.GL.LedgerQuery
  alias VmuCore.Repo
  import Ecto.Query
  alias Decimal, as: D

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

    # The closing balance is the sum of each employee account's latest balance
    # bucket, which is where CMS actually keeps a balance.
    #
    # Three separate reasons the previous version could not work:
    # it selected `a.current_balance`, a field `CMS.Account` does not have;
    # it filtered on `a.id`, a field `CMS.Account` does not have either (its
    # primary key is `account_id` — the same id-vs-account_id slip
    # `HCS.CompanyOnboarding` calls out and fixed for itself); and a single
    # scalar on `cms_accounts` was never the right source regardless, because
    # the balance is decomposed across `cms_balance_buckets` and summed by
    # `BalanceBucket.total/1`.
    closing_balance =
      from(b in BalanceBucket,
        where: b.account_id in ^employee_account_ids and b.balance_date <= ^statement_date,
        distinct: b.account_id,
        order_by: [asc: b.account_id, desc: b.balance_date]
      )
      |> Repo.all()
      |> Enum.reduce(D.new(0), fn bucket, acc -> D.add(acc, BalanceBucket.total(bucket)) end)

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
    # "Etc/UTC", not "UTC". The default time zone database only knows the IANA
    # names, so `DateTime.new!/3` with "UTC" raises
    # `:utc_only_time_zone_database` — which it did on every call, before this
    # function reached a single query. `HCS.FleetReport` had it right.
    start_dt = DateTime.new!(period_from, ~T[00:00:00], "Etc/UTC")
    end_dt   = DateTime.new!(period_to,   ~T[23:59:59], "Etc/UTC")

    # GL Phase C2 — see `GL.LedgerQuery`.
    #
    # `inserted_from`/`inserted_to`, not `from`/`to`: this window has always
    # been over row-write time rather than posting date, and migrating it onto
    # posting date would change which activity a statement covers.
    #
    # HCS rides on `cms_accounts` — onboarding provisions a real `CMS.Account`
    # per employee and vehicle — so these resolve as product `CREDIT` and were
    # mirrored like any other posting.
    #
    # ## The previous version reported spend and payments as the same number
    #
    # It took `spend` from `sum(dr_amount)` and `payments` from
    # `sum(cr_amount)` over the same rows. Under double entry those columns are
    # equal on **every** row — `CMS.LedgerEntry`'s changeset enforces it — so
    # the two totals were always identical, and `fees`/`interest` were
    # hardcoded to zero besides. A corporate consolidated statement showing
    # spend == payments is not a rounding problem, it is the wrong question.
    #
    # Splitting by event type is the right one, and it fills in the two
    # hardcoded zeroes as a side effect. Found 2026-08-05 while migrating: the
    # live figure was 134,953.57 on both sides for every company.
    window = [account_ref: account_ids, inserted_from: start_dt, inserted_to: end_dt]

    %{
      spend:    LedgerQuery.sum_amount(window ++ [transaction_code: ["PURCHASE", "CASH_ADV"]]),
      payments: LedgerQuery.sum_amount(window ++ [transaction_code: "PAYMENT"]),
      fees:     LedgerQuery.sum_amount(window ++ [transaction_code: "FEE"]),
      interest: LedgerQuery.sum_amount(window ++ [transaction_code: "INTEREST"])
    }
  end

  defp aggregate_period_activity([], _, _) do
    %{spend: D.new(0), payments: D.new(0), fees: D.new(0), interest: D.new(0)}
  end
end
