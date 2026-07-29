defmodule VmuCore.Kyc.Adapters.OcrHttpAdapterTest do
  @moduledoc """
  `Req.Test` (a real Plug pipeline, not a mock) against the configured
  `:kyc_ocr_http_plug` -- same convention as `VmuCore.ASM.OidcClient`'s own
  tests. KYC-P3 (2026-07-29). See docs/kyc/KYC_Implementation_Tracker.md §7.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Kyc.Adapters.OcrHttpAdapter

  setup do
    tmp_path = Path.join(System.tmp_dir!(), "kyc_ocr_test_#{System.unique_integer([:positive])}.png")
    File.write!(tmp_path, "not a real image, just bytes for the multipart body")
    on_exit(fn -> File.rm(tmp_path) end)
    {:ok, tmp_path: tmp_path}
  end

  test "extract_text/1 posts multipart to /api/detect_text and returns the decoded body", %{tmp_path: tmp_path} do
    Req.Test.stub(OcrHttpAdapter, fn conn ->
      assert conn.request_path == "/api/detect_text"

      Req.Test.json(conn, %{
        "filename" => Path.basename(tmp_path),
        "simplified_text" => %{"groupings" => [], "raw_text" => "JOHN DOE\n784-1990-1234567-1"}
      })
    end)

    assert {:ok, body} = OcrHttpAdapter.extract_text(tmp_path)
    assert body["simplified_text"]["raw_text"] =~ "JOHN DOE"
  end

  test "extract_text/1 returns an error tuple on a non-2xx response", %{tmp_path: tmp_path} do
    Req.Test.stub(OcrHttpAdapter, fn conn ->
      Plug.Conn.send_resp(conn, 500, ~s({"error":"ocr engine unavailable"}))
    end)

    assert {:error, {:http_error, 500, _body}} = OcrHttpAdapter.extract_text(tmp_path)
  end
end
