defmodule VmuCoreWeb.Api.V1.Customer.AuthControllerTest do
  @moduledoc """
  Real Postgres via Sandbox + real Phoenix.ConnTest HTTP pipeline, real SMS
  dispatch stubbed via `Req.Test` (same convention as `CAM.AuthTest`). CAM
  Phase F1 (2026-08-02) — the /api/v1/customer/auth/* surface: bearer-token
  ServiceAccount auth, scope enforcement, and the real OTP round trip.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias VmuCore.Repo
  alias VmuCore.ASM.ServiceAccounts
  alias VmuCore.Shared.{Customer, ModuleConfigWriter}
  alias VmuCore.CAM.OtpChallenges

  @endpoint VmuCoreWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    Req.Test.stub(VmuCore.CMS.NotificationDispatcher.HttpGateway, fn conn ->
      Req.Test.json(conn, %{"status" => "queued"})
    end)
    {:ok, conn: build_conn()}
  end

  defp customer_fixture do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"

    ModuleConfigWriter.put("cms", "notification_gateway_config",
      %{"sms" => %{"url" => "http://test.local/sms"}},
      %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)

    customer =
      %Customer{}
      |> Customer.changeset(%{
        sys_id: sys_id, bank_id: bank_id, first_name: "Api", last_name: "CamTest#{n}",
        mobile_country: "+971", mobile_number: "5#{100_000_000 + rem(n, 899_999_999)}"
      })
      |> Repo.insert!()

    {customer, sys_id, bank_id}
  end

  defp token_fixture(scopes \\ ["nts:customer"]) do
    n = System.unique_integer([:positive])
    {:ok, _account, raw_token} = ServiceAccounts.create(%{"name" => "cam-api-test-#{n}", "scopes" => scopes})
    raw_token
  end

  defp authed(conn, token), do: Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")

  test "request_otp then verify_otp round-trips a real session token", %{conn: conn} do
    {customer, sys_id, bank_id} = customer_fixture()
    token = token_fixture()

    otp_resp =
      conn
      |> authed(token)
      |> post("/api/v1/customer/auth/request_otp", %{"sys_id" => sys_id, "bank_id" => bank_id, "mobile_number" => customer.mobile_number})
      |> json_response(200)

    assert otp_resp["message"] =~ "code has been sent"

    {:ok, real_code, _challenge} = OtpChallenges.create(customer.customer_id)

    verify_resp =
      build_conn()
      |> authed(token)
      |> post("/api/v1/customer/auth/verify_otp", %{
        "sys_id" => sys_id, "bank_id" => bank_id, "mobile_number" => customer.mobile_number, "code" => real_code
      })
      |> json_response(200)

    assert is_binary(verify_resp["customer_token"])
    assert verify_resp["customer"]["customer_id"] == customer.customer_id
  end

  test "verify_otp with a wrong code returns 401", %{conn: conn} do
    {customer, sys_id, bank_id} = customer_fixture()
    token = token_fixture()
    {:ok, _code, _challenge} = OtpChallenges.create(customer.customer_id)

    resp =
      conn
      |> authed(token)
      |> post("/api/v1/customer/auth/verify_otp", %{
        "sys_id" => sys_id, "bank_id" => bank_id, "mobile_number" => customer.mobile_number, "code" => "000000"
      })
      |> json_response(401)

    assert resp["error"]["code"] == "invalid_code"
  end

  test "no Authorization header returns 401", %{conn: conn} do
    resp =
      conn
      |> post("/api/v1/customer/auth/request_otp", %{"sys_id" => "T1", "bank_id" => "B1", "mobile_number" => "500000000"})
      |> json_response(401)

    assert resp["error"]["code"] == "unauthorized"
  end

  test "a token without the nts:customer scope returns 403", %{conn: conn} do
    token = token_fixture(["kyc:read"])

    resp =
      conn
      |> authed(token)
      |> post("/api/v1/customer/auth/request_otp", %{"sys_id" => "T1", "bank_id" => "B1", "mobile_number" => "500000000"})
      |> json_response(403)

    assert resp["error"]["code"] == "forbidden"
  end
end
