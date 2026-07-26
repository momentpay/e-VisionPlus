defmodule VmuCoreWeb.Live.Admin.HcsComponentTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Way4 parity plan Phase 1 item 2
  (2026-07-25) — first-ever admin UI test coverage for HCS, covering
  company creation, detail view, and the facility-limit-change request
  flow through to the Approval Inbox.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias VmuCore.Repo
  alias VmuCore.ASM.{Authz, Operator}
  alias VmuCore.HCS.{Company, CompanyOnboarding}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, ModuleConfigWriter, SysParameter}
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
      username: "hcs_test_#{String.downcase(role)}_#{System.unique_integer([:positive])}",
      display_name: "HCS Test #{role}", pw_hash: "x", pw_salt: "x", role: role, status: "ACTIVE"
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
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "424242", description: "test"}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    {sys_id, bank_id, logo_id, block_id}
  end

  defp company_fixture do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{
        sys_id: sys_id, bank_id: bank_id, first_name: "Corporate", last_name: "UiTest#{n}",
        customer_tier: "CORPORATE", company_name: "UI Test Co #{n}", registration_number: "REG-UI-#{n}"
      })
      |> Repo.insert!()

    {:ok, %{company: company}} =
      CompanyOnboarding.onboard_company(%{
        account_attrs: %{
          customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id,
          logo_id: logo_id, block_id: block_id, pan_token: "ui-test-facility-#{n}",
          last_four: "0000", expiry_date: "0000", credit_limit: D.new("50000.00")
        },
        company_attrs: %{
          company_code: "UI#{n}", company_name: "UI Test Co #{n}", registration_no: "REG-UI-#{n}",
          liability_model: "CENTRAL", credit_limit: D.new("50000.00")
        }
      })

    {company, sys_id, bank_id, logo_id, block_id}
  end

  test "creating a new company via the admin form" do
    operator = operator_fixture("SUPERVISOR")
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()

    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/hcs")

    view |> element("button[phx-click=open_action][phx-value-a=create_company]") |> render_click()

    html =
      view
      |> form("form[phx-submit=create_company_save]", %{
        "company" => %{
          "company_code" => "NEWCO", "company_name" => "New Co Ltd",
          "registration_no" => "REG-NEWCO-1",
          "credit_limit" => "75000.00", "sys_id" => sys_id, "bank_id" => bank_id,
          "logo_id" => logo_id, "block_id" => block_id
        }
      })
      |> render_submit()

    assert html =~ "Company NEWCO created."

    company = Repo.get_by!(Company, company_code: "NEWCO")
    assert D.equal?(company.credit_limit, D.new("75000.00"))
    assert D.equal?(company.available_limit, D.new("75000.00"))
  end

  test "viewing company detail shows the facility, employee cards, and spending controls" do
    {company, _sys_id, _bank_id, _logo_id, _block_id} = company_fixture()
    operator = operator_fixture("SUPERVISOR")

    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/hcs")

    html = view |> element("button[phx-click=view_company][phx-value-id='#{company.id}']") |> render_click()

    assert html =~ company.company_name
    assert html =~ "Employee Cards"
    assert html =~ "Spending Controls"
    assert html =~ "Pending Facility Limit Requests"
  end

  test "requesting a facility limit change, then approving it from the Approval Inbox as a different operator" do
    {company, sys_id, bank_id, _logo_id, _block_id} = company_fixture()
    maker = operator_fixture("SUPERVISOR")
    checker = operator_fixture("SUPERVISOR")

    ModuleConfigWriter.put("hcs", "facility_limit_approval_matrix", ["SUPERVISOR"],
      %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)

    {:ok, view, _html} = live(authed_conn(maker), "/visionplus/admin/hcs")
    view |> element("button[phx-click=view_company][phx-value-id='#{company.id}']") |> render_click()
    view |> element("button[phx-click=open_action][phx-value-a=request_limit]") |> render_click()

    request_html =
      view
      |> form("form[phx-submit=request_limit_save]", %{
        "action" => %{"requested_limit" => "80000.00", "reason" => "expansion"}
      })
      |> render_submit()

    assert request_html =~ "pending approval"
    assert request_html =~ "80000.00"

    {:ok, inbox_view, _html} = live(authed_conn(checker), "/visionplus/admin/approvals")
    inbox_html = render(inbox_view)
    assert inbox_html =~ "HCS Facility Limit Changes"

    approve_html =
      inbox_view
      |> element("button[phx-click=approve_facility_limit]")
      |> render_click()

    assert approve_html =~ "Facility limit change approved and applied."

    reloaded = Repo.get!(Company, company.id)
    assert D.equal?(reloaded.credit_limit, D.new("80000.00"))
  end

  describe "fleet cards (Way4 Phase 1 item 3)" do
    test "adding a vehicle, issuing a fleet card, and assigning a driver end-to-end" do
      {company, _sys_id, _bank_id, _logo_id, _block_id} = company_fixture()
      operator = operator_fixture("SUPERVISOR")

      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/hcs")
      view |> element("button[phx-click=view_company][phx-value-id='#{company.id}']") |> render_click()

      view |> element("button[phx-click=open_action][phx-value-a=add_vehicle]") |> render_click()

      detail_html =
        view
        |> form("form[phx-submit=add_vehicle_save]", %{
          "vehicle" => %{"plate_number" => "DXB-E2E-1", "vin" => "VINE2E001"}
        })
        |> render_submit()

      assert detail_html =~ "Vehicle DXB-E2E-1 added."
      assert detail_html =~ "DXB-E2E-1"

      view |> element("button[phx-click=view_vehicle]") |> render_click()

      view |> element("button[phx-click=open_action][phx-value-a=issue_fleet_card]") |> render_click()

      card_html =
        view
        |> form("form[phx-submit=issue_fleet_card_save]", %{
          "card" => %{"individual_limit" => "3000.00"}
        })
        |> render_submit()

      assert card_html =~ "Fleet card issued for DXB-E2E-1."
      assert card_html =~ "3000.00"

      view |> element("button[phx-click=open_action][phx-value-a=assign_driver]") |> render_click()

      driver_html =
        view
        |> form("form[phx-submit=assign_driver_save]", %{
          "driver" => %{"driver_name" => "Bilal Ahmed"}
        })
        |> render_submit()

      assert driver_html =~ "Driver assigned to DXB-E2E-1."
      assert driver_html =~ "Bilal Ahmed"

      unassign_html = view |> element("button[phx-click=unassign_driver]") |> render_click()
      assert unassign_html =~ "Driver unassigned."
    end

    test "generating a fleet spend report by vehicle" do
      {company, _sys_id, _bank_id, _logo_id, _block_id} = company_fixture()
      operator = operator_fixture("SUPERVISOR")

      {:ok, %{fleet_card: _card}} =
        (fn ->
          {:ok, vehicle} = VmuCore.HCS.FleetOnboarding.add_vehicle(company.id, %{plate_number: "DXB-RPT-E2E"})
          VmuCore.HCS.FleetOnboarding.add_fleet_card(company.id, vehicle.id, %{individual_limit: D.new("2000.00")})
        end).()

      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/hcs")
      view |> element("button[phx-click=view_company][phx-value-id='#{company.id}']") |> render_click()

      view |> element("button[phx-click=open_action][phx-value-a=fleet_report]") |> render_click()

      today = Date.utc_today() |> Date.to_iso8601()
      week_ago = Date.utc_today() |> Date.add(-7) |> Date.to_iso8601()

      html =
        view
        |> form("form[phx-submit=generate_report_save]", %{
          "report" => %{"period_from" => week_ago, "period_to" => today, "kind" => "vehicle"}
        })
        |> render_submit()

      assert html =~ "DXB-RPT-E2E"
      assert html =~ "grouped by vehicle"
    end
  end
end
