defmodule VmuCoreWeb.DpsEvidenceController do
  @moduledoc """
  Evidence download for the DPS ops UI (DPS-P5). Plain controller route
  (not a LiveView action) so the browser can trigger a real file download —
  gated by the same `VmuCoreWeb.OperatorAuth` plug + `dps`/`view` permission
  the LiveView admin console uses.
  """

  use Phoenix.Controller, formats: [:html]

  alias VmuCore.Repo
  alias VmuCore.DPS.{DisputeEvidence, Evidence}
  alias VmuCore.ASM.Authz

  def download(conn, %{"id" => id}) do
    operator = conn.assigns[:current_operator]

    cond do
      not Authz.can?(operator, "dps", "view") ->
        conn |> put_status(:forbidden) |> text("Forbidden")

      # Malformed id (not a valid UUID) → clean 404, not a CastError 500 —
      # same posture as the existing /api/v1 controllers.
      match?(:error, Ecto.UUID.cast(id)) ->
        conn |> put_status(:not_found) |> text("Not found")

      true ->
        with %DisputeEvidence{} = evidence <- Repo.get(DisputeEvidence, id),
             {:ok, data} <- Evidence.fetch_data(id) do
          conn
          |> put_resp_content_type(evidence.content_type || "application/octet-stream")
          |> put_resp_header("content-disposition", ~s(attachment; filename="#{evidence.filename}"))
          |> send_resp(200, data)
        else
          nil -> conn |> put_status(:not_found) |> text("Not found")
          {:error, _reason} -> conn |> put_status(:not_found) |> text("Not found")
        end
    end
  end
end
