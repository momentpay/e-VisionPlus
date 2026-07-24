defmodule VmuCoreWeb.MockIdp do
  @moduledoc """
  A2 (2026-07-13) — self-hosted mock OIDC provider, dev/test only.

  There is no real corporate IdP available in this environment to
  integrate against. Rather than skip verification or hand-wave it, this
  GenServer holds a real RSA keypair generated at boot and issues real,
  correctly-signed RS256 ID tokens through a real authorize/token/JWKS
  flow — `VmuCore.ASM.OidcClient` is exercised against the actual
  signature-verification code path it would use against a real IdP, just
  not a live Okta/Azure AD tenant. Same posture as this session's
  `SoftHSM`: real crypto, dev-mode adapter.

  **Never mounted outside dev/test** — gated at compile time in
  `router.ex` (`if Mix.env() in [:dev, :test]`) and this module's own
  supervision-tree registration in `application.ex`.

  Auto-approves every authorization request (no real login UI/consent
  screen) — this is a protocol-conformance fixture, not a UI to test
  against.
  """

  use GenServer

  # In-memory "directory" of test IdP users the mock recognizes, keyed by
  # the value that will be issued as the `preferred_username` claim.
  @known_subjects %{
    "sso.tester" => %{"sub" => "mock-sub-001", "email" => "sso.tester@example.com"},
    "sso.nomatch" => %{"sub" => "mock-sub-002", "email" => "sso.nomatch@example.com"}
  }

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Issues a signed authorization `code` for the given username + nonce (mock consent)."
  def issue_code(username, nonce), do: GenServer.call(__MODULE__, {:issue_code, username, nonce})

  @doc "Exchanges a code for a signed ID token. Codes are single-use."
  def exchange_code(code, client_id), do: GenServer.call(__MODULE__, {:exchange_code, code, client_id})

  @doc "Returns the JWKS document (public key only) for token verification."
  def jwks, do: GenServer.call(__MODULE__, :jwks)

  @impl true
  def init(_) do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, jwk_with_kid} = JOSE.JWK.merge(jwk, %{"kid" => "mock-idp-key-1", "use" => "sig", "alg" => "RS256"}) |> JOSE.JWK.to_map()
    signing_key = JOSE.JWK.from_map(jwk_with_kid)

    {:ok, %{signing_key: signing_key, codes: %{}}}
  end

  @impl true
  def handle_call({:issue_code, username, nonce}, _from, state) do
    case Map.fetch(@known_subjects, username) do
      {:ok, subject} ->
        code = "mock_code_" <> (:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false))
        codes = Map.put(state.codes, code, %{username: username, subject: subject, nonce: nonce})
        {:reply, {:ok, code}, %{state | codes: codes}}

      :error ->
        {:reply, {:error, :unknown_test_user}, state}
    end
  end

  def handle_call({:exchange_code, code, client_id}, _from, state) do
    case Map.pop(state.codes, code) do
      {nil, _codes} ->
        {:reply, {:error, :invalid_or_used_code}, state}

      {%{username: username, subject: subject, nonce: nonce}, codes} ->
        id_token = sign_id_token(state.signing_key, client_id, username, subject, nonce)
        {:reply, {:ok, id_token}, %{state | codes: codes}}
    end
  end

  def handle_call(:jwks, _from, state) do
    {_, public_map} = state.signing_key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    {:reply, %{"keys" => [public_map]}, state}
  end

  defp sign_id_token(signing_key, client_id, username, subject, nonce) do
    now = System.system_time(:second)

    claims = %{
      "iss"                => issuer(),
      "aud"                => client_id,
      "sub"                => subject["sub"],
      "preferred_username" => username,
      "email"               => subject["email"],
      "nonce"              => nonce,
      "iat"                => now,
      "exp"                => now + 300
    }

    {_jws, compact} =
      JOSE.JWT.sign(signing_key, %{"alg" => "RS256", "kid" => "mock-idp-key-1"}, claims)
      |> JOSE.JWS.compact()

    compact
  end

  defp issuer, do: Application.get_env(:vmu_core, :mock_idp_issuer, "http://localhost:4001/mock_idp")
end
