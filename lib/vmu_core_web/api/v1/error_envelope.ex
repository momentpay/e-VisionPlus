defmodule VmuCoreWeb.Api.V1.ErrorEnvelope do
  @moduledoc """
  Consistent JSON error shape for `/api/v1/*` (KYC-P5). First real
  implementation of this — a prior doc claimed one already existed;
  verified it didn't (`docs/kyc/KYC_Implementation_Tracker.md` §7).

  `%{error: %{code:, message:}, meta: %{request_id:}}` — `request_id`
  reads `Plug.RequestId`'s value (already in the endpoint pipeline for
  every request, just unused for JSON responses until now).
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @doc "Send a JSON error response with `code`/`message` and halt the pipeline."
  @spec send(Plug.Conn.t(), integer(), String.t(), String.t()) :: Plug.Conn.t()
  def send(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{
      error: %{code: code, message: message},
      meta: %{request_id: request_id()}
    })
    |> halt()
  end

  @doc "Wrap a successful payload with the same `meta.request_id` envelope."
  @spec ok(map()) :: map()
  def ok(data) do
    Map.put(data, :meta, %{request_id: request_id()})
  end

  defp request_id do
    case Logger.metadata()[:request_id] do
      nil -> nil
      id -> id
    end
  end
end
