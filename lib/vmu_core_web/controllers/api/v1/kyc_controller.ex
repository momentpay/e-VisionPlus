defmodule VmuCoreWeb.Api.V1.KycController do
  @moduledoc """
  External KYC API (KYC-P5, `docs/kyc/KYC_Implementation_Tracker.md` §7) —
  thin HTTP wrappers over the existing `Kyc.Methods`/`Kyc.Requests`/
  `Kyc.Documents` contexts, no new business logic. Confirmed in scope by
  the user ("The KYC process can be external and we need to manage via
  API also some time").

  Review/approve/reject stays admin-console-only, same as every other
  approval flow in this program (COL write-offs, HCS facility-limit
  changes) — no endpoint here does it.

  Every mutating action is audited via `ASM.AuditLog.record/4` (actor
  `nil` — audited as "system" with the calling service account's name in
  `details`; `AuditLog` is typed around a human `Operator`, not worth
  widening for one new caller kind).
  """

  use Phoenix.Controller, formats: [:json]

  alias VmuCore.Kyc.{Methods, Requests, Documents}
  alias VmuCore.ASM.AuditLog
  alias VmuCoreWeb.Plugs.ApiV1Auth
  alias VmuCoreWeb.Api.V1.ErrorEnvelope

  @doc "GET /api/v1/kyc/methods?product_type=X — the active method(s) + field schema for a product."
  def list_methods(conn, params) do
    conn = ApiV1Auth.require_scope(conn, "kyc:read")

    if conn.halted do
      conn
    else
      case params["product_type"] do
        nil ->
          ErrorEnvelope.send(conn, 422, "missing_product_type", "product_type query parameter is required")

        product_type ->
          methods = Methods.list(%{"product_type" => product_type, "status" => "active"})
          json(conn, ErrorEnvelope.ok(%{methods: Enum.map(methods, &method_json/1)}))
      end
    end
  end

  @doc "POST /api/v1/kyc/requests — submit a filled KYC request for an active method."
  def create_request(conn, %{"kyc_method_id" => method_id} = params) do
    conn = ApiV1Auth.require_scope(conn, "kyc:write")

    if conn.halted do
      conn
    else
      case Methods.get(method_id) do
        nil ->
          ErrorEnvelope.send(conn, 404, "method_not_found", "No active KYC method with that id")

        method ->
          attrs = %{"customer_id" => params["customer_id"], "data" => params["data"] || %{}}

          case Requests.submit(method, attrs) do
            {:ok, request} ->
              AuditLog.record(nil, "kyc_api_submit", "kyc_request:#{request.request_id}", %{
                service_account: conn.assigns.service_account.name,
                kyc_method_id: method_id
              })

              conn |> put_status(201) |> json(ErrorEnvelope.ok(%{request: request_json(request)}))

            {:error, :step_locked} ->
              ErrorEnvelope.send(conn, 422, "step_locked", "An earlier required step for this product isn't approved yet")

            {:error, changeset} ->
              ErrorEnvelope.send(conn, 422, "validation_failed", changeset_error_message(changeset))
          end
      end
    end
  end

  def create_request(conn, _params) do
    conn = ApiV1Auth.require_scope(conn, "kyc:write")
    if conn.halted, do: conn, else: ErrorEnvelope.send(conn, 422, "missing_kyc_method_id", "kyc_method_id is required")
  end

  @doc "GET /api/v1/kyc/requests/:id — status check."
  def show_request(conn, %{"id" => id}) do
    conn = ApiV1Auth.require_scope(conn, "kyc:read")

    if conn.halted do
      conn
    else
      case Requests.get(id) do
        nil -> ErrorEnvelope.send(conn, 404, "request_not_found", "No KYC request with that id")
        request -> json(conn, ErrorEnvelope.ok(%{request: request_json(request)}))
      end
    end
  end

  @doc "POST /api/v1/kyc/requests/:id/documents — upload a file for a file-type field; triggers OCR."
  def upload_document(conn, %{"id" => id, "field_key" => field_key, "file" => %Plug.Upload{} = upload}) do
    conn = ApiV1Auth.require_scope(conn, "kyc:write")

    if conn.halted do
      conn
    else
      case Requests.get(id) do
        nil ->
          ErrorEnvelope.send(conn, 404, "request_not_found", "No KYC request with that id")

        _request ->
          case Documents.upload(id, field_key, %{filename: upload.filename, content_type: upload.content_type, tmp_path: upload.path}) do
            {:ok, document} ->
              AuditLog.record(nil, "kyc_api_document_upload", "kyc_request:#{id}", %{
                service_account: conn.assigns.service_account.name,
                field_key: field_key
              })

              conn |> put_status(201) |> json(ErrorEnvelope.ok(%{document: document_json(document)}))

            {:error, changeset} ->
              ErrorEnvelope.send(conn, 422, "validation_failed", changeset_error_message(changeset))
          end
      end
    end
  end

  def upload_document(conn, _params) do
    conn = ApiV1Auth.require_scope(conn, "kyc:write")
    if conn.halted, do: conn, else: ErrorEnvelope.send(conn, 422, "missing_params", "field_key and file are required")
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp method_json(m) do
    %{
      kyc_method_id: m.method_id,
      name: m.name,
      title: m.title,
      product_type: m.product_type,
      step: m.step,
      required: m.required,
      version: m.version,
      fields: m.fields
    }
  end

  defp request_json(r) do
    %{
      request_id: r.request_id,
      application_number: r.application_number,
      product_type: r.product_type,
      step: r.step,
      status: r.status,
      data: r.data,
      decision_reason: r.decision_reason,
      submitted_at: r.submitted_at,
      reviewed_at: r.reviewed_at
    }
  end

  defp document_json(d) do
    %{
      document_id: d.document_id,
      field_key: d.field_key,
      original_filename: d.original_filename,
      ocr_text: get_in(d.ocr_result || %{}, ["simplified_text", "raw_text"])
    }
  end

  defp changeset_error_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
    |> Enum.join("; ")
  end
end
