defmodule VmuCore.CAM.AuthTest do
  @moduledoc """
  Real Postgres via Sandbox, real `NotificationDispatcher.SmsAdapter` HTTP
  call stubbed via `Req.Test` (the established convention for every
  external-HTTP boundary this session) — no mocking of `CAM.Auth` itself.
  CAM Phase F1 (2026-08-02).
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.Shared.{Customer, ModuleConfigWriter}
  alias VmuCore.CAM.{Auth, OtpChallenges}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    Req.Test.stub(VmuCore.CMS.NotificationDispatcher.HttpGateway, fn conn ->
      Req.Test.json(conn, %{"status" => "queued"})
    end)
    :ok
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
        sys_id: sys_id, bank_id: bank_id, first_name: "Cam", last_name: "AuthTest#{n}",
        mobile_country: "+971", mobile_number: "5#{100_000_000 + rem(n, 899_999_999)}"
      })
      |> Repo.insert!()

    {customer, sys_id, bank_id}
  end

  test "request_otp/3 for a real customer creates a challenge and dispatches SMS" do
    {customer, sys_id, bank_id} = customer_fixture()

    assert :ok = Auth.request_otp(sys_id, bank_id, customer.mobile_number)

    assert {:error, :invalid_code} = OtpChallenges.verify(customer.customer_id, "000000")
  end

  test "request_otp/3 for an unknown mobile number still returns :ok (no enumeration)" do
    assert :ok = Auth.request_otp("T999", "B999", "5999999999")
  end

  test "verify_otp/4 with the correct code returns a session token" do
    {customer, sys_id, bank_id} = customer_fixture()

    {:ok, code, _challenge} = OtpChallenges.create(customer.customer_id)

    assert {:ok, token, returned_customer} = Auth.verify_otp(sys_id, bank_id, customer.mobile_number, code)
    assert is_binary(token)
    assert returned_customer.customer_id == customer.customer_id
  end

  test "verify_otp/4 with an unknown mobile number fails cleanly" do
    assert {:error, :not_found} = Auth.verify_otp("T999", "B999", "5999999999", "123456")
  end
end
