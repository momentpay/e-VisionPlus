defmodule VmuCoreWeb.Plugs.FapiValidationPlug do
  @moduledoc """
  FAPI 2.0 security plug — enforces mTLS certificate binding + RS256 JWT validation.

  Per FAPI 2.0 (Financial-grade API Security Profile):
    1. Validates Bearer JWT in Authorization header using RS256.
    2. Extracts `cnf.x5t#S256` (certificate thumbprint confirmation claim) from JWT.
    3. Computes SHA-256 fingerprint of the client TLS certificate (forwarded by the
       TLS-terminating reverse proxy in the `x-client-cert` header, PEM-encoded).
    4. Verifies thumbprint from JWT claim matches the presented certificate.
    5. On failure → 401 with FAPI-compliant JSON error body; halts the pipeline.

  Proxy expectations (nginx/HAProxy):
    - `x-client-cert`: URL-encoded PEM certificate from the mutual TLS handshake
    - `x-forwarded-for`: client IP (for audit logging)

  JWT verification:
    - Algorithm: RS256 only (no HS256, no none).
    - Issuer: configured via `config :vmu_core, [:fapi, :jwt_issuer]`
    - Public JWKS: configured via `config :vmu_core, [:fapi, :jwks_path]` (local file)
      or `config :vmu_core, [:fapi, :jwks_url]` for remote JWKS.
  """

  import Plug.Conn
  require Logger

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with {:ok, token}       <- extract_bearer_token(conn),
         {:ok, claims}      <- verify_jwt(token),
         {:ok, cert_pem}    <- extract_client_cert(conn),
         {:ok, thumbprint}  <- compute_cert_thumbprint(cert_pem),
         :ok                <- verify_cert_binding(claims, thumbprint) do
      conn
      |> assign(:fapi_claims, claims)
      |> assign(:fapi_subject, claims["sub"])
    else
      {:error, reason} ->
        Logger.warning("[FAPI] Validation failed: #{inspect(reason)} path=#{conn.request_path}")
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: fapi_error_code(reason), error_description: fapi_description(reason)}))
        |> halt()
    end
  end

  # ---------------------------------------------------------------------------
  # JWT extraction + verification
  # ---------------------------------------------------------------------------

  defp extract_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> {:ok, String.trim(token)}
      _                         -> {:error, :missing_bearer_token}
    end
  end

  defp verify_jwt(token) do
    with {:ok, header}  <- decode_jwt_header(token),
         :ok            <- validate_algorithm(header),
         {:ok, public_key} <- load_public_key(header["kid"]),
         {:ok, claims}  <- verify_signature_and_claims(token, public_key) do
      {:ok, claims}
    end
  end

  defp decode_jwt_header(token) do
    case String.split(token, ".") do
      [header_b64 | _] ->
        case Base.url_decode64(header_b64, padding: false) do
          {:ok, json} -> Jason.decode(json)
          _           -> {:error, :invalid_jwt_header}
        end
      _ ->
        {:error, :malformed_jwt}
    end
  end

  defp validate_algorithm(%{"alg" => "RS256"}), do: :ok
  defp validate_algorithm(%{"alg" => alg}),     do: {:error, {:unsupported_algorithm, alg}}
  defp validate_algorithm(_),                    do: {:error, :missing_algorithm}

  defp load_public_key(kid) do
    jwks_path = Application.get_env(:vmu_core, [:fapi, :jwks_path], "priv/fapi/jwks.json")

    with {:ok, raw}  <- File.read(jwks_path),
         {:ok, jwks} <- Jason.decode(raw) do
      keys = Map.get(jwks, "keys", [])

      key =
        if kid do
          Enum.find(keys, fn k -> k["kid"] == kid end)
        else
          List.first(keys)
        end

      case key do
        nil -> {:error, :jwk_key_not_found}
        jwk -> build_rsa_public_key(jwk)
      end
    else
      _ -> {:error, :jwks_load_failed}
    end
  end

  defp build_rsa_public_key(%{"kty" => "RSA", "n" => n_b64, "e" => e_b64}) do
    with {:ok, n_bin} <- Base.url_decode64(n_b64, padding: false),
         {:ok, e_bin} <- Base.url_decode64(e_b64, padding: false) do
      n = :binary.decode_unsigned(n_bin)
      e = :binary.decode_unsigned(e_bin)
      {:ok, {:RSAPublicKey, n, e}}
    else
      _ -> {:error, :invalid_jwk_key}
    end
  end
  defp build_rsa_public_key(_), do: {:error, :unsupported_key_type}

  defp verify_signature_and_claims(token, public_key) do
    [header_b64, payload_b64, sig_b64] =
      case String.split(token, ".") do
        [h, p, s] -> [h, p, s]
        _         -> ["", "", ""]
      end

    signing_input = "#{header_b64}.#{payload_b64}"

    with {:ok, sig}     <- Base.url_decode64(sig_b64, padding: false),
         {:ok, payload} <- Base.url_decode64(payload_b64, padding: false),
         {:ok, claims}  <- Jason.decode(payload),
         :ok            <- verify_rsa_sha256(signing_input, sig, public_key),
         :ok            <- validate_standard_claims(claims) do
      {:ok, claims}
    else
      :error -> {:error, :invalid_base64}
      err    -> err
    end
  end

  defp verify_rsa_sha256(signing_input, signature, public_key) do
    if :public_key.verify(signing_input, :sha256, signature, public_key),
      do: :ok,
      else: {:error, :invalid_signature}
  end

  defp validate_standard_claims(claims) do
    now = System.system_time(:second)

    issuer = Application.get_env(:vmu_core, [:fapi, :jwt_issuer], "")

    cond do
      Map.get(claims, "iss") != issuer ->
        {:error, :invalid_issuer}

      exp = Map.get(claims, "exp") ->
        if exp < now, do: {:error, :token_expired}, else: :ok

      true ->
        {:error, :missing_expiry}
    end
  end

  # ---------------------------------------------------------------------------
  # mTLS certificate binding
  # ---------------------------------------------------------------------------

  defp extract_client_cert(conn) do
    case get_req_header(conn, "x-client-cert") do
      [cert_encoded | _] ->
        # Proxy sends URL-encoded PEM
        pem = URI.decode(cert_encoded)
        {:ok, pem}

      [] ->
        # Also accept x-ssl-client-cert (nginx default header name)
        case get_req_header(conn, "x-ssl-client-cert") do
          [cert | _] -> {:ok, URI.decode(cert)}
          []         -> {:error, :missing_client_certificate}
        end
    end
  end

  defp compute_cert_thumbprint(pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, _} | _] ->
        thumbprint =
          :crypto.hash(:sha256, der)
          |> Base.url_encode64(padding: false)

        {:ok, thumbprint}

      _ ->
        {:error, :invalid_client_certificate}
    end
  end

  # Verify cnf.x5t#S256 claim from JWT matches the client certificate thumbprint
  defp verify_cert_binding(claims, thumbprint) do
    case get_in(claims, ["cnf", "x5t#S256"]) do
      nil ->
        {:error, :missing_cert_confirmation_claim}

      jwt_thumbprint ->
        if jwt_thumbprint == thumbprint,
          do: :ok,
          else: {:error, :cert_binding_mismatch}
    end
  end

  # ---------------------------------------------------------------------------
  # Error response helpers
  # ---------------------------------------------------------------------------

  defp fapi_error_code(:missing_bearer_token),          do: "invalid_request"
  defp fapi_error_code(:invalid_signature),             do: "invalid_token"
  defp fapi_error_code(:token_expired),                 do: "invalid_token"
  defp fapi_error_code(:invalid_issuer),                do: "invalid_token"
  defp fapi_error_code(:missing_cert_confirmation_claim), do: "invalid_token"
  defp fapi_error_code(:cert_binding_mismatch),         do: "invalid_token"
  defp fapi_error_code(:missing_client_certificate),    do: "invalid_request"
  defp fapi_error_code({:unsupported_algorithm, _}),    do: "invalid_request"
  defp fapi_error_code(_),                              do: "server_error"

  defp fapi_description(:missing_bearer_token),          do: "Authorization header with Bearer token required"
  defp fapi_description(:invalid_signature),             do: "JWT signature verification failed"
  defp fapi_description(:token_expired),                 do: "JWT has expired"
  defp fapi_description(:invalid_issuer),                do: "JWT issuer does not match expected issuer"
  defp fapi_description(:missing_cert_confirmation_claim), do: "JWT must contain cnf.x5t#S256 claim"
  defp fapi_description(:cert_binding_mismatch),         do: "Client certificate does not match JWT cnf claim"
  defp fapi_description(:missing_client_certificate),    do: "mTLS client certificate not presented"
  defp fapi_description({:unsupported_algorithm, alg}),  do: "Algorithm #{alg} not permitted; only RS256 allowed"
  defp fapi_description(_),                              do: "Authentication failed"
end
