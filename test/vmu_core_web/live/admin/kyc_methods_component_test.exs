defmodule VmuCoreWeb.Live.Admin.KycMethodsComponentTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. KYC-P3.5 (2026-07-29) — split out
  of the combined KycComponent per the user's role-separation feedback:
  method template design is its own screen/permission (`kyc_methods`),
  separate from request review (`kyc_requests`, see
  kyc_requests_component_test.exs).
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias VmuCore.Repo
  alias VmuCore.ASM.{Authz, Operator}

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
      username: "kyc_methods_test_#{String.downcase(role)}_#{System.unique_integer([:positive])}",
      display_name: "Kyc Methods Test #{role}", pw_hash: "x", pw_salt: "x", role: role, status: "ACTIVE"
    })
    |> Repo.insert!()
  end

  defp authed_conn(operator) do
    build_conn()
    |> init_test_session(%{"operator_id" => operator.operator_id, "logged_in_at" => System.os_time(:second)})
  end

  test "creating a method through the builder UI, then editing it bumps version" do
    operator = operator_fixture("SUPERVISOR")
    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/kyc_methods")

    view |> element("button[phx-click=new_method]") |> render_click()

    view
    |> form("form[phx-change=form_change]", %{
      "method" => %{"name" => "Browser Method", "title" => "Browser Method Title", "product_type" => "DEBIT", "status" => "active", "step" => "1", "required" => "true"}
    })
    |> render_change()

    view |> element("button[phx-click=add_field]") |> render_click()

    view
    |> element("input[phx-value-idx='0'][phx-value-prop=label]")
    |> render_blur(%{"value" => "Full Name"})

    html = view |> form("form[phx-submit=save_method]") |> render_submit()
    assert html =~ "Method saved successfully"
    assert html =~ "Browser Method"

    # Edit it: add a second field, version should bump to 2
    view |> element("button[phx-click=edit_method]", "Edit") |> render_click()
    view |> element("button[phx-click=add_field]") |> render_click()

    view
    |> element("input[phx-value-idx='1'][phx-value-prop=label]")
    |> render_blur(%{"value" => "ID Number"})

    html = view |> form("form[phx-submit=save_method]") |> render_submit()
    assert html =~ "v2"
  end

  test "the Conditional Logic tab is a real, separate tab from Form Fields" do
    operator = operator_fixture("SUPERVISOR")
    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/kyc_methods")

    view |> element("button[phx-click=new_method]") |> render_click()
    view |> element("button[phx-click=add_field]") |> render_click()

    view
    |> element("input[phx-value-idx='0'][phx-value-prop=label]")
    |> render_blur(%{"value" => "Customer Type"})

    html = render(view)
    assert html =~ "Customer Type"

    html = view |> element("button[phx-click=editor_tab][phx-value-t=logic]") |> render_click()
    refute html =~ "value=\"Customer Type\""
    assert html =~ "Show a field only when another field"

    html = view |> element("button[phx-click=editor_tab][phx-value-t=fields]") |> render_click()
    assert html =~ "Customer Type"
  end

  test "clone copies a method's fields into a new, independent method in another product" do
    operator = operator_fixture("SUPERVISOR")

    {:ok, method} =
      VmuCore.Kyc.Methods.create(%{
        "name" => "Source Method",
        "title" => "Source Method",
        "product_type" => "DEBIT",
        "status" => "active",
        "fields" => [%{"key" => "full_name", "label" => "Full Name", "type" => "text", "required" => true, "options" => []}]
      })

    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/kyc_methods")

    view |> element("button[phx-click=clone_open][phx-value-id='#{method.method_id}']") |> render_click()

    html =
      view
      |> form("form[phx-submit=clone_save]", %{"target_product_type" => "PREPAID"})
      |> render_submit()

    assert html =~ "Method cloned to PREPAID"

    cloned = Repo.get_by!(VmuCore.Kyc.Method, cloned_from_method_id: method.method_id)
    assert cloned.product_type == "PREPAID"
    assert cloned.status == "inactive"
  end

  test "COMPLIANCE role can view but not edit methods" do
    operator = operator_fixture("COMPLIANCE")
    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/kyc_methods")

    html = render(view)
    refute html =~ "+ New Method"
  end
end
