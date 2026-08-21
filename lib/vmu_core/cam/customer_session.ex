defmodule VmuCore.CAM.CustomerSession do
  @moduledoc """
  Signs/verifies the cardholder session token — CAM Phase F1 (2026-08-02).
  HS256 (symmetric), unlike `ASM.OidcClient`/`VmuCoreWeb.MockIdp`'s RS256 —
  those verify a THIRD PARTY's signature (or are verified BY a third
  party); this token is issued and verified only by us, so a shared
  secret is the right, simpler tool. Reuses `:jose` (already a dependency)
  for consistency rather than introducing Joken/Guardian.

  Config: `config :vmu_core, :cam, session_signing_key: <32+ byte secret>`.
  """

  @ttl_seconds 1800

  @spec issue(VmuCore.Shared.Customer.t()) :: String.t()
  def issue(customer) do
    now = System.system_time(:second)

    claims = %{
      "sub"     => customer.customer_id,
      "sys_id"  => customer.sys_id,
      "bank_id" => customer.bank_id,
      "iat"     => now,
      "exp"     => now + @ttl_seconds
    }

    jwk = signing_jwk()
    {_, token} = JOSE.JWT.sign(jwk, %{"alg" => "HS256"}, claims) |> JOSE.JWS.compact()
    token
  end

  @spec verify(String.t()) :: {:ok, binary()} | {:error, :invalid | :expired}
  def verify(token) do
    jwk = signing_jwk()

    case JOSE.JWT.verify_strict(jwk, ["HS256"], token) do
      {true, %JOSE.JWT{fields: %{"sub" => customer_id, "exp" => exp}}, _jws} ->
        if System.system_time(:second) < exp do
          {:ok, customer_id}
        else
          {:error, :expired}
        end

      _ ->
        {:error, :invalid}
    end
  rescue
    _ -> {:error, :invalid}
  end

  defp signing_jwk do
    key =
      Application.get_env(:vmu_core, :cam, [])
      |> Keyword.fetch!(:session_signing_key)

    JOSE.JWK.from_oct(key)
  end
end
