defmodule VmuCore.Kyc.Adapters.OcrHttpAdapter do
  @moduledoc """
  Real OCR adapter — the local OCR server the user confirmed is already
  running (`docs/kyc/KYC_Implementation_Tracker.md` §7, confirmed 2026-07-29,
  same server the July-14 design tracker referenced):

      POST http://localhost:4000/api/detect_text
        -F "image=@<file>" [-F "model_type=tesseract_ocr|paddle_ocr|keras_ocr"]
        -> 200 %{filename:, simplified_text: %{groupings:, raw_text:}}

  Test-time faking uses `Req.Test` (a real Plug pipeline, not a mock) — same
  convention as `CMS.NotificationDispatcher.HttpGateway`: `config/test.exs`
  sets `:vmu_core, :kyc_ocr_http_plug` to `{Req.Test, __MODULE__}`, tests call
  `Req.Test.stub(VmuCore.Kyc.Adapters.OcrHttpAdapter, fun)`. Unset in dev/prod,
  so requests go out over real HTTP.
  """

  @behaviour VmuCore.Kyc.ProviderAdapter

  require Logger

  @impl true
  @spec extract_text(String.t()) :: {:ok, map()} | {:error, term()}
  def extract_text(path) do
    image = {File.read!(path), filename: Path.basename(path), content_type: "application/octet-stream"}

    req_opts =
      [
        url: base_url() <> "/api/detect_text",
        form_multipart: [image: image, model_type: "tesseract_ocr"],
        receive_timeout: 15_000
      ]
      |> Keyword.merge(plug_opts())

    case Req.post(req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("[Kyc.OcrHttpAdapter] non-2xx status=#{status}")
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.warning("[Kyc.OcrHttpAdapter] request failed reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  @spec validate_field(map(), term()) :: {:error, :not_implemented}
  def validate_field(_field, _value), do: {:error, :not_implemented}

  defp base_url, do: Application.get_env(:vmu_core, :kyc_ocr_base_url, "http://localhost:4000")

  defp plug_opts do
    case Application.get_env(:vmu_core, :kyc_ocr_http_plug) do
      nil -> []
      plug -> [plug: plug]
    end
  end
end
