defmodule VmuCore.CMS.NotificationDispatcher.HttpGateway do
  @moduledoc """
  Shared HTTP POST used by every real `VmuCore.CMS.NotificationDispatcher`
  channel adapter — a bank-configured gateway URL receives a JSON body of
  `%{content, content_format, channel, priority, recipient, event_type, reference}`
  and is responsible for actual delivery.

  Test-time faking uses `Req.Test` (a real Plug pipeline, not a mock) —
  `config/test.exs` sets `:vmu_core, :notification_http_plug` to
  `{Req.Test, VmuCore.CMS.NotificationDispatcher.HttpGateway}`; tests then
  call `Req.Test.stub(VmuCore.CMS.NotificationDispatcher.HttpGateway, fun)`.
  In dev/prod this config key is unset, so requests go out over real HTTP.
  """

  require Logger

  @doc """
  POSTs `body` (a map) to `config["url"]` with `config["headers"]` merged
  in. Returns `{:error, :no_url}` if the channel isn't configured yet —
  the caller (`VmuCore.CMS.Notification`) treats that as `SKIPPED`, not a
  real failure.
  """
  @spec post(map(), map()) :: {:ok, term()} | {:error, term()}
  def post(%{"url" => url} = config, body) when is_binary(url) and url != "" do
    headers = Map.get(config, "headers", %{}) |> Enum.into([])

    opts =
      [url: url, json: body, headers: headers, receive_timeout: 5_000]
      |> Keyword.merge(plug_opts())

    case Req.post(opts) do
      {:ok, %Req.Response{status: status, body: resp_body}} when status in 200..299 ->
        {:ok, resp_body}

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        Logger.warning("[NotificationDispatcher.HttpGateway] non-2xx status=#{status} url=#{url}")
        {:error, {:http_error, status, resp_body}}

      {:error, reason} ->
        Logger.warning("[NotificationDispatcher.HttpGateway] request failed url=#{url} reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  def post(_config, _body), do: {:error, :no_url}

  defp plug_opts do
    case Application.get_env(:vmu_core, :notification_http_plug) do
      nil -> []
      plug -> [plug: plug]
    end
  end
end
