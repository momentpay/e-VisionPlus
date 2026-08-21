defmodule VmuCore.ASM.OidcClient do
  @moduledoc """
  OIDC Authorization Code flow client (A2, 2026-07-13) — vmu_core ASM
  operator login against one corporate IdP.

  Deliberately minimal: only the pieces `OperatorSessionController` needs
  (build the authorize redirect, exchange a code, verify the returned ID
  token). No IdP-specific SDK — OIDC's core flow (redirect + code exchange
  + JWKS-verified JWT) is a stable, vendor-agnostic standard, unlike e.g.
  a bank's proprietary file format, so building directly against the spec
  here isn't the same "guessing" risk flagged elsewhere in this program.

  Test-time faking of `exchange_code/2`/`verify_id_token/3`'s HTTP calls
  uses `Req.Test` (same pattern as `CMS.NotificationDispatcher.
  HttpGateway`) — `config/test.exs` sets `:vmu_core, :oidc_http_plug` to
  `{Req.Test, VmuCore.ASM.OidcClient}`; this lets the real signature-
  verification/claims-validation logic below be exercised against a real
  token signed by `VmuCoreWeb.MockIdp` without a live TCP listener.
  """

  require Logger
  alias VmuCore.ASM.OidcConfig

  @doc "Builds the IdP authorization URL. Caller stores `state`/`nonce` in the session to verify on callback."
  @spec authorization_url(OidcConfig.t(), String.t(), String.t()) :: String.t()
  def authorization_url(%OidcConfig{} = cfg, state, nonce) do
    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id"     => cfg.client_id,
        "redirect_uri"  => cfg.redirect_uri,
        "scope"         => "openid profile email",
        "state"         => state,
        "nonce"         => nonce
      })

    cfg.authorize_endpoint <> "?" <> query
  end

  @doc "Exchanges an authorization code for an ID token at the IdP's token endpoint."
  @spec exchange_code(OidcConfig.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def exchange_code(%OidcConfig{} = cfg, code) do
    opts =
      [url: cfg.token_endpoint,
       form: %{
         grant_type:    "authorization_code",
         code:          code,
         client_id:     cfg.client_id,
         client_secret: cfg.client_secret,
         redirect_uri:  cfg.redirect_uri
       }] ++ plug_opts()

    case Req.post(opts) do
      {:ok, %Req.Response{status: 200, body: %{"id_token" => id_token}}} ->
        {:ok, id_token}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("[ASM.OidcClient] token endpoint returned #{status}: #{inspect(body)}")
        {:error, :token_exchange_failed}

      {:error, reason} ->
        Logger.warning("[ASM.OidcClient] token endpoint request failed: #{inspect(reason)}")
        {:error, :token_endpoint_unreachable}
    end
  end

  @doc """
  Verifies an ID token's RS256 signature against the IdP's JWKS, and its
  `iss`/`aud`/`exp`/`nonce` claims. Always fetches JWKS fresh (no caching
  yet — acceptable at login-time volume, not a hot path) and always pins
  the algorithm to RS256 explicitly — an `alg` value is never read out of
  the token to decide how to verify it (the classic "alg confusion" class
  of JWT vulnerability).
  """
  @spec verify_id_token(OidcConfig.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def verify_id_token(%OidcConfig{} = cfg, id_token, expected_nonce) do
    with {:ok, jwks} <- fetch_jwks(cfg),
         {:ok, claims} <- verify_signature(jwks, id_token) do
      validate_claims(claims, cfg, expected_nonce)
    end
  end

  defp fetch_jwks(cfg) do
    opts = [url: cfg.jwks_endpoint] ++ plug_opts()

    case Req.get(opts) do
      {:ok, %Req.Response{status: 200, body: %{"keys" => keys}}} -> {:ok, keys}
      _ -> {:error, :jwks_unreachable}
    end
  end

  defp plug_opts do
    case Application.get_env(:vmu_core, :oidc_http_plug) do
      nil -> []
      plug -> [plug: plug]
    end
  end

  defp verify_signature(keys, id_token) do
    keys
    |> Enum.find_value(fn key_map ->
      jwk = JOSE.JWK.from_map(key_map)

      case JOSE.JWT.verify_strict(jwk, ["RS256"], id_token) do
        {true, %JOSE.JWT{fields: claims}, _jws} -> {:ok, claims}
        _ -> nil
      end
    end)
    |> case do
      nil -> {:error, :signature_invalid}
      result -> result
    end
  end

  defp validate_claims(claims, cfg, expected_nonce) do
    now = System.system_time(:second)

    cond do
      claims["iss"] != cfg.issuer ->
        {:error, :iss_mismatch}

      claims["aud"] != cfg.client_id ->
        {:error, :aud_mismatch}

      claims["nonce"] != expected_nonce ->
        {:error, :nonce_mismatch}

      is_integer(claims["exp"]) and claims["exp"] < now ->
        {:error, :token_expired}

      true ->
        {:ok, claims}
    end
  end
end
