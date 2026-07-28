defmodule VmuCoreWeb.Live.Admin.CustomerComponentArrangementsTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Koṣa domain-model alignment
  (2026-07-28) — first-ever test for `CustomerComponent`, covering the
  new "Arrangements (All Products)" panel: a customer's CIF detail page
  should show every product relationship they have, not just credit
  accounts (`Customer.list_accounts_for/1`'s old, credit-only scope).
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias VmuCore.Repo
  alias VmuCore.ASM.{Authz, Operator}
  alias VmuCore.CMS.{DebitAccountOpening, PrepaidAccountOpening}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}

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
      username: "cust_arr_test_#{String.downcase(role)}_#{System.unique_integer([:positive])}",
      display_name: "Cust Arr Test #{role}", pw_hash: "x", pw_salt: "x", role: role, status: "ACTIVE"
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

  test "a customer with both a debit and a prepaid account shows both arrangements on their CIF detail page" do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "MultiProduct", last_name: "CustTest#{n}"})
      |> Repo.insert!()

    {:ok, _debit} =
      DebitAccountOpening.open(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id
      })

    {:ok, _prepaid} =
      PrepaidAccountOpening.open(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id
      })

    operator = operator_fixture("SUPERVISOR")
    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/customer")

    view |> element("button[phx-click=cust_view][phx-value-id='#{customer.customer_id}']") |> render_click()
    # Arrangements now lives behind its own detail tab (2026-07-28 tab redesign).
    html = view |> element("div[phx-click=detail_tab][phx-value-t='4']") |> render_click()

    assert html =~ "Arrangements"
    assert html =~ "DEBIT"
    assert html =~ "PREPAID"
    assert html =~ "View in Debit Cards"
    assert html =~ "View in Prepaid Cards"
  end

  test "a customer with no products shows the empty state, not an error" do
    {sys_id, bank_id, _logo_id, _block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "NoProduct", last_name: "CustTest#{n}"})
      |> Repo.insert!()

    operator = operator_fixture("SUPERVISOR")
    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/customer")

    view |> element("button[phx-click=cust_view][phx-value-id='#{customer.customer_id}']") |> render_click()
    html = view |> element("div[phx-click=detail_tab][phx-value-t='4']") |> render_click()

    assert html =~ "No product relationships for this customer yet."
  end
end
