defmodule VmuCore.WPS.RefundsTest do
  @moduledoc """
  Employer refunds and the regulatory report (Phase W4).

  Real Postgres and the real ledger — the two things worth proving here are that
  the maker-checker control cannot be bypassed, and that wages the worker has
  already spent cannot be clawed back.
  """
  use VmuCore.DataCase, async: false

  alias VmuCore.CMS.{PrepaidAccount, PrepaidLedger}
  alias VmuCore.GL.InstitutionResolver
  alias VmuCore.GLFixtures

  alias VmuCore.Shared.{
    BankParameter,
    BlockParameter,
    Customer,
    LogoParameter,
    ModuleConfigEngine,
    ModuleConfigWriter,
    SysParameter
  }

  alias VmuCore.WPS.{
    Disbursement,
    Ingestion,
    RefundRequest,
    Refunds,
    RegulatoryReport,
    Roster,
    SalaryCredit
  }

  alias Decimal, as: D

  setup do
    :ok = GLFixtures.seed_posting_engine!()
    InstitutionResolver.reset()
    on_exit(&InstitutionResolver.reset/0)
    :ok
  end

  # ---------------------------------------------------------------------------

  defp institution do
    n = System.unique_integer([:positive])
    sys_id = "R#{100 + rem(n, 900)}"
    bank_id = "F#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "B#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "t"}) |> Repo.insert!()

    %BankParameter{}
    |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "t"})
    |> Repo.insert!()

    %LogoParameter{}
    |> LogoParameter.changeset(%{
      sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "606060", description: "t"
    })
    |> Repo.insert!()

    %BlockParameter{}
    |> BlockParameter.changeset(%{
      sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id
    })
    |> Repo.insert!()

    :ok = GLFixtures.open_institution!(sys_id, bank_id)
    Process.put({:hier, sys_id, bank_id}, {logo_id, block_id})
    {sys_id, bank_id}
  end

  defp employer_fixture(layout \\ %{}) do
    {sys_id, bank_id} = institution()
    n = System.unique_integer([:positive])
    code = "EMP#{n}"

    {:ok, employer} =
      Roster.onboard_employer(%{
        sys_id: sys_id, bank_id: bank_id,
        employer_code: code, employer_name: "Gulf Contracting #{n}"
      })

    {:ok, existing} = ModuleConfigEngine.get("wps", "employer_config", sys_id, bank_id)

    {:ok, _} =
      ModuleConfigWriter.put(
        "wps", "employer_config",
        Map.put(existing || %{}, code, layout),
        %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id},
        %{username: "test", role: "sysadmin"}
      )

    ModuleConfigEngine.refresh_all()
    employer
  end

  defp prepaid_account(employer) do
    n = System.unique_integer([:positive])
    {logo_id, block_id} = Process.get({:hier, employer.sys_id, employer.bank_id})

    customer =
      %Customer{}
      |> Customer.changeset(%{
        sys_id: employer.sys_id, bank_id: employer.bank_id,
        first_name: "W", last_name: "Worker#{n}",
        id_type: "PASSPORT", id_number: "WPS-#{n}"
      })
      |> Repo.insert!()

    %PrepaidAccount{}
    |> PrepaidAccount.changeset(%{
      customer_id: customer.customer_id,
      sys_id: employer.sys_id, bank_id: employer.bank_id,
      logo_id: logo_id, block_id: block_id,
      currency: "AED", opened_at: Date.utc_today(), status: "ACTIVE"
    })
    |> Repo.insert!()
  end

  @csv """
  employee_id,payment_reference,net_amount,payment_date
  E001,PAY-001,1500.00,2026-07-31
  E002,PAY-002,2000.00,2026-07-31
  """

  # An employer with two workers paid.
  defp paid_employer(content \\ @csv) do
    employer = employer_fixture()

    accounts =
      for id <- ["E001", "E002"], into: %{} do
        account = prepaid_account(employer)

        {:ok, _} =
          Roster.link(%{
            employer_id: employer.employer_id, employee_id: id,
            prepaid_account_id: account.prepaid_account_id
          })

        {id, account}
      end

    InstitutionResolver.reset()

    {:ok, file, _} = Ingestion.ingest(employer.employer_id, "july.csv", content)
    {:ok, _} = Disbursement.post_batch(file.wps_file_id)

    {employer, accounts, file}
  end

  defp credit_for(reference), do: Repo.get_by!(SalaryCredit, payment_reference: reference)

  # ---------------------------------------------------------------------------

  describe "requesting a refund" do
    test "defaults to the whole credit" do
      {_employer, _accounts, _file} = paid_employer()
      credit = credit_for("PAY-001")

      assert {:ok, request} =
               Refunds.request(credit.salary_credit_id,
                 reason: "employer overpaid this cycle",
                 requested_by: "ops1"
               )

      assert request.status == "PENDING"
      assert D.equal?(request.amount, D.new("1500.00"))
      assert request.requested_by == "ops1"
    end

    test "a partial amount is allowed, because overpayment is the realistic case" do
      {_e, _a, _f} = paid_employer()
      credit = credit_for("PAY-001")

      assert {:ok, request} =
               Refunds.request(credit.salary_credit_id,
                 amount: D.new("500.00"),
                 reason: "overpaid by five hundred",
                 requested_by: "ops1"
               )

      assert D.equal?(request.amount, D.new("500.00"))
    end

    test "more than was paid is refused" do
      {_e, _a, _f} = paid_employer()
      credit = credit_for("PAY-001")

      assert {:error, {:exceeds_credit, _}} =
               Refunds.request(credit.salary_credit_id,
                 amount: D.new("9999.00"),
                 reason: "wishful thinking",
                 requested_by: "ops1"
               )
    end

    test "an unpaid line cannot be refunded — there is nothing to recover" do
      employer = employer_fixture()
      InstitutionResolver.reset()
      {:ok, file, _} = Ingestion.ingest(employer.employer_id, "july.csv", @csv)
      {:ok, _} = Disbursement.post_batch(file.wps_file_id)

      credit = credit_for("PAY-001")
      assert credit.status == "FAILED"

      # An unpaid line is cancelled through the exception queue, not refunded.
      assert {:error, {:not_posted, "FAILED"}} =
               Refunds.request(credit.salary_credit_id,
                 reason: "not paid anyway",
                 requested_by: "ops1"
               )
    end

    test "only one request may be pending per payment" do
      {_e, _a, _f} = paid_employer()
      credit = credit_for("PAY-001")

      {:ok, _} =
        Refunds.request(credit.salary_credit_id, reason: "first request", requested_by: "ops1")

      # Two approvals of two requests would recover the money twice.
      assert {:error, changeset} =
               Refunds.request(credit.salary_credit_id,
                 reason: "second request",
                 requested_by: "ops2"
               )

      refute changeset.valid?
    end
  end

  describe "maker-checker" do
    setup do
      {employer, accounts, _file} = paid_employer()
      credit = credit_for("PAY-001")

      {:ok, request} =
        Refunds.request(credit.salary_credit_id,
          reason: "employer overpaid this cycle",
          requested_by: "ops1"
        )

      %{employer: employer, accounts: accounts, credit: credit, request: request}
    end

    test "the requester cannot approve their own request", %{request: request} do
      assert {:error, :maker_cannot_be_checker} =
               Refunds.approve(request.refund_request_id, "ops1", "approving my own")

      # And nothing moved.
      assert Refunds.get(request.refund_request_id).status == "PENDING"
    end

    test "the requester cannot reject their own request either", %{request: request} do
      assert {:error, :maker_cannot_be_checker} =
               Refunds.reject(request.refund_request_id, "ops1", "never mind")
    end

    test "a different person approves, and the money comes back", %{
      request: request,
      accounts: accounts
    } do
      account_id = accounts["E001"].prepaid_account_id
      assert D.equal?(PrepaidLedger.balance(account_id), D.new("1500.00"))

      assert {:ok, approved} =
               Refunds.approve(request.refund_request_id, "supervisor1", "verified with employer")

      assert approved.status == "APPROVED"
      assert approved.decided_by == "supervisor1"
      assert approved.decided_at

      assert D.equal?(PrepaidLedger.balance(account_id), D.new(0))
    end

    test "a partial approval takes only what was asked for", %{
      credit: credit,
      accounts: accounts,
      request: request
    } do
      # Replace the full request with a partial one.
      {:ok, _} = Refunds.reject(request.refund_request_id, "supervisor1", "superseded")

      {:ok, partial} =
        Refunds.request(credit.salary_credit_id,
          amount: D.new("500.00"),
          reason: "overpaid by five hundred",
          requested_by: "ops1"
        )

      {:ok, _} = Refunds.approve(partial.refund_request_id, "supervisor1", "ok")

      assert D.equal?(
               PrepaidLedger.balance(accounts["E001"].prepaid_account_id),
               D.new("1000.00")
             )
    end

    test "rejection leaves the money alone", %{request: request, accounts: accounts} do
      assert {:ok, rejected} =
               Refunds.reject(request.refund_request_id, "supervisor1", "employer withdrew it")

      assert rejected.status == "REJECTED"
      assert rejected.decision_note == "employer withdrew it"

      assert D.equal?(
               PrepaidLedger.balance(accounts["E001"].prepaid_account_id),
               D.new("1500.00")
             )
    end

    test "a decided request cannot be decided again", %{request: request} do
      {:ok, _} = Refunds.reject(request.refund_request_id, "supervisor1", "no")

      assert {:error, {:already_decided, "REJECTED"}} =
               Refunds.approve(request.refund_request_id, "supervisor2", "actually yes")
    end
  end

  describe "wages already spent cannot be clawed back" do
    test "approval fails and the request is FAILED, not APPROVED" do
      {_employer, accounts, _file} = paid_employer()
      account_id = accounts["E001"].prepaid_account_id

      # The worker spends most of it, which is the entire point of being paid.
      {:ok, _} = PrepaidLedger.spend(account_id, D.new("1400.00"), posted_by: "worker")
      assert D.equal?(PrepaidLedger.balance(account_id), D.new("100.00"))

      credit = credit_for("PAY-001")

      {:ok, request} =
        Refunds.request(credit.salary_credit_id,
          reason: "employer wants it all back",
          requested_by: "ops1"
        )

      assert {:error, :insufficient_funds} =
               Refunds.approve(request.refund_request_id, "supervisor1", "try it")

      # FAILED, not APPROVED: approving something that did not happen would be a
      # lie in the audit trail. And not REJECTED either — nobody decided against
      # it, the money was simply gone.
      reloaded = Refunds.get(request.refund_request_id)
      assert reloaded.status == "FAILED"
      assert reloaded.failure_reason =~ "insufficient_funds"

      # The worker keeps what is left.
      assert D.equal?(PrepaidLedger.balance(account_id), D.new("100.00"))
    end
  end

  describe "the GL side of a refund" do
    test "posts REVERSAL, not PURCHASE — a recovery is not the worker spending" do
      {_employer, accounts, _file} = paid_employer()
      credit = credit_for("PAY-001")

      {:ok, request} =
        Refunds.request(credit.salary_credit_id, reason: "overpaid", requested_by: "ops1")

      {:ok, _} = Refunds.approve(request.refund_request_id, "supervisor1", "ok")

      ref = accounts["E001"].prepaid_account_id

      events =
        Repo.all(
          from j in VmuCore.Posting.JournalEntry,
            join: s in assoc(j, :posting_set),
            where: j.account_ref == ^ref,
            select: {s.event_type, j.product, j.dr_gl_account, j.cr_gl_account}
        )

      # DEPOSIT paid the wage in; REVERSAL took it back. They are distinguishable
      # only by event type — the account pair for REVERSAL and PURCHASE is the
      # same — which is why the explicit event type matters.
      assert {"DEPOSIT", "WPS_PREPAID", "3005", "2007"} in events
      assert {"REVERSAL", "WPS_PREPAID", "2007", "3005"} in events
    end
  end

  describe "the regulatory report" do
    test "lists unpaid workers as first-class rows with their reason" do
      employer = employer_fixture()
      # Only E001 is linked; E002 will not be paid.
      account = prepaid_account(employer)

      {:ok, _} =
        Roster.link(%{
          employer_id: employer.employer_id, employee_id: "E001",
          prepaid_account_id: account.prepaid_account_id
        })

      InstitutionResolver.reset()

      {:ok, file, _} = Ingestion.ingest(employer.employer_id, "july.csv", @csv)
      {:ok, _} = Disbursement.post_batch(file.wps_file_id)

      {:ok, report} =
        RegulatoryReport.generate(employer.employer_id, ~D[2026-07-01], ~D[2026-07-31])

      assert report.summary.total_count == 2
      assert report.summary.paid_count == 1
      assert report.summary.unpaid_count == 1
      assert D.equal?(report.summary.paid_total, D.new("1500.00"))
      assert D.equal?(report.summary.unpaid_total, D.new("2000.00"))

      unpaid = Enum.find(report.rows, &(&1.employee_id == "E002"))

      # The scheme exists to make non-payment visible, so the reason travels
      # with the row rather than the row being omitted.
      assert unpaid.status == "NOT_PAID"
      assert unpaid.failure_reason =~ "BENEFICIARY_UNRESOLVED"
    end

    test "the period is the employer's pay date, not our processing date" do
      {employer, _accounts, _file} = paid_employer()

      # Paid today; the file says the wages are for 2026-07-31.
      {:ok, in_period} =
        RegulatoryReport.generate(employer.employer_id, ~D[2026-07-01], ~D[2026-07-31])

      {:ok, out_of_period} =
        RegulatoryReport.generate(employer.employer_id, ~D[2026-06-01], ~D[2026-06-30])

      assert in_period.summary.total_count == 2
      assert out_of_period.summary.total_count == 0
    end

    test "renders CSV with the employer's own column names" do
      {employer, _a, _f} = paid_employer()

      {:ok, report} =
        RegulatoryReport.generate(employer.employer_id, ~D[2026-07-01], ~D[2026-07-31])

      config = %{
        "export_mapping" => %{
          "employee_id" => "StaffNo",
          "net_amount" => "AmountPaid",
          "status" => "PaymentStatus"
        }
      }

      assert {:ok, csv, "CSV"} = RegulatoryReport.render(report, config)

      [header | rows] = String.split(String.trim(csv), "\n")

      assert header =~ "StaffNo"
      assert header =~ "AmountPaid"
      assert header =~ "PaymentStatus"
      # Unmapped columns keep their own names.
      assert header =~ "payment_reference"
      assert length(rows) == 2
    end

    test "a failure reason containing commas does not break the row" do
      employer = employer_fixture()
      InstitutionResolver.reset()
      {:ok, file, _} = Ingestion.ingest(employer.employer_id, "july.csv", @csv)
      {:ok, _} = Disbursement.post_batch(file.wps_file_id)

      {:ok, report} =
        RegulatoryReport.generate(employer.employer_id, ~D[2026-07-01], ~D[2026-07-31])

      {:ok, csv, _} = RegulatoryReport.render(report, %{})

      [header | rows] = String.split(String.trim(csv), "\n")
      expected_columns = length(String.split(header, ","))

      # Quoting, not luck: reasons contain commas routinely.
      for row <- rows do
        assert length(parse_csv_row(row)) == expected_columns
      end
    end

    test "renders JSON when configured" do
      {employer, _a, _f} = paid_employer()

      {:ok, report} =
        RegulatoryReport.generate(employer.employer_id, ~D[2026-07-01], ~D[2026-07-31])

      assert {:ok, json, "JSON"} = RegulatoryReport.render(report, %{"file_format" => "JSON"})

      decoded = Jason.decode!(json)
      assert length(decoded) == 2
      assert Enum.all?(decoded, &Map.has_key?(&1, "payment_reference"))
    end

    test "dates follow the configured format" do
      {employer, _a, _f} = paid_employer()

      {:ok, report} =
        RegulatoryReport.generate(employer.employer_id, ~D[2026-07-01], ~D[2026-07-31])

      {:ok, csv, _} = RegulatoryReport.render(report, %{"date_format" => "%Y%m%d"})

      assert csv =~ "20260731"
      refute csv =~ "2026-07-31"
    end
  end

  # A minimal quote-aware splitter, so the assertion tests the CSV rather than
  # re-implementing the bug it is checking for.
  defp parse_csv_row(row) do
    row
    |> String.graphemes()
    |> Enum.reduce({[], "", false}, fn
      ~s("), {fields, current, in_quotes} -> {fields, current, not in_quotes}
      ",", {fields, current, false} -> {[current | fields], "", false}
      char, {fields, current, in_quotes} -> {fields, current <> char, in_quotes}
    end)
    |> then(fn {fields, current, _} -> Enum.reverse([current | fields]) end)
  end
end
