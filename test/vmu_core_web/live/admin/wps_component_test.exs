defmodule VmuCoreWeb.Live.Admin.WpsComponentTest do
  @moduledoc """
  The WPS admin screens (Phase W5).

  Real LiveView mounts against a real Postgres sandbox. The assertions worth
  having here are not "does the page load" but the two the screens exist to
  enforce: that pre-flight shows an operator what *would* happen before
  anything moves, and that the maker-checker control on refunds survives the
  round trip through the UI.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias VmuCore.Repo
  alias VmuCore.ASM.{Authz, Operator}
  alias VmuCore.CMS.PrepaidAccount
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

  alias VmuCore.WPS.{Disbursement, Ingestion, Refunds, Roster, SalaryCredit}
  alias VmuCoreWeb.Admin.Nav
  alias Decimal, as: D

  @endpoint VmuCoreWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    Authz.seed_default_matrix()
    Authz.refresh()

    :ok = GLFixtures.seed_posting_engine!()
    InstitutionResolver.reset()
    on_exit(&InstitutionResolver.reset/0)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp operator_fixture(role, sys_id \\ nil, bank_id \\ nil) do
    n = System.unique_integer([:positive])

    attrs = %{
      username: "wps_#{String.downcase(role)}_#{n}",
      display_name: "WPS #{role} #{n}",
      pw_hash: "x",
      pw_salt: "x",
      role: role,
      status: "ACTIVE"
    }

    attrs = if sys_id, do: Map.merge(attrs, %{sys_id: sys_id, bank_id: bank_id}), else: attrs

    %Operator{} |> Operator.changeset(attrs) |> Repo.insert!()
  end

  defp authed_conn(operator) do
    build_conn()
    |> init_test_session(%{
      "operator_id" => operator.operator_id,
      "logged_in_at" => System.os_time(:second)
    })
  end

  defp institution do
    n = System.unique_integer([:positive])
    sys_id = "U#{100 + rem(n, 900)}"
    bank_id = "V#{100 + rem(n, 900)}"
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
        "wps", "employer_config",
        Map.put(existing || %{}, code, %{}),
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
        id_type: "PASSPORT", id_number: "WPS-UI-#{n}"
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

  defp admin_for(employer), do: operator_fixture("ADMIN", employer.sys_id, employer.bank_id)

  # Opens a screen already scoped to an employer via `?view=`, the same
  # deep-link convention the other product screens use.
  #
  # Employer selection in the UI is an `<.ag_grid>` action, and the grid's rows
  # are built by the JS hook rather than server-rendered — so there is no
  # element for LiveViewTest to click. The pilot test for the grid contract
  # takes the same approach: assert the wiring in `data-columns`, drive the
  # server through something that exists server-side.
  defp open(operator, screen, employer) do
    live(authed_conn(operator), "/visionplus/admin/#{screen}?view=#{employer.employer_id}")
  end

  # Forms and buttons are server-rendered and carry `phx-target`, so
  # `form/3` and `element/2` reach the component correctly.
  #
  # Grid *actions* are drawn by the JS hook rather than the server, so there is
  # no element for LiveViewTest to click — those are asserted as wiring in
  # `data-columns`, exactly as the AG Grid pilot test does, and their behaviour
  # is covered against the contexts in the W3/W4 suites.
  defp submit_form(view, selector, params) do
    view |> form(selector, params) |> render_submit()
  end

  defp click(view, selector) do
    view |> element(selector) |> render_click()
  end

  # Action forms render only once their panel is open, which is how the screen
  # actually behaves — so a test has to open it the same way an operator does.
  defp open_action(view, action) do
    click(view, ~s(button[phx-click="action"][phx-value-a="#{action}"]))
  end

  # ---------------------------------------------------------------------------

  describe "navigation" do
    test "all five WPS screens are live and reachable" do
      for id <- ~w[wps_employers wps_files wps_exceptions wps_refunds wps_reports] do
        assert Nav.live?(id), "#{id} is not a live nav item"
      end
    end

    test "regulator submission is present but honestly marked planned" do
      item = Enum.find(Nav.items(), &(&1.id == "wps_submissions"))

      # Filing is a business arrangement, not built. Showing it greyed out is
      # better than hiding it: the nav doubles as the roadmap.
      assert item.status == :planned
    end
  end

  describe "employers screen" do
    test "lists employers in a grid" do
      employer = employer_fixture()
      operator = admin_for(employer)

      {:ok, _view, html} = live(authed_conn(operator), "/visionplus/admin/wps_employers")

      assert html =~ ~s(id="wps-employers-grid")
      assert html =~ employer.employer_name
    end

    test "opening an employer shows its roster" do
      employer = employer_fixture()
      account = prepaid_account(employer)

      {:ok, _} =
        Roster.link(%{
          employer_id: employer.employer_id, employee_id: "E001",
          prepaid_account_id: account.prepaid_account_id
        })

      operator = admin_for(employer)

      # Selecting an employer is a grid action drawn by the JS hook, so the
      # deep link is what a test (and a shared URL) uses to land on one.
      {:ok, view, html} = open(operator, "wps_employers", employer)

      assert html =~ ~s(id="wps-roster-grid")
      assert html =~ "E001"

      # The suspend action is wired to ACTIVE rows only — a suspended link has
      # nothing to suspend.
      assert has_element?(
               view,
               ~s(#wps-roster-grid[data-columns*='"whenValue":"ACTIVE"'])
             )
    end
  end

  describe "salary files screen" do
    test "ingesting a file reports what parsed and what was rejected" do
      employer = employer_fixture()
      operator = admin_for(employer)

      {:ok, view, _} = open(operator, "wps_files", employer)

      open_action(view, "ingest")

      html =
        submit_form(view, "#wps-ingest-form", %{
          "file" => %{"filename" => "july.csv", "content" => @csv}
        })

      assert html =~ "2 lines parsed, 0 rejected"
      assert html =~ ~s(id="wps-credits-grid")
    end

    test "an unconfigured employer is refused with the reason, not a stack trace" do
      {sys_id, bank_id} = institution()

      {:ok, employer} =
        Roster.onboard_employer(%{
          sys_id: sys_id, bank_id: bank_id,
          employer_code: "NOLAYOUT", employer_name: "No Layout Co"
        })

      operator = operator_fixture("ADMIN", sys_id, bank_id)

      {:ok, view, _} = open(operator, "wps_files", employer)

      open_action(view, "ingest")

      html =
        submit_form(view, "#wps-ingest-form", %{
          "file" => %{"filename" => "x.csv", "content" => @csv}
        })

      # The operator is told what to do, and told the layout is not guessed.
      assert html =~ "No file layout configured"
      assert html =~ "not guessed"
    end

    test "pre-flight shows the blockers before anything is paid" do
      employer = employer_fixture()
      # Only E001 is linked; E002 will block.
      account = prepaid_account(employer)

      {:ok, _} =
        Roster.link(%{
          employer_id: employer.employer_id, employee_id: "E001",
          prepaid_account_id: account.prepaid_account_id
        })

      InstitutionResolver.reset()
      {:ok, file, _} = Ingestion.ingest(employer.employer_id, "july.csv", @csv)

      operator = admin_for(employer)
      {:ok, view, _} = open(operator, "wps_files", employer)

      html = click(view, "#wps-preflight-btn")

      assert html =~ "nothing has moved yet"
      assert html =~ "BENEFICIARY_UNRESOLVED"
      assert html =~ "E002"

      # And nothing did move.
      assert Repo.get_by!(SalaryCredit, payment_reference: "PAY-001").status == "PARSED"
    end

    test "posting the batch pays the payable lines" do
      employer = employer_fixture()

      for id <- ["E001", "E002"] do
        account = prepaid_account(employer)

        {:ok, _} =
          Roster.link(%{
            employer_id: employer.employer_id, employee_id: id,
            prepaid_account_id: account.prepaid_account_id
          })
      end

      InstitutionResolver.reset()
      {:ok, file, _} = Ingestion.ingest(employer.employer_id, "july.csv", @csv)

      operator = admin_for(employer)
      {:ok, view, _} = open(operator, "wps_files", employer)

      # Posting is only reachable from the pre-flight panel, which is the point:
      # you see what would happen before it happens.
      click(view, "#wps-preflight-btn")
      html = click(view, ~s(button[phx-click="post_batch"]))

      assert html =~ "Posted 2 payments"
      assert Repo.get_by!(SalaryCredit, payment_reference: "PAY-001").status == "POSTED"
    end
  end

  describe "exceptions screen" do
    setup do
      employer = employer_fixture()
      InstitutionResolver.reset()
      {:ok, file, _} = Ingestion.ingest(employer.employer_id, "july.csv", @csv)
      {:ok, _} = Disbursement.post_batch(file.wps_file_id)

      %{employer: employer, wps_file: file}
    end

    test "the queue groups by cause and names the workers", %{employer: employer} do
      operator = admin_for(employer)

      {:ok, view, html} = open(operator, "wps_exceptions", employer)

      assert html =~ ~s(id="wps-exceptions-grid")
      assert html =~ "BENEFICIARY_UNRESOLVED"
      assert html =~ "E001"
    end

    test "retrying after linking the worker pays them", %{employer: employer} do
      [exception | _] = Disbursement.open_exceptions(employer.employer_id)
      credit = Repo.get!(SalaryCredit, exception.salary_credit_id)

      account = prepaid_account(employer)

      {:ok, _} =
        Roster.link(%{
          employer_id: employer.employer_id, employee_id: credit.employee_id,
          prepaid_account_id: account.prepaid_account_id
        })

      InstitutionResolver.reset()

      operator = admin_for(employer)
      {:ok, view, _} = open(operator, "wps_exceptions", employer)

      # Retry is a grid action, drawn by the JS hook — so the screen's job is to
      # wire it, and the wiring is what is asserted here. That it actually pays
      # the worker is proved against the context in the W3 suite.
      {:ok, retry_view, _} = open(operator, "wps_exceptions", employer)

      assert has_element?(
               retry_view,
               ~s(#wps-exceptions-grid[data-columns*='"event":"retry_exception"'])
             )

      assert {:ok, posted} = Disbursement.retry(exception.exception_id)
      assert posted.status == "POSTED"
      assert Repo.get!(SalaryCredit, credit.salary_credit_id).status == "POSTED"
    end

    test "a retry that still fails says so without losing the exception", %{employer: employer} do
      [exception | _] = Disbursement.open_exceptions(employer.employer_id)

      operator = admin_for(employer)
      {:ok, view, _} = open(operator, "wps_exceptions", employer)

      assert has_element?(
               view,
               ~s(#wps-exceptions-grid[data-columns*='"event":"abandon_exception"'])
             )

      # Retrying without fixing anything leaves the exception open and counts
      # the attempt, rather than losing it.
      assert {:error, :not_linked} = Disbursement.retry(exception.exception_id)
      assert length(Disbursement.open_exceptions(employer.employer_id)) == 2
    end
  end

  describe "refunds screen — the maker-checker control" do
    setup do
      employer = employer_fixture()

      for id <- ["E001", "E002"] do
        account = prepaid_account(employer)

        {:ok, _} =
          Roster.link(%{
            employer_id: employer.employer_id, employee_id: id,
            prepaid_account_id: account.prepaid_account_id
          })
      end

      InstitutionResolver.reset()
      {:ok, file, _} = Ingestion.ingest(employer.employer_id, "july.csv", @csv)
      {:ok, _} = Disbursement.post_batch(file.wps_file_id)

      %{employer: employer, credit: Repo.get_by!(SalaryCredit, payment_reference: "PAY-001")}
    end

    test "the operator who requested cannot approve, through the UI too", %{
      employer: employer,
      credit: credit
    } do
      operator = admin_for(employer)

      {:ok, view, _} = open(operator, "wps_refunds", employer)

      open_action(view, "refund")

      submit_form(view, "#wps-refund-form", %{
        "refund" => %{
          "salary_credit_id" => credit.salary_credit_id,
          "amount" => "",
          "reason" => "employer overpaid this cycle"
        }
      })

      [request] = Refunds.pending(employer.employer_id)

      html = click(view, "#wps-approve-#{request.refund_request_id}")

      # The screen explains the refusal as a control rather than an error.
      assert html =~ "you cannot approve it"
      assert html =~ "That is the control"
      assert Refunds.get(request.refund_request_id).status == "PENDING"
    end

    test "a different operator can approve, and the money comes back", %{
      employer: employer,
      credit: credit
    } do
      maker = operator_fixture("OPS", employer.sys_id, employer.bank_id)
      checker = operator_fixture("SUPERVISOR", employer.sys_id, employer.bank_id)

      {:ok, _request} =
        Refunds.request(credit.salary_credit_id,
          reason: "employer overpaid this cycle",
          requested_by: maker.username
        )

      {:ok, view, _} = open(checker, "wps_refunds", employer)

      [request] = Refunds.pending(employer.employer_id)
      html = click(view, "#wps-approve-#{request.refund_request_id}")

      assert html =~ "recovered"
      assert Refunds.get(request.refund_request_id).status == "APPROVED"
    end
  end

  describe "reports screen" do
    test "reports paid and unpaid workers alike" do
      employer = employer_fixture()
      account = prepaid_account(employer)

      {:ok, _} =
        Roster.link(%{
          employer_id: employer.employer_id, employee_id: "E001",
          prepaid_account_id: account.prepaid_account_id
        })

      InstitutionResolver.reset()
      {:ok, file, _} = Ingestion.ingest(employer.employer_id, "july.csv", @csv)
      {:ok, _} = Disbursement.post_batch(file.wps_file_id)

      operator = admin_for(employer)
      {:ok, view, _} = open(operator, "wps_reports", employer)

      html =
        submit_form(view, "#wps-report-form", %{
          "report" => %{"from" => "2026-07-01", "to" => "2026-07-31"}
        })

      assert html =~ ~s(id="wps-report-grid")
      assert html =~ "1</strong> paid"
      assert html =~ "1</strong> not paid"
      # The unpaid worker's reason travels with the row — the scheme exists to
      # make non-payment visible.
      assert html =~ "BENEFICIARY_UNRESOLVED"
    end
  end

  describe "permissions" do
    test "a COMPLIANCE operator can read but cannot post a batch" do
      employer = employer_fixture()

      for id <- ["E001", "E002"] do
        account = prepaid_account(employer)

        {:ok, _} =
          Roster.link(%{
            employer_id: employer.employer_id, employee_id: id,
            prepaid_account_id: account.prepaid_account_id
          })
      end

      InstitutionResolver.reset()
      {:ok, file, _} = Ingestion.ingest(employer.employer_id, "july.csv", @csv)

      operator = operator_fixture("COMPLIANCE", employer.sys_id, employer.bank_id)

      {:ok, view, _} = open(operator, "wps_files", employer)

      # Posting is only reachable from the pre-flight panel, which is the point:
      # you see what would happen before it happens.
      # COMPLIANCE holds wps_files:view but not :edit, so the post control is
      # never offered. `guard/4` refuses it server-side as well, which is what
      # makes hiding the button presentation rather than protection.
      click(view, "#wps-preflight-btn")

      refute has_element?(view, ~s(button[phx-click="post_batch"]))
      assert Repo.get_by!(SalaryCredit, payment_reference: "PAY-001").status == "PARSED"
    end
  end
end
