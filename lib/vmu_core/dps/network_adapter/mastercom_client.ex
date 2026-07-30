defmodule VmuCore.DPS.NetworkAdapter.MastercomClient do
  @moduledoc """
  Low-level HTTP client for the real Mastercard Mastercom v6 API (DPS-P5).

  Re-ported 2026-07-29 from `Avenza/apps/vmu_dps` — real, complete work
  from before the platform-of-record reversal that never carried back to
  standalone vmu_core, the same "real work built once, lost on the
  reversal" pattern found repeatedly this program (COL, LMS, ASM-SSO,
  CU-1). Confirmed with the user (2026-07-30) that the same Mastercard
  Developer registration this consumer key belongs to also covers MDES
  Token Connect — so this client's signing logic doubles as the concrete
  starting point for the NTS tokenization plan's Phase B MDES client
  (`docs/wallet/WALLET_Module_Requirements.md`), not just a DPS-scoped fix.

  Mastercard's whole developer platform (not just Mastercom) uses the same
  auth scheme: OAuth 1.0a with `RSA-SHA256` signing plus their `oauth_body_hash`
  extension (a base64 SHA-256 digest of the request body, required because
  Mastercard's payloads are JSON, not the form-encoded bodies plain OAuth 1.0a
  assumes). Official signing looks like this everywhere Mastercard publishes
  a client library (Java/Node/Python/.NET/PHP/Ruby) — there is no Elixir one,
  so this reimplements the algorithm directly against RFC 5849 using only
  `:crypto`/`:public_key` (OTP stdlib, no new dependency).

  ## What this needs to make a real call

  Two credentials, both resolved from `config :vmu_core, :mastercom` (see
  `config/config.exs`):
    - `consumer_key` — present (from `.env`'s `MASTERCARDCOM_Consumerkey`,
      confirmed by the user 2026-07-30 to also cover MDES)
    - `private_key_path` — a PEM file with the RSA private key generated
      alongside that consumer key in the Mastercard Developers portal.
      **Not present in this project** — Mastercard doesn't store private
      keys after you download them once; if genuinely lost, a new key pair
      needs generating under the same Developer portal project. Every call
      correctly fails closed with `{:error, :missing_private_key}` until one
      is configured — this client does not silently no-op or fabricate a
      response.

  ## Base URL

  Defaults to the sandbox host (`sandbox.api.mastercard.com`); override via
  `MASTERCOM_BASE_URL` for production once this has been validated against
  the sandbox with real credentials.
  """

  require Logger

  @doc """
  Makes a signed request. `path` is relative to the configured base_url
  (e.g. `"/claims"`, `"/claims/\#{claim_id}/chargebacks"`).
  """
  @spec request(atom(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def request(method, path, body \\ %{}) do
    config = Application.get_env(:vmu_core, :mastercom, [])

    with {:ok, private_key} <- load_private_key(config[:private_key_path]),
         consumer_key when is_binary(consumer_key) <- config[:consumer_key] || {:error, :missing_consumer_key} do
      base_url = config[:base_url]
      url      = base_url <> path
      body_json = Jason.encode!(body)

      auth_header = build_auth_header(method, url, body_json, consumer_key, private_key)

      opts =
        [
          method: method,
          url: url,
          body: body_json,
          headers: [
            {"Authorization", auth_header},
            {"Content-Type", "application/json"},
            {"Accept", "application/json"}
          ]
        ] ++ plug_opts()

      opts
      |> Req.request()
      |> case do
        {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
          {:ok, resp_body}

        {:ok, %{status: status, body: resp_body}} ->
          Logger.warning("[Mastercom] #{method} #{path} -> HTTP #{status}: #{inspect(resp_body)}")
          {:error, {:http_error, status, resp_body}}

        {:error, reason} ->
          Logger.warning("[Mastercom] #{method} #{path} request failed: #{inspect(reason)}")
          {:error, {:transport_error, reason}}
      end
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :missing_consumer_key}
    end
  end

  # Test-time faking via Req.Test, same pattern as ASM.OidcClient/CMS.
  # NotificationDispatcher.HttpGateway: config/test.exs sets
  # :vmu_core, :mastercom_http_plug to {Req.Test, __MODULE__}.
  defp plug_opts do
    case Application.get_env(:vmu_core, :mastercom_http_plug) do
      nil -> []
      plug -> [plug: plug]
    end
  end

  # ---------------------------------------------------------------------------
  # OAuth 1.0a + RSA-SHA256 + oauth_body_hash (Mastercard's signing scheme)
  # ---------------------------------------------------------------------------

  defp build_auth_header(method, url, body_json, consumer_key, private_key) do
    oauth_params = %{
      "oauth_consumer_key" => consumer_key,
      "oauth_nonce" => nonce(),
      "oauth_signature_method" => "RSA-SHA256",
      "oauth_timestamp" => Integer.to_string(System.system_time(:second)),
      "oauth_version" => "1.0",
      "oauth_body_hash" => body_hash(body_json)
    }

    signature = sign(method, url, oauth_params, private_key)
    signed_params = Map.put(oauth_params, "oauth_signature", signature)

    header_params =
      signed_params
      |> Enum.map(fn {k, v} -> "#{percent_encode(k)}=\"#{percent_encode(v)}\"" end)
      |> Enum.join(", ")

    "OAuth " <> header_params
  end

  defp body_hash(body_json) do
    :crypto.hash(:sha256, body_json) |> Base.encode64()
  end

  defp sign(method, url, oauth_params, private_key) do
    base_string = signature_base_string(method, url, oauth_params)
    :public_key.sign(base_string, :sha256, private_key) |> Base.encode64()
  end

  # RFC 5849 §3.4.1 — method + base URL (no query) + normalized params,
  # each component percent-encoded then joined with "&". Mastercom v6's
  # documented endpoints use path parameters, not query strings, so the
  # normalized-params set here is exactly the oauth_* params (no separate
  # query-string merge step needed for this API).
  defp signature_base_string(method, url, oauth_params) do
    normalized_params =
      oauth_params
      |> Enum.map(fn {k, v} -> "#{percent_encode(k)}=#{percent_encode(v)}" end)
      |> Enum.sort()
      |> Enum.join("&")

    [
      method |> Atom.to_string() |> String.upcase(),
      percent_encode(url),
      percent_encode(normalized_params)
    ]
    |> Enum.join("&")
  end

  # OAuth's percent-encoding (RFC 3986 unreserved set) is stricter than
  # URI.encode_www_form — must not encode ALPHA/DIGIT/"-"/"."/"_"/"~" and
  # must encode everything else, including "~"'s common false friends.
  defp percent_encode(value) do
    value
    |> to_string()
    |> URI.encode(&(&1 in ?A..?Z or &1 in ?a..?z or &1 in ?0..?9 or &1 in [?-, ?., ?_, ?~]))
  end

  defp nonce, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp load_private_key(nil), do: {:error, :missing_private_key}

  defp load_private_key(path) do
    with {:ok, pem} <- File.read(path),
         [entry | _] <- :public_key.pem_decode(pem) do
      {:ok, :public_key.pem_entry_decode(entry)}
    else
      {:error, _posix} -> {:error, :missing_private_key}
      [] -> {:error, :invalid_private_key}
    end
  end
end
