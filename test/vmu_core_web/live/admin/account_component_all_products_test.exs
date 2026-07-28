defmodule VmuCoreWeb.Live.Admin.AccountComponentAllProductsTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Koṣa domain-model alignment
  (2026-07-28) — the "Accounts (CMS)" page was Credit-only, so
  Debit/Prepaid/Corporate cards had no visible list anywhere in the
  admin UI. Covers the new "All Products (Arrangements)" tab, driven by
  `CMS.Arrangements.search/1`, that rolls all four up into one list with
  links out to each product's own admin page.
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
      username: "all_products_test_#{String.downcase(role)}_#{System.unique_integer([:positive])}",
      display_name: "All Products Test #{role}", pw_hash: "x", pw_salt: "x", role: role, status: "ACTIVE"
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

  test "the All Products tab lists Debit and Prepaid accounts with links out to their own admin pages" do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "AllProdUi", last_name: "Test#{n}"})
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
    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/account")

    html = view |> element("button[phx-click=acc_scope][phx-value-scope=all]") |> render_click()

    assert html =~ "All Products (Arrangements)"
    assert html =~ "AllProdUi"
    assert html =~ "DEBIT"
    assert html =~ "PREPAID"
    assert html =~ "View in Debit Cards"
    assert html =~ "View in Prepaid Cards"
  end

  test "the product_type filter narrows the All Products list" do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "AllProdFilter", last_name: "Test#{n}"})
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
    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/account")

    view |> element("button[phx-click=acc_scope][phx-value-scope=all]") |> render_click()
    view |> element("input[phx-keyup=acc_search]") |> render_keyup(%{"q" => "AllProdFilter"})
    html = view |> element("select[phx-change=all_product_filter]") |> render_change(%{"product_type" => "PREPAID"})

    assert html =~ "PREPAID"
    refute html =~ "View in Debit Cards"
  end
end
