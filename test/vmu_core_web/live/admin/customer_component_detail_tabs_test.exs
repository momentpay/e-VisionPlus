defmodule VmuCoreWeb.Live.Admin.CustomerComponentDetailTabsTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. 2026-07-28 tab redesign — the
  Customer detail page's stacked info cards (Personal/Contact/Address/
  Identity/Corporate/Arrangements) moved behind detail-tabs, mirroring
  AccountComponent's existing Overview/Balances/Cards/etc. pattern, so
  operators don't have to scroll through every section to find one.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias VmuCore.Repo
  alias VmuCore.ASM.{Authz, Operator}
  alias VmuCore.Shared.{BankParameter, Customer, SysParameter}

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
      username: "detail_tabs_test_#{String.downcase(role)}_#{System.unique_integer([:positive])}",
      display_name: "Detail Tabs Test #{role}", pw_hash: "x", pw_salt: "x", role: role, status: "ACTIVE"
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

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()

    {sys_id, bank_id}
  end

  test "a RETAIL customer's detail page defaults to Overview and has no Corporate tab" do
    {sys_id, bank_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{
        sys_id: sys_id, bank_id: bank_id, first_name: "TabRetail", last_name: "CustTest#{n}",
        email: "tab-retail-#{n}@example.com", customer_tier: "RETAIL"
      })
      |> Repo.insert!()

    operator = operator_fixture("SUPERVISOR")
    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/customer")

    html = view |> element("button[phx-click=cust_view][phx-value-id='#{customer.customer_id}']") |> render_click()

    # Overview tab content (Personal + Contact) shown by default, no page reload needed
    assert html =~ "Personal Information"
    assert html =~ "Contact Details"
    assert html =~ "tab-retail-#{n}@example.com"
    refute html =~ "Corporate Details"
    refute html =~ ">Corporate<"
  end

  test "a CORPORATE customer's detail page shows a Corporate tab with the company details" do
    {sys_id, bank_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{
        sys_id: sys_id, bank_id: bank_id, first_name: "TabCorp", last_name: "CustTest#{n}",
        customer_tier: "CORPORATE", company_name: "Tab Corp Holdings #{n}",
        registration_number: "REG-TABCORP-#{n}"
      })
      |> Repo.insert!()

    operator = operator_fixture("SUPERVISOR")
    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/customer")

    view |> element("button[phx-click=cust_view][phx-value-id='#{customer.customer_id}']") |> render_click()
    html = view |> element("div[phx-click=detail_tab][phx-value-t='3']") |> render_click()

    assert html =~ "Corporate Details"
    assert html =~ "Tab Corp Holdings #{n}"
  end

  test "the Identity & KYC tab shows identity documents when clicked" do
    {sys_id, bank_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{
        sys_id: sys_id, bank_id: bank_id, first_name: "TabIdentity", last_name: "CustTest#{n}",
        id_type: "PASSPORT"
      })
      |> Repo.insert!()

    operator = operator_fixture("SUPERVISOR")
    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/customer")

    view |> element("button[phx-click=cust_view][phx-value-id='#{customer.customer_id}']") |> render_click()
    html = view |> element("div[phx-click=detail_tab][phx-value-t='2']") |> render_click()

    assert html =~ "Identity Documents"
    assert html =~ "PASSPORT"
  end
end
