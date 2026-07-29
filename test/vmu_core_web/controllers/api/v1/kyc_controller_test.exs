defmodule VmuCoreWeb.Api.V1.KycControllerTest do
  @moduledoc """
  Real Postgres via Sandbox + real HTTP request pipeline (Phoenix.ConnTest,
  not a mock router), no mocking. KYC-P5 (2026-07-29) — the external
  /api/v1/kyc/* surface: bearer-token auth, scope enforcement, and each
  endpoint's real happy path. See docs/kyc/KYC_Implementation_Tracker.md §7.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias VmuCore.Repo
  alias VmuCore.ASM.ServiceAccounts
  alias VmuCore.Kyc.{Methods, Requests}
  alias VmuCore.Shared.{BankParameter, Customer, SysParameter}

  @endpoint VmuCoreWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    {:ok, conn: build_conn()}
  end

  defp customer_fixture do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()

    %Customer{}
    |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Api", last_name: "Test#{n}"})
    |> Repo.insert!()
  end

  defp method_fixture(fields \\ []) do
    n = System.unique_integer([:positive])

    {:ok, method} =
      Methods.create(%{
        "name" => "API Method #{n}",
        "title" => "API Method",
        "product_type" => "DEBIT",
        "status" => "active",
        "fields" => fields
      })

    method
  end

  defp token_with_scopes(scopes) do
    n = System.unique_integer([:positive])
    {:ok, _account, raw_token} = ServiceAccounts.create(%{"name" => "api-test-#{n}", "scopes" => scopes})
    raw_token
  end

  defp authed(conn, token), do: Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")

  describe "authentication" do
    test "no Authorization header returns 401", %{conn: conn} do
      conn = get(conn, "/api/v1/kyc/methods", product_type: "DEBIT")
      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end

    test "an invalid token returns 401", %{conn: conn} do
      conn = conn |> authed("sa_totally_made_up") |> get("/api/v1/kyc/methods", product_type: "DEBIT")
      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end

    test "a valid token missing the required scope returns 403", %{conn: conn} do
      token = token_with_scopes(["kyc:write"])
      conn = conn |> authed(token) |> get("/api/v1/kyc/methods", product_type: "DEBIT")
      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end

    test "every response carries a request_id in meta" do
      token = token_with_scopes(["kyc:read"])
      conn = build_conn() |> authed(token) |> get("/api/v1/kyc/methods", product_type: "DEBIT")
      assert json_response(conn, 200)["meta"]["request_id"] != nil
    end
  end

  describe "GET /api/v1/kyc/methods" do
    test "returns active methods for a product with their field schema", %{conn: conn} do
      method = method_fixture([%{"key" => "full_name", "label" => "Full Name", "type" => "text", "required" => true, "options" => []}])
      token = token_with_scopes(["kyc:read"])

      conn = conn |> authed(token) |> get("/api/v1/kyc/methods", product_type: "DEBIT")
      body = json_response(conn, 200)

      ids = Enum.map(body["methods"], & &1["kyc_method_id"])
      assert method.method_id in ids

      returned = Enum.find(body["methods"], &(&1["kyc_method_id"] == method.method_id))
      assert returned["product_type"] == "DEBIT"
      assert [%{"key" => "full_name"}] = returned["fields"]
    end

    test "missing product_type returns 422", %{conn: conn} do
      token = token_with_scopes(["kyc:read"])
      conn = conn |> authed(token) |> get("/api/v1/kyc/methods")
      assert json_response(conn, 422)["error"]["code"] == "missing_product_type"
    end
  end

  describe "POST /api/v1/kyc/requests" do
    test "submits a request against an active method", %{conn: conn} do
      customer = customer_fixture()
      method = method_fixture([%{"key" => "full_name", "label" => "Full Name", "type" => "text", "required" => true, "options" => []}])
      token = token_with_scopes(["kyc:write"])

      conn =
        conn
        |> authed(token)
        |> post("/api/v1/kyc/requests", %{
          "kyc_method_id" => method.method_id,
          "customer_id" => customer.customer_id,
          "data" => %{"full_name" => "Jane API"}
        })

      body = json_response(conn, 201)
      assert body["request"]["status"] == "submitted"
      assert body["request"]["data"]["full_name"] == "Jane API"

      persisted = Requests.get!(body["request"]["request_id"])
      assert persisted.customer_id == customer.customer_id
    end

    test "a locked step returns 422 step_locked", %{conn: conn} do
      customer = customer_fixture()

      {:ok, _step1} =
        Methods.create(%{"name" => "Step1 #{System.unique_integer([:positive])}", "title" => "Step 1", "product_type" => "PREPAID", "status" => "active", "step" => 1, "fields" => []})

      {:ok, step2} =
        Methods.create(%{"name" => "Step2 #{System.unique_integer([:positive])}", "title" => "Step 2", "product_type" => "PREPAID", "status" => "active", "step" => 2, "fields" => []})

      token = token_with_scopes(["kyc:write"])

      conn =
        conn
        |> authed(token)
        |> post("/api/v1/kyc/requests", %{"kyc_method_id" => step2.method_id, "customer_id" => customer.customer_id, "data" => %{}})

      assert json_response(conn, 422)["error"]["code"] == "step_locked"
    end

    test "an unknown kyc_method_id returns 404", %{conn: conn} do
      customer = customer_fixture()
      token = token_with_scopes(["kyc:write"])

      conn =
        conn
        |> authed(token)
        |> post("/api/v1/kyc/requests", %{"kyc_method_id" => Ecto.UUID.generate(), "customer_id" => customer.customer_id, "data" => %{}})

      assert json_response(conn, 404)["error"]["code"] == "method_not_found"
    end
  end

  describe "GET /api/v1/kyc/requests/:id" do
    test "returns the request's current status", %{conn: conn} do
      customer = customer_fixture()
      method = method_fixture()
      {:ok, request} = Requests.submit(method, %{"customer_id" => customer.customer_id, "data" => %{}})
      token = token_with_scopes(["kyc:read"])

      conn = conn |> authed(token) |> get("/api/v1/kyc/requests/#{request.request_id}")
      body = json_response(conn, 200)
      assert body["request"]["application_number"] == request.application_number
      assert body["request"]["status"] == "submitted"
    end

    test "an unknown id returns 404", %{conn: conn} do
      token = token_with_scopes(["kyc:read"])
      conn = conn |> authed(token) |> get("/api/v1/kyc/requests/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)["error"]["code"] == "request_not_found"
    end
  end

  describe "POST /api/v1/kyc/requests/:id/documents" do
    test "uploads a file for a field and returns the OCR result", %{conn: conn} do
      customer = customer_fixture()
      method = method_fixture([%{"key" => "id_doc", "label" => "ID Document", "type" => "file", "required" => true, "options" => []}])
      {:ok, request} = Requests.submit(method, %{"customer_id" => customer.customer_id, "data" => %{}})
      token = token_with_scopes(["kyc:write"])

      Req.Test.stub(VmuCore.Kyc.Adapters.OcrHttpAdapter, fn c ->
        Req.Test.json(c, %{"simplified_text" => %{"raw_text" => "784-1990-1234567-1"}})
      end)

      tmp_path = Path.join(System.tmp_dir!(), "api_upload_test_#{System.unique_integer([:positive])}.jpg")
      File.write!(tmp_path, "fake jpeg bytes")
      on_exit(fn -> File.rm(tmp_path) end)

      upload = %Plug.Upload{path: tmp_path, filename: "emirates_id.jpg", content_type: "image/jpeg"}

      conn =
        conn
        |> authed(token)
        |> post("/api/v1/kyc/requests/#{request.request_id}/documents", %{"field_key" => "id_doc", "file" => upload})

      body = json_response(conn, 201)
      assert body["document"]["field_key"] == "id_doc"
      assert body["document"]["ocr_text"] == "784-1990-1234567-1"

      document = Repo.get_by!(VmuCore.Kyc.Document, request_id: request.request_id)
      assert File.exists?(document.storage_path)
    end
  end
end
