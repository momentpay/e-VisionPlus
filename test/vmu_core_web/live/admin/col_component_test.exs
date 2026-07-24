defmodule VmuCoreWeb.Live.Admin.ColComponentTest do
  @moduledoc """
  Live tests for the COL ops UI (ported from Avenza's `vmu_col` app back into
  standalone vmu_core — the P1-P9 build was verified once already on
  2026-07-10 but never committed to git; it was extracted into the Avenza
  umbrella by a later commit and never carried back after the platform-of-
  record reversal to standalone vmu_core. See
  `docs/col/COL_Gap_Implementation_Tracker.md`. No mocking: real Postgres via
  the Sandbox, real LiveComponent event handling.

  Same fixture pattern as `DpsComponentTest`/`PurchasePostingTest`.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias VmuCore.Repo
  alias VmuCore.ASM.{Authz, Operator}
  alias VmuCore.CMS.Account
  alias VmuCore.COL.CollectionCase
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter,
                        ModuleConfigWriter, SysParameter}
  alias Decimal, as: D

  @endpoint VmuCoreWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    Authz.seed_default_matrix()
    Authz.refresh()

    :ok
  end

  defp operator_fixture(role) do
    %Operator{}
    |> Operator.changeset(%{
      username: "col_test_#{String.downcase(role)}_#{System.unique_integer([:positive])}",
      display_name: "COL Test #{role}",
      pw_hash: "x", pw_salt: "x", role: role, status: "ACTIVE"
    })
    |> Repo.insert!()
  end

  defp authed_conn(operator) do
    build_conn()
    |> init_test_session(%{"operator_id" => operator.operator_id, "logged_in_at" => System.os_time(:second)})
  end

  defp parameter_hierarchy_fixture do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()

    %BankParameter{}
    |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"})
    |> Repo.insert!()

    %LogoParameter{}
    |> LogoParameter.changeset(%{
      sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "424242", description: "test"
    })
    |> Repo.insert!()

    %BlockParameter{}
    |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id})
    |> Repo.insert!()

    {sys_id, bank_id, logo_id, block_id}
  end

  defp account_fixture do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{
        sys_id: sys_id, bank_id: bank_id, first_name: "Col", last_name: "Test#{n}",
        id_type: "PASSPORT", id_number: "COL-TEST-#{n}"
      })
      |> Repo.insert!()

    %Account{}
    |> Account.changeset(%{
      customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
      block_id: block_id, pan_token: "col-test-pan-#{n}", last_four: "8888",
      expiry_date: "1230", credit_limit: D.new("10000.00")
    })
    |> Repo.insert!()
  end

  defp case_fixture(account, overrides \\ %{}) do
    %CollectionCase{}
    |> CollectionCase.changeset(Map.merge(%{
      account_id: account.account_id, dpd_bucket: 90,
      outstanding_amount: D.new("500.00"), status: "OPEN"
    }, overrides))
    |> Repo.insert!()
  end

  defp configure_agency(account, code, overrides \\ %{}) do
    config = %{
      code => Map.merge(%{
        "file_format" => "CSV", "commission_type" => "flat_percent", "commission_value" => "10"
      }, overrides)
    }

    ModuleConfigWriter.put(
      "col", "agency_config", config,
      %{scope_type: "bank", sys_id: account.sys_id, bank_id: account.bank_id}, nil
    )
  end

  describe "authentication gate" do
    test "unauthenticated request redirects to login" do
      assert {:error, {:redirect, %{to: "/visionplus/admin/login"}}} =
               live(build_conn(), "/visionplus/admin/col")
    end
  end

  describe "case list (SUPERVISOR — full access)" do
    test "renders a real seeded case" do
      account = account_fixture()
      case_row = case_fixture(account)
      operator = operator_fixture("SUPERVISOR")

      {:ok, view, html} = live(authed_conn(operator), "/visionplus/admin/col")

      assert html =~ "Collections &amp; Recovery" or html =~ "Collections & Recovery"
      assert has_element?(view, "td", "90")
      assert has_element?(view, "button", "View")

      view |> element("button[phx-value-id='#{case_row.case_id}']", "View") |> render_click()
      assert render(view) =~ "OPEN"
    end
  end

  describe "case detail (SUPERVISOR)" do
    test "logs a call, verified against the real col_contact_attempts row" do
      account = account_fixture()
      case_row = case_fixture(account)
      operator = operator_fixture("SUPERVISOR")

      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/col")
      view |> element("button[phx-value-id='#{case_row.case_id}']", "View") |> render_click()

      view
      |> form("form[phx-submit=log_call]", %{"outcome" => "promise_to_pay", "notes" => "Cardholder will pay Friday"})
      |> render_submit()

      history = VmuCore.COL.ContactHistory.list_for_account(account.account_id)
      assert [%{outcome: "promise_to_pay", notes: "Cardholder will pay Friday"}] = history
    end

    test "configures an agency, places the case with it, then recalls" do
      account = account_fixture()
      case_row = case_fixture(account)
      configure_agency(account, "AGENCY1")
      operator = operator_fixture("SUPERVISOR")

      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/col")
      view |> element("button[phx-value-id='#{case_row.case_id}']", "View") |> render_click()

      view
      |> form("form[phx-submit=place_with_agency]", %{"agency_code" => "AGENCY1"})
      |> render_submit()

      placement = Repo.get_by!(VmuCore.COL.AgencyPlacement, case_id: case_row.case_id)
      assert placement.status == "PLACED"
      assert placement.agency_code == "AGENCY1"
      assert Repo.get!(CollectionCase, case_row.case_id).status == "AGENCY"

      view |> element("button", "Recall") |> render_click()

      assert Repo.get!(VmuCore.COL.AgencyPlacement, placement.id).status == "RECALLED"
      assert Repo.get!(CollectionCase, case_row.case_id).status == "OPEN"
    end

    test "requests a workout plan (payment holiday), pending approval" do
      account = account_fixture()
      case_row = case_fixture(account)
      operator = operator_fixture("SUPERVISOR")

      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/col")
      view |> element("button[phx-value-id='#{case_row.case_id}']", "View") |> render_click()

      view
      |> form("form[phx-submit=request_workout]", %{
        "plan_type" => "PAYMENT_HOLIDAY", "holiday_months" => "2", "reason" => "hardship"
      })
      |> render_submit()

      [plan] = VmuCore.COL.WorkoutCommand.pending(10) |> Enum.filter(&(&1.account_id == account.account_id))
      assert plan.plan_type == "PAYMENT_HOLIDAY"
      assert plan.holiday_months == 2
      assert plan.status == "PENDING_APPROVAL"
    end

    test "requests a settlement offer, pending approval" do
      account = account_fixture()
      case_row = case_fixture(account, %{outstanding_amount: D.new("1000.00")})
      operator = operator_fixture("SUPERVISOR")

      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/col")
      view |> element("button[phx-value-id='#{case_row.case_id}']", "View") |> render_click()

      view
      |> form("form[phx-submit=request_settlement]", %{
        "offer_amount" => "800.00", "expiry_date" => Date.to_iso8601(Date.add(Date.utc_today(), 30))
      })
      |> render_submit()

      [offer] = VmuCore.COL.SettlementCommand.pending(10) |> Enum.filter(&(&1.account_id == account.account_id))
      assert D.equal?(offer.offer_amount, D.new("800.00"))
      assert offer.status == "PENDING_APPROVAL"
    end
  end

  describe "agency files panel (SUPERVISOR)" do
    test "generates a real CSV assignment file and imports a pasted activity line" do
      account = account_fixture()
      case_row = case_fixture(account)
      configure_agency(account, "AGENCY1")
      # import_activity_file only applies against an active placement — place
      # first, same precondition the real agency workflow always has.
      {:ok, _placement} = VmuCore.COL.AgencyDesk.place(case_row.case_id, "AGENCY1")
      operator = operator_fixture("SUPERVISOR")

      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/col")

      view |> element("button", "📁 Agency Files") |> render_click()

      bank_key = "#{account.sys_id}|#{account.bank_id}"
      view |> form("form[phx-change=select_file_bank]", %{"file_bank" => bank_key}) |> render_change()

      html =
        view
        |> form("form[phx-submit=generate_file]", %{"agency_code" => "AGENCY1"})
        |> render_submit()

      assert html =~ account.last_four

      csv_line = "account_id,activity_type,amount\n#{account.account_id},CONTACT,\n"

      import_html =
        view
        |> form("form[phx-submit=import_file]", %{"agency_code" => "AGENCY1", "content" => csv_line})
        |> render_submit()

      assert import_html =~ "Applied: 1"
    end
  end

  describe "access control (CS_AGENT — view-only)" do
    test "sees the case but no log-call/place/workout/settlement forms, and no rows get written" do
      account = account_fixture()
      case_row = case_fixture(account)
      operator = operator_fixture("CS_AGENT")

      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/col")
      view |> element("button[phx-value-id='#{case_row.case_id}']", "View") |> render_click()

      refute has_element?(view, "form[phx-submit=log_call]")
      refute has_element?(view, "form[phx-submit=place_with_agency]")
      refute has_element?(view, "form[phx-submit=request_workout]")
      refute has_element?(view, "form[phx-submit=request_settlement]")

      assert VmuCore.COL.ContactHistory.list_for_account(account.account_id) == []
      assert VmuCore.COL.WorkoutCommand.pending(10) == []
      assert VmuCore.COL.SettlementCommand.pending(10) == []
    end
  end
end
