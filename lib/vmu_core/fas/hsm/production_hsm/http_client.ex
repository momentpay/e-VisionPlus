defmodule VmuCore.FAS.HSM.ProductionHSM.HttpClient do
  @moduledoc """
  Shared HTTP POST used by every `VmuCore.FAS.HSM.ProductionHSM` command —
  one endpoint (`POST /api/v1/rest/`) for every payShield 10K host
  command, authenticated by mutual TLS (no bearer token/API key on any
  sampled request in the reference Postman collection).

  Test-time faking uses `Req.Test` (a real Plug pipeline, not a mock —
  same pattern as `CMS.NotificationDispatcher.HttpGateway` and
  `ASM.OidcClient`) — `config/test.exs` sets `:vmu_core,
  :veriscent_hsm_http_plug` to `{Req.Test, VmuCore.FAS.HSM.ProductionHSM.HttpClient}`.

  **Live connectivity to the real Veriscent endpoint is unverified as of
  2026-07-24** — the reference mTLS client certificate in
  `Veriscent-HSM-cloud/slot_1/` has expired (confirmed live: TLS
  handshake reaches certificate exchange, server responds
  `certificate_unknown`). Request/response shapes below are built from
  the real Postman collection samples plus the real payShield 10K Core
  Host Commands manual (not guessed), but an actual round trip against
  Veriscent's service needs a renewed certificate to confirm.
  """

  require Logger

  @doc """
  POSTs `body` (a map) to the configured Veriscent service URL under
  mutual TLS. Returns `{:ok, decoded_json_map}` on any 2xx response
  (payShield host commands report errors via the `errorCode` field in a
  200 response body, not HTTP status), or `{:error, reason}`.
  """
  @spec post(map()) :: {:ok, map()} | {:error, term()}
  def post(body) do
    config = Application.get_env(:vmu_core, :production_hsm, [])
    service_url = Keyword.get(config, :service_url)

    if is_nil(service_url) and is_nil(plug_opts()[:plug]) do
      {:error, :hsm_not_configured}
    else
      opts =
        [url: "https://#{service_url || "test-plug"}/api/v1/rest/", json: body, receive_timeout: 5_000]
        |> Keyword.merge(mtls_opts(config))
        |> Keyword.merge(plug_opts())

      case Req.post(opts) do
        {:ok, %Req.Response{status: status, body: resp_body}} when status in 200..299 ->
          {:ok, resp_body}

        {:ok, %Req.Response{status: status, body: resp_body}} ->
          Logger.warning("[ProductionHSM.HttpClient] non-2xx status=#{status} body=#{inspect(resp_body)}")
          {:error, {:http_error, status, resp_body}}

        {:error, reason} ->
          Logger.warning("[ProductionHSM.HttpClient] request failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp mtls_opts(config) do
    case {Keyword.get(config, :client_cert), Keyword.get(config, :ca_chain)} do
      {nil, _} ->
        []

      {client_cert, ca_chain} ->
        password = config |> Keyword.get(:client_cert_password_env) |> then(&(&1 && System.get_env(&1)))

        [connect_options: [transport_opts: cert_transport_opts(client_cert, password, ca_chain)]]
    end
  end

  defp cert_transport_opts(client_cert_path, password, ca_chain_path) do
    opts = [certfile: client_cert_path]
    opts = if password, do: [{:password, String.to_charlist(password)} | opts], else: opts
    opts = if ca_chain_path, do: [{:cacertfile, ca_chain_path} | opts], else: opts
    opts
  end

  defp plug_opts do
    case Application.get_env(:vmu_core, :veriscent_hsm_http_plug) do
      nil -> []
      plug -> [plug: plug]
    end
  end
end
