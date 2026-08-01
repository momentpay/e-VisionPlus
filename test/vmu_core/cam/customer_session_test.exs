defmodule VmuCore.CAM.CustomerSessionTest do
  @moduledoc "CAM Phase F1 (2026-08-02) — no DB needed, pure JWT logic."

  use ExUnit.Case, async: true

  alias VmuCore.Shared.Customer
  alias VmuCore.CAM.CustomerSession

  defp fake_customer do
    %Customer{customer_id: Ecto.UUID.generate(), sys_id: "T100", bank_id: "B100"}
  end

  test "issue/1 then verify/1 round-trips the customer_id" do
    customer = fake_customer()
    token = CustomerSession.issue(customer)

    assert {:ok, customer_id} = CustomerSession.verify(token)
    assert customer_id == customer.customer_id
  end

  test "verify/1 rejects a garbage token" do
    assert {:error, :invalid} = CustomerSession.verify("not-a-real-jwt")
  end

  test "verify/1 rejects a token signed with a different key" do
    customer = fake_customer()
    now = System.system_time(:second)
    claims = %{"sub" => customer.customer_id, "iat" => now, "exp" => now + 1800}
    other_jwk = JOSE.JWK.from_oct("a-completely-different-signing-key")
    {_, forged} = JOSE.JWT.sign(other_jwk, %{"alg" => "HS256"}, claims) |> JOSE.JWS.compact()

    assert {:error, :invalid} = CustomerSession.verify(forged)
  end

  test "verify/1 rejects an expired token" do
    customer = fake_customer()
    now = System.system_time(:second)
    claims = %{"sub" => customer.customer_id, "iat" => now - 3600, "exp" => now - 1}

    jwk =
      Application.get_env(:vmu_core, :cam, [])
      |> Keyword.fetch!(:session_signing_key)
      |> JOSE.JWK.from_oct()

    {_, token} = JOSE.JWT.sign(jwk, %{"alg" => "HS256"}, claims) |> JOSE.JWS.compact()

    assert {:error, :expired} = CustomerSession.verify(token)
  end
end
