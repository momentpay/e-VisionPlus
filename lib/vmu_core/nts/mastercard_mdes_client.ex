defmodule VmuCore.NTS.MastercardMdesClient do
  @moduledoc """
  Low-level HTTP client for the real Mastercard MDES Token Connect API
  (NTS Phase B, 2026-07-31), grounded in the real spec at `docs/nts/
  mdes-token-connect.yaml` — not guessed.

  Same OAuth 1.0a + RSA-SHA256 + `oauth_body_hash` request-signing scheme
  as `DPS.NetworkAdapter.MastercomClient` (Mastercard's whole developer
  platform uses this, confirmed by the user: the same Mastercard
  Developer registration covers both Mastercom and MDES). Deliberately
  duplicated here rather than shared with the DPS module — NTS and DPS
  are different bounded contexts that happen to use the same underlying
  Mastercard credential, not a reason to couple them.

  Config: `config :vmu_core, :mdes, consumer_key:, private_key_path:,
  cert_path:, base_url:`. `consumer_key`/`private_key_path` are the same
  values `:mastercom`'s config resolves (same Developer registration);
  `cert_path` is MDES's own public field-level-encryption certificate
  (`docs/wallet/mdes-token-connect-clientenc*.pem`), used by
  `NTS.MastercardPayloadEncryption` for the request bodies that need it.
  """

  require Logger

  alias VmuCore.NTS.MastercardPayloadEncryption

  # The {maj} path parameter in every endpoint — "major.minor" API
  # version, per the spec's own example (`docs/nts/mdes-token-connect.yaml`
  # parameterIdMaj).
  @maj "1/0"

  @doc "POST /connect/{maj}/getEligibleTokenRequestors — no encryption needed, no card data in this call."
  @spec get_eligible_token_requestors([String.t()], String.t()) :: {:ok, map()} | {:error, term()}
  def get_eligible_token_requestors(account_ranges, request_id) do
    request(:post, "/connect/#{@maj}/getEligibleTokenRequestors", %{
      "requestId" => request_id,
      "accountRanges" => account_ranges
    })
  end

  @doc """
  POST /connect/{maj}/pushMultipleAccounts — pushes one card to a Token
  Requestor. `funding_account` is the plaintext `FundingAccount` map
  (`docs/nts/mdes-token-connect.yaml`'s schema — `cardAccountData: %{
  "accountNumber" => ..., "expiryMonth" => ..., "expiryYear" => ...}`);
  encrypted here via `MastercardPayloadEncryption`, never sent plaintext.

  `opts`:
    - `:request_issuer_initiated_digitization_data` (default `true`) —
      asks MDES to return the digitization result in-band rather than
      requiring a separate inbound callback. Case 2/Google Pay and
      Case 4/proprietary comms rely on this default. Cases 1/3/5 (NTS
      Phase F2+, browser-redirect flows) pass `false` — they want the
      standard `availablePushMethods` redirect response instead.
    - `:callback_url` — populates `signatureData.callbackURL` (per spec,
      "the URL for the token requestor to use to pass control back to
      the Issuer"). Only meaningful for the redirect flows above.
    - `:token_requestor_session_id` — populates `signatureData.
      tokenRequestorSessionId` ("the session Id provided by the token
      requestor in pull provisioning use case") — Case 5 (Pull from
      Wallet, NTS Phase F4): the wallet already started a session before
      redirecting the cardholder to us, and this ties our push back to
      it. Same `signatureData` object as `:callback_url` above (mutually
      exclusive in practice — a request is either a push-initiated
      redirect or a pull-initiated one, never both).
  """
  @spec push_multiple_accounts(String.t(), String.t(), map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def push_multiple_accounts(request_id, token_requestor_id, funding_account, push_account_id, opts \\ []) do
    config = Application.get_env(:vmu_core, :mdes, [])

    with {:ok, encrypted} <-
           MastercardPayloadEncryption.encrypt(
             [%{"pushAccountId" => push_account_id, "fundingAccountData" => funding_account}],
             config[:cert_path]
           ) do
      body =
        %{
          "requestId" => request_id,
          "tokenRequestorId" => token_requestor_id,
          "pushFundingAccounts" => %{"encryptedPayload" => encrypted},
          "requestIssuerInitiatedDigitizationData" => Keyword.get(opts, :request_issuer_initiated_digitization_data, true)
        }
        |> maybe_put_signature_data(Keyword.get(opts, :callback_url), Keyword.get(opts, :token_requestor_session_id))

      request(:post, "/connect/#{@maj}/pushMultipleAccounts", body)
    end
  end

  defp maybe_put_signature_data(body, nil, nil), do: body

  defp maybe_put_signature_data(body, callback_url, token_requestor_session_id) do
    signature_data =
      %{}
      |> maybe_put("callbackURL", callback_url)
      |> maybe_put("tokenRequestorSessionId", token_requestor_session_id)

    Map.put(body, "signatureData", signature_data)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Makes a signed request. `path` is relative to the configured base_url
  and already has `{maj}` substituted by the caller-facing functions
  above.
  """
  @spec request(atom(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def request(method, path, body \\ %{}) do
    config = Application.get_env(:vmu_core, :mdes, [])

    with {:ok, private_key} <- load_private_key(config[:private_key_path]),
         consumer_key when is_binary(consumer_key) <- config[:consumer_key] || {:error, :missing_consumer_key} do
      base_url = config[:base_url]
      url = base_url <> path
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
          Logger.warning("[MDES] #{method} #{path} -> HTTP #{status}: #{inspect(resp_body)}")
          {:error, {:http_error, status, resp_body}}

        {:error, reason} ->
          Logger.warning("[MDES] #{method} #{path} request failed: #{inspect(reason)}")
          {:error, {:transport_error, reason}}
      end
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :missing_consumer_key}
    end
  end

  defp plug_opts do
    case Application.get_env(:vmu_core, :mdes_http_plug) do
      nil -> []
      plug -> [plug: plug]
    end
  end

  # ---------------------------------------------------------------------------
  # OAuth 1.0a + RSA-SHA256 + oauth_body_hash — identical scheme to
  # DPS.NetworkAdapter.MastercomClient (Mastercard's platform-wide auth).
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

  defp body_hash(body_json), do: :crypto.hash(:sha256, body_json) |> Base.encode64()

  defp sign(method, url, oauth_params, private_key) do
    base_string = signature_base_string(method, url, oauth_params)
    :public_key.sign(base_string, :sha256, private_key) |> Base.encode64()
  end

  defp signature_base_string(method, url, oauth_params) do
    normalized_params =
      oauth_params
      |> Enum.map(fn {k, v} -> "#{percent_encode(k)}=#{percent_encode(v)}" end)
      |> Enum.sort()
      |> Enum.join("&")

    [method |> Atom.to_string() |> String.upcase(), percent_encode(url), percent_encode(normalized_params)]
    |> Enum.join("&")
  end

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
