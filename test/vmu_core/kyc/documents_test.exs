defmodule VmuCore.Kyc.DocumentsTest do
  @moduledoc """
  Real Postgres via Sandbox + real disk I/O + Req.Test-stubbed OCR, no
  mocking. KYC-P3 (2026-07-29) -- upload/OCR/annotation.
  See docs/kyc/KYC_Implementation_Tracker.md §7.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.Kyc.{Methods, Requests, Documents, Document}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias VmuCore.Kyc.Adapters.OcrHttpAdapter

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    tmp_path = Path.join(System.tmp_dir!(), "kyc_doc_test_#{System.unique_integer([:positive])}.jpg")
    File.write!(tmp_path, "fake image bytes")
    on_exit(fn -> File.rm(tmp_path) end)

    {:ok, tmp_path: tmp_path}
  end

  defp parameter_hierarchy_fixture do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "606060", description: "test"}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    {sys_id, bank_id}
  end

  defp request_fixture do
    {sys_id, bank_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Doc", last_name: "Test#{n}"})
      |> Repo.insert!()

    {:ok, method} =
      Methods.create(%{
        "name" => "Doc Method #{n}", "title" => "Doc Method", "product_type" => "DEBIT", "status" => "active",
        "fields" => [%{"key" => "id_doc", "label" => "ID Document", "type" => "file", "required" => true, "options" => []}]
      })

    {:ok, request} = Requests.submit(method, %{"customer_id" => customer.customer_id, "data" => %{}})
    request
  end

  test "upload/3 stores the file on disk and runs OCR", %{tmp_path: tmp_path} do
    request = request_fixture()

    Req.Test.stub(OcrHttpAdapter, fn conn ->
      Req.Test.json(conn, %{"simplified_text" => %{"raw_text" => "784-1990-1234567-1"}})
    end)

    assert {:ok, document} =
             Documents.upload(request.request_id, "id_doc", %{
               filename: "emirates_id.jpg",
               content_type: "image/jpeg",
               tmp_path: tmp_path
             })

    assert document.field_key == "id_doc"
    assert document.original_filename == "emirates_id.jpg"
    assert File.exists?(document.storage_path)
    assert File.read!(document.storage_path) == "fake image bytes"
    assert document.ocr_result["simplified_text"]["raw_text"] == "784-1990-1234567-1"
  end

  test "upload/3 still stores the document even when OCR fails", %{tmp_path: tmp_path} do
    request = request_fixture()

    Req.Test.stub(OcrHttpAdapter, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)

    assert {:ok, document} =
             Documents.upload(request.request_id, "id_doc", %{filename: "x.jpg", content_type: "image/jpeg", tmp_path: tmp_path})

    assert document.ocr_result == nil
    assert File.exists?(document.storage_path)
  end

  test "list_for_request/1 returns uploaded documents" do
    request = request_fixture()
    tmp = Path.join(System.tmp_dir!(), "kyc_doc_list_#{System.unique_integer([:positive])}.jpg")
    File.write!(tmp, "x")
    Req.Test.stub(OcrHttpAdapter, fn conn -> Req.Test.json(conn, %{}) end)

    {:ok, _doc} = Documents.upload(request.request_id, "id_doc", %{filename: "a.jpg", content_type: "image/jpeg", tmp_path: tmp})

    [doc] = Documents.list_for_request(request.request_id)
    assert doc.field_key == "id_doc"
    File.rm(tmp)
  end

  describe "annotate/4" do
    test "records a comment/approval/rejection mark on a document", %{tmp_path: tmp_path} do
      request = request_fixture()
      Req.Test.stub(OcrHttpAdapter, fn conn -> Req.Test.json(conn, %{}) end)

      {:ok, document} =
        Documents.upload(request.request_id, "id_doc", %{filename: "a.jpg", content_type: "image/jpeg", tmp_path: tmp_path})

      operator_id = "00000000-0000-0000-0000-000000000001"
      assert {:ok, annotation} = Documents.annotate(document.document_id, "approval", "looks legitimate", operator_id)
      assert annotation.type == "approval"

      [reloaded] = Documents.list_annotations(document.document_id)
      assert reloaded.content == "looks legitimate"
      assert reloaded.created_by == operator_id
    end

    test "rejects an unknown annotation type" do
      assert {:error, changeset} = Documents.annotate(Ecto.UUID.generate(), "not_a_real_type", "x", Ecto.UUID.generate())
      refute changeset.valid?
    end
  end
end
