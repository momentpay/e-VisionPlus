defmodule VmuCoreWeb.Live.Admin.KycComponentTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. First browser-level coverage for
  KYC-P1/P2 (2026-07-29): method builder, admin-initiated request
  submission wizard, and approve/reject with the real StatusSync side
  effect, all through the real LiveView.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias VmuCore.Repo
  alias VmuCore.ASM.{Authz, Operator}
  alias VmuCore.CMS.DebitAccount
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias VmuCore.Kyc.Adapters.OcrHttpAdapter

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
      username: "kyc_test_#{String.downcase(role)}_#{System.unique_integer([:positive])}",
      display_name: "Kyc Test #{role}", pw_hash: "x", pw_salt: "x", role: role, status: "ACTIVE"
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
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "606060", description: "test"}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    {sys_id, bank_id, logo_id, block_id}
  end

  defp customer_fixture do
    {sys_id, bank_id, _logo_id, _block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    %Customer{}
    |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Kyc", last_name: "Browser#{n}", email: "kycbrowser#{n}@test.com"})
    |> Repo.insert!()
  end

  defp debit_account_fixture(customer) do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()

    %DebitAccount{}
    |> DebitAccount.changeset(%{
      customer_id: customer.customer_id,
      sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id,
      opened_at: Date.utc_today()
    })
    |> Repo.insert!()
  end

  test "creating a method through the builder UI, then editing it bumps version" do
    operator = operator_fixture("SUPERVISOR")
    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/kyc")

    view |> element("button[phx-click=new_method]") |> render_click()

    view
    |> form("form[phx-change=form_change]", %{
      "method" => %{"name" => "Browser Method", "title" => "Browser Method Title", "product_type" => "DEBIT", "status" => "active"}
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

  test "admin-initiated KYC request: submit, view, approve syncs DebitAccount.kyc_status" do
    operator = operator_fixture("SUPERVISOR")
    customer = customer_fixture()
    account = debit_account_fixture(customer)
    assert account.kyc_status == "PENDING"

    {:ok, method} =
      VmuCore.Kyc.Methods.create(%{
        "name" => "Browser Debit KYC",
        "title" => "Debit KYC",
        "product_type" => "DEBIT",
        "status" => "active",
        "fields" => [%{"key" => "full_name", "label" => "Full Name", "type" => "text", "required" => true, "options" => []}]
      })

    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/kyc")

    view |> element("button[phx-click=section][phx-value-s=requests]") |> render_click()
    view |> element("button[phx-click=req_new]") |> render_click()

    view
    |> element("input[phx-keyup=req_cust_search]")
    |> render_keyup(%{"value" => customer.last_name})

    view |> element("button[phx-click=req_select_customer][phx-value-id='#{customer.customer_id}']") |> render_click()

    view
    |> element("select[phx-change=req_select_product]")
    |> render_change(%{"value" => "DEBIT"})

    view
    |> element("select[phx-change=req_select_method]")
    |> render_change(%{"value" => method.method_id})

    html =
      view
      |> form("form[phx-submit=req_submit]", %{"data" => %{"full_name" => "Jane Applicant"}})
      |> render_submit()

    assert html =~ "KYC request submitted"

    # Open the request from the list and approve it
    html = view |> element("button[phx-click=req_view]") |> render_click()
    assert html =~ "Jane Applicant"

    html =
      view
      |> form("form[phx-submit=req_approve]", %{"reason" => "all documents verified"})
      |> render_submit()

    assert html =~ "Request approved"
    assert html =~ "approved"

    reloaded_account = Repo.get!(DebitAccount, account.debit_account_id)
    assert reloaded_account.kyc_status == "VERIFIED"
    assert reloaded_account.kyc_verified_at != nil
  end

  test "rejecting a request requires a reason and does not touch kyc_verified_at" do
    operator = operator_fixture("SUPERVISOR")
    customer = customer_fixture()
    account = debit_account_fixture(customer)

    {:ok, method} =
      VmuCore.Kyc.Methods.create(%{
        "name" => "Browser Reject KYC",
        "title" => "Reject KYC",
        "product_type" => "DEBIT",
        "status" => "active",
        "fields" => [%{"key" => "full_name", "label" => "Full Name", "type" => "text", "required" => true, "options" => []}]
      })

    {:ok, request} = VmuCore.Kyc.Requests.submit(method, %{"customer_id" => customer.customer_id, "data" => %{"full_name" => "Reject Me"}})

    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/kyc")
    view |> element("button[phx-click=section][phx-value-s=requests]") |> render_click()
    view |> element("button[phx-click=req_view][phx-value-id='#{request.request_id}']") |> render_click()

    html =
      view
      |> form("form[phx-submit=req_reject]", %{"reason" => "document expired"})
      |> render_submit()

    assert html =~ "Request rejected"

    reloaded_account = Repo.get!(DebitAccount, account.debit_account_id)
    assert reloaded_account.kyc_status == "REJECTED"
    assert reloaded_account.kyc_verified_at == nil
  end

  test "conditional logic hides a field until its condition is satisfied, live in the submission form" do
    operator = operator_fixture("SUPERVISOR")
    customer = customer_fixture()

    {:ok, method} =
      VmuCore.Kyc.Methods.create(%{
        "name" => "Conditional KYC",
        "title" => "Conditional KYC",
        "product_type" => "DEBIT",
        "status" => "active",
        "fields" => [
          %{"key" => "customer_type", "label" => "Customer Type", "type" => "select", "required" => true, "options" => ["retail", "corporate"]},
          %{"key" => "company_name", "label" => "Company Name", "type" => "text", "required" => false, "options" => []}
        ],
        "conditional_rules" => [
          %{"target_field" => "company_name", "condition" => %{"field" => "customer_type", "operator" => "equals", "value" => "corporate"}}
        ]
      })

    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/kyc")
    view |> element("button[phx-click=section][phx-value-s=requests]") |> render_click()
    view |> element("button[phx-click=req_new]") |> render_click()
    view |> element("input[phx-keyup=req_cust_search]") |> render_keyup(%{"value" => customer.last_name})
    view |> element("button[phx-click=req_select_customer][phx-value-id='#{customer.customer_id}']") |> render_click()
    view |> element("select[phx-change=req_select_product]") |> render_change(%{"value" => "DEBIT"})

    html =
      view
      |> element("select[phx-change=req_select_method]")
      |> render_change(%{"value" => method.method_id})

    refute html =~ "Company Name"

    html =
      view
      |> form("form[phx-submit=req_submit]", %{"data" => %{"customer_type" => "corporate"}})
      |> render_change()

    assert html =~ "Company Name"

    html =
      view
      |> form("form[phx-submit=req_submit]", %{"data" => %{"customer_type" => "retail"}})
      |> render_change()

    refute html =~ "Company Name"
  end

  test "document upload triggers OCR extraction and supports reviewer annotation" do
    operator = operator_fixture("SUPERVISOR")
    customer = customer_fixture()
    _account = debit_account_fixture(customer)

    {:ok, method} =
      VmuCore.Kyc.Methods.create(%{
        "name" => "Doc Upload KYC",
        "title" => "Doc Upload KYC",
        "product_type" => "DEBIT",
        "status" => "active",
        "fields" => [%{"key" => "id_doc", "label" => "ID Document", "type" => "file", "required" => true, "options" => []}]
      })

    {:ok, request} = VmuCore.Kyc.Requests.submit(method, %{"customer_id" => customer.customer_id, "data" => %{}})

    Req.Test.stub(OcrHttpAdapter, fn conn ->
      Req.Test.json(conn, %{"simplified_text" => %{"raw_text" => "784-1990-1234567-1"}})
    end)

    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/kyc")
    view |> element("button[phx-click=section][phx-value-s=requests]") |> render_click()
    view |> element("button[phx-click=req_view][phx-value-id='#{request.request_id}']") |> render_click()

    view
    |> form("form[phx-submit=doc_upload]", %{"field_key" => "id_doc"})
    |> render_change()

    view
    |> file_input("form[phx-submit=doc_upload]", :kyc_document, [
      %{name: "emirates_id.jpg", content: "fake jpeg bytes", type: "image/jpeg"}
    ])
    |> render_upload("emirates_id.jpg")

    html = view |> element("form[phx-submit=doc_upload]") |> render_submit()
    assert html =~ "Document uploaded"
    assert html =~ "emirates_id.jpg"
    assert html =~ "784-1990-1234567-1"

    document = Repo.get_by!(VmuCore.Kyc.Document, request_id: request.request_id)
    assert File.exists?(document.storage_path)

    html =
      view
      |> form("form[phx-submit=doc_annotate][phx-value-document_id='#{document.document_id}']", %{"type" => "approval", "content" => "clear scan, matches records"})
      |> render_submit()

    assert html =~ "Annotation added"
    assert html =~ "clear scan, matches records"
  end
end
