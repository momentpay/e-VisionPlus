defmodule VmuCore.WPS.DisbursementTest do
  @moduledoc """
  Salary batch disbursement (Phase W3).

  Real Postgres and the real posting engine — this is the phase where money
  moves, and the two guarantees that matter (a re-run does not pay twice, one
  bad line does not stop the batch) are both properties of the database and the
  ledger rather than of this module in isolation.
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

  alias VmuCore.WPS.{Disbursement, Ingestion, Roster, SalaryCredit, SalaryCreditException}
  alias Decimal, as: D

  setup do
    :ok = GLFixtures.seed_posting_engine!()
    InstitutionResolver.reset()
    on_exit(&InstitutionResolver.reset/0)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp institution do
    n = System.unique_integer([:positive])
    sys_id = "J#{100 + rem(n, 900)}"
    bank_id = "K#{100 + rem(n, 900)}"
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

    # W3 posts for real, so the institution must be open for business.
    :ok = GLFixtures.open_institution!(sys_id, bank_id)

    Process.put({:hier, sys_id, bank_id}, {logo_id, block_id})
    {sys_id, bank_id}
  end

  defp employer_fixture do
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
        "wps",
        "employer_config",
        Map.put(existing || %{}, code, %{}),
        %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id},
        %{username: "test", role: "sysadmin"}
      )

    ModuleConfigEngine.refresh_all()
    employer
  end

  defp prepaid_account(employer, opts \\ []) do
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
      currency: "AED", opened_at: Date.utc_today(),
      status: Keyword.get(opts, :status, "ACTIVE")
    })
    |> Repo.insert!()
  end

  defp link(employer, employee_id, account) do
    {:ok, _} =
      Roster.link(%{
        employer_id: employer.employer_id,
        employee_id: employee_id,
        prepaid_account_id: account.prepaid_account_id
      })
  end

  @csv """
  employee_id,payment_reference,net_amount
  E001,PAY-001,1500.00
  E002,PAY-002,2000.00
  E003,PAY-003,2500.00
  """

  defp ingest(employer, content \\ @csv, filename \\ "july.csv") do
    {:ok, file, _} = Ingestion.ingest(employer.employer_id, filename, content)
    file
  end

  defp fully_linked_employer do
    employer = employer_fixture()

    accounts =
      for id <- ["E001", "E002", "E003"], into: %{} do
        account = prepaid_account(employer)
        link(employer, id, account)
        {id, account}
      end

    InstitutionResolver.reset()
    {employer, accounts}
  end

  # ---------------------------------------------------------------------------

  describe "pre_flight/1" do
    test "reports what would be paid without moving anything" do
      {employer, accounts} = fully_linked_employer()
      file = ingest(employer)

      assert {:ok, report} = Disbursement.pre_flight(file.wps_file_id)

      assert report.payable_count == 3
      assert D.equal?(report.payable_total, D.new("6000.00"))
      assert report.blocked_count == 0
      assert report.employer_disbursable

      # Nothing moved.
      account = accounts["E001"]
      assert D.equal?(PrepaidLedger.balance(account.prepaid_account_id), D.new(0))

      credits = Ingestion.list_credits(file.wps_file_id)
      assert Enum.all?(credits, &(&1.status == "PARSED"))
    end

    test "groups blockers by cause, which is how an operator fixes them" do
      employer = employer_fixture()

      # E001 linked and payable; E002 unlinked; E003 linked to a closed account.
      link(employer, "E001", prepaid_account(employer))
      link(employer, "E003", prepaid_account(employer, status: "CLOSED"))
      InstitutionResolver.reset()

      file = ingest(employer)

      assert {:ok, report} = Disbursement.pre_flight(file.wps_file_id)

      assert report.payable_count == 1
      assert report.blocked_count == 2

      assert %{"BENEFICIARY_UNRESOLVED" => unresolved} = report.blockers
      assert unresolved.count == 1
      assert unresolved.employees == ["E002"]

      assert %{"ACCOUNT_INACTIVE" => inactive} = report.blockers
      assert inactive.count == 1
      assert inactive.employees == ["E003"]
    end

    test "an unverified link is distinguished from a missing one" do
      employer = employer_fixture()
      # Linked but with no account: UNVERIFIED, not absent.
      {:ok, _} = Roster.link(%{employer_id: employer.employer_id, employee_id: "E001"})
      InstitutionResolver.reset()

      file = ingest(employer)
      {:ok, report} = Disbursement.pre_flight(file.wps_file_id)

      # Different remediation: one needs an account attached, the other needs
      # the worker identified at all.
      assert %{"BENEFICIARY_NOT_ACTIVE" => %{employees: ["E001"]}} = report.blockers
      assert %{"BENEFICIARY_UNRESOLVED" => %{count: 2}} = report.blockers
    end
  end

  describe "post_batch/2" do
    test "pays every payable line and credits the real prepaid balance" do
      {employer, accounts} = fully_linked_employer()
      file = ingest(employer)

      assert {:ok, result} = Disbursement.post_batch(file.wps_file_id)

      assert result.posted == 3
      assert result.failed == 0
      assert D.equal?(result.amount, D.new("6000.00"))

      # The money is really there, through the same path any prepaid load uses.
      assert D.equal?(PrepaidLedger.balance(accounts["E001"].prepaid_account_id), D.new("1500.00"))
      assert D.equal?(PrepaidLedger.balance(accounts["E003"].prepaid_account_id), D.new("2500.00"))

      credits = Ingestion.list_credits(file.wps_file_id)
      assert Enum.all?(credits, &(&1.status == "POSTED"))
      assert Enum.all?(credits, &(&1.posted_at != nil))
    end

    test "posts under the WPS_PREPAID product, not ordinary prepaid" do
      {employer, accounts} = fully_linked_employer()
      file = ingest(employer)

      {:ok, _} = Disbursement.post_batch(file.wps_file_id)

      ref = accounts["E001"].prepaid_account_id

      # Joining the roster is what makes this salary float rather than gift-card
      # float, and the GL has to say so.
      assert {:ok, "WPS_PREPAID"} = InstitutionResolver.resolve_product(ref)

      posting =
        Repo.one(
          from j in VmuCore.Posting.JournalEntry,
            where: j.account_ref == ^ref,
            select: {j.product, j.dr_gl_account, j.cr_gl_account}
        )

      assert {"WPS_PREPAID", "3005", "2007"} = posting
    end

    test "one bad line does not stop the batch" do
      employer = employer_fixture()
      good = prepaid_account(employer)
      link(employer, "E001", good)
      link(employer, "E003", prepaid_account(employer))
      InstitutionResolver.reset()

      file = ingest(employer)

      assert {:ok, result} = Disbursement.post_batch(file.wps_file_id)

      # E002 is unlinked. The other two are still paid — which is the entire
      # reason a payroll run needs an exception queue rather than a rollback.
      assert result.posted == 2
      assert result.failed == 1
      assert D.equal?(PrepaidLedger.balance(good.prepaid_account_id), D.new("1500.00"))
    end

    test "a suspended employer cannot disburse at all" do
      {employer, _accounts} = fully_linked_employer()
      file = ingest(employer)

      {:ok, _} = Roster.set_employer_status(employer.employer_id, "SUSPENDED")

      assert {:error, :employer_not_disbursable} = Disbursement.post_batch(file.wps_file_id)

      credits = Ingestion.list_credits(file.wps_file_id)
      assert Enum.all?(credits, &(&1.status == "PARSED"))
    end
  end

  describe "a re-run does not pay twice" do
    test "re-running a completed batch posts nothing further" do
      {employer, accounts} = fully_linked_employer()
      file = ingest(employer)

      {:ok, first} = Disbursement.post_batch(file.wps_file_id)
      assert first.posted == 3

      {:ok, second} = Disbursement.post_batch(file.wps_file_id)

      # Nothing left pending: every line is already POSTED.
      assert second.posted == 0
      assert second.failed == 0

      assert D.equal?(PrepaidLedger.balance(accounts["E001"].prepaid_account_id), D.new("1500.00"))
    end

    test "the idempotency key holds even if the credit status is wrong" do
      {employer, accounts} = fully_linked_employer()
      file = ingest(employer)

      {:ok, _} = Disbursement.post_batch(file.wps_file_id)

      account_id = accounts["E001"].prepaid_account_id
      assert D.equal?(PrepaidLedger.balance(account_id), D.new("1500.00"))

      # Force the status back to PARSED, simulating a stale or corrupted record.
      # The status check is the cheap guard; the ledger key is the real one.
      credit = Repo.get_by!(SalaryCredit, payment_reference: "PAY-001")
      Repo.update!(SalaryCredit.changeset(credit, %{status: "PARSED"}))

      {:ok, result} = Disbursement.post_batch(file.wps_file_id)

      # Reported as posted — because it is — but the balance did not move again.
      assert result.posted == 1
      assert D.equal?(PrepaidLedger.balance(account_id), D.new("1500.00"))
    end
  end

  describe "the exception queue" do
    test "a failed line gets a classified, actionable exception" do
      employer = employer_fixture()
      link(employer, "E001", prepaid_account(employer))
      InstitutionResolver.reset()

      file = ingest(employer)
      {:ok, _} = Disbursement.post_batch(file.wps_file_id)

      exceptions = Disbursement.open_exceptions(employer.employer_id)
      assert length(exceptions) == 2

      assert Enum.all?(exceptions, &(&1.exception_type == "BENEFICIARY_UNRESOLVED"))
      assert Enum.all?(exceptions, &(&1.status == "OPEN"))
      assert Enum.all?(exceptions, &(&1.reason =~ "no roster link"))
    end

    test "the summary is grouped by cause with the money at stake" do
      employer = employer_fixture()
      link(employer, "E003", prepaid_account(employer, status: "CLOSED"))
      InstitutionResolver.reset()

      file = ingest(employer)
      {:ok, _} = Disbursement.post_batch(file.wps_file_id)

      summary = Disbursement.exception_summary(employer.employer_id)

      assert summary["BENEFICIARY_UNRESOLVED"].count == 2
      assert D.equal?(summary["BENEFICIARY_UNRESOLVED"].total, D.new("3500.00"))
      assert summary["ACCOUNT_INACTIVE"].count == 1
      assert D.equal?(summary["ACCOUNT_INACTIVE"].total, D.new("2500.00"))
    end

    test "retrying after the operator fixes the roster pays the worker" do
      employer = employer_fixture()
      link(employer, "E001", prepaid_account(employer))
      InstitutionResolver.reset()

      file = ingest(employer)
      {:ok, _} = Disbursement.post_batch(file.wps_file_id)

      [exception | _] =
        Disbursement.open_exceptions(employer.employer_id,
          exception_type: "BENEFICIARY_UNRESOLVED"
        )

      credit = Repo.get!(SalaryCredit, exception.salary_credit_id)

      # The operator does the thing the queue is asking for.
      account = prepaid_account(employer)
      link(employer, credit.employee_id, account)
      InstitutionResolver.reset()

      assert {:ok, posted} = Disbursement.retry(exception.exception_id)
      assert posted.status == "POSTED"

      assert D.equal?(PrepaidLedger.balance(account.prepaid_account_id), credit.net_amount)

      # And the queue no longer shows it.
      reloaded = Repo.get!(SalaryCreditException, exception.exception_id)
      assert reloaded.status == "RESOLVED"
    end

    test "a retry that fails again increments rather than stacking a second row" do
      employer = employer_fixture()
      InstitutionResolver.reset()

      file = ingest(employer)
      {:ok, _} = Disbursement.post_batch(file.wps_file_id)

      [exception | _] = Disbursement.open_exceptions(employer.employer_id)
      assert exception.attempt_count == 1

      # Retried without fixing anything.
      assert {:error, :not_linked} = Disbursement.retry(exception.exception_id)

      reloaded = Repo.get!(SalaryCreditException, exception.exception_id)
      assert reloaded.attempt_count == 2
      # An operator's queue shows outstanding work, not a history of attempts.
      assert length(Disbursement.open_exceptions(employer.employer_id)) == 3
    end

    test "abandoning closes the exception without paying" do
      employer = employer_fixture()
      InstitutionResolver.reset()

      file = ingest(employer)
      {:ok, _} = Disbursement.post_batch(file.wps_file_id)

      [exception | _] = Disbursement.open_exceptions(employer.employer_id)

      assert {:ok, abandoned} =
               Disbursement.abandon(exception.exception_id, "worker left before payday", "ops1")

      assert abandoned.status == "ABANDONED"
      assert abandoned.resolved_by == "ops1"
      assert length(Disbursement.open_exceptions(employer.employer_id)) == 2
    end

    test "an already-closed exception cannot be retried or abandoned again" do
      employer = employer_fixture()
      InstitutionResolver.reset()

      file = ingest(employer)
      {:ok, _} = Disbursement.post_batch(file.wps_file_id)

      [exception | _] = Disbursement.open_exceptions(employer.employer_id)
      {:ok, _} = Disbursement.abandon(exception.exception_id, "done", "ops1")

      assert {:error, {:not_open, "ABANDONED"}} = Disbursement.retry(exception.exception_id)
      assert {:error, {:not_open, "ABANDONED"}} =
               Disbursement.abandon(exception.exception_id, "again", "ops1")
    end
  end

  describe "refusals" do
    test "an unknown file" do
      assert {:error, :file_not_found} = Disbursement.pre_flight(Ecto.UUID.generate())
    end
  end
end
