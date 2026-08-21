defmodule VmuCoreWeb.MockIdpController do
  @moduledoc """
  HTTP surface for `VmuCoreWeb.MockIdp` (A2, 2026-07-13) — dev/test only,
  routes gated at compile time in `router.ex`.

  `login_hint` (a real, standard OIDC authorization-request parameter,
  not a mock-only invention) selects which fixture test user "logs in",
  since there's no real login form here — just protocol conformance.
  """

  use Phoenix.Controller, formats: [:html, :json]

  alias VmuCoreWeb.MockIdp

  @doc "GET /mock_idp/authorize — auto-approves and redirects back with a code."
  def authorize(conn, params) do
    username = Map.get(params, "login_hint", "sso.tester")
    redirect_uri = params["redirect_uri"]
    state = params["state"]
    nonce = params["nonce"]

    case MockIdp.issue_code(username, nonce) do
      {:ok, code} ->
        redirect(conn, external: redirect_uri <> "?code=#{URI.encode_www_form(code)}&state=#{URI.encode_www_form(state || "")}")

      {:error, :unknown_test_user} ->
        conn
        |> put_status(400)
        |> text("mock_idp: unknown login_hint #{inspect(username)} — known test users: sso.tester, sso.nomatch")
    end
  end

  @doc "POST /mock_idp/token — exchanges a code for a signed ID token."
  def token(conn, %{"code" => code, "client_id" => client_id}) do
    case MockIdp.exchange_code(code, client_id) do
      {:ok, id_token} ->
        json(conn, %{
          access_token: "mock_access_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false),
          id_token: id_token,
          token_type: "Bearer",
          expires_in: 300
        })

      {:error, :invalid_or_used_code} ->
        conn |> put_status(400) |> json(%{error: "invalid_grant"})
    end
  end

  def token(conn, _params) do
    conn |> put_status(400) |> json(%{error: "invalid_request"})
  end

  @doc "GET /mock_idp/jwks — the public JWKS document."
  def jwks(conn, _params), do: json(conn, MockIdp.jwks())
end
