defmodule VmuCoreWeb.Plugs.CardholderAuth do
  @moduledoc """
  Cardholder-identity auth for `/api/v1/customer/*` (CAM Phase F1,
  2026-08-02) — composes AFTER `ApiV1Auth` in the `:api_v1_cardholder`
  pipeline, not instead of it: `ApiV1Auth` proves "this is the Kosa app"
  (a `ServiceAccount` bearer token), this plug proves "acting as this
  specific customer" (a `CAM.CustomerSession` bearer token in a SEPARATE
  header, `X-Customer-Token`, since `Authorization` is already spent on
  the app-level token).
  """

  import Plug.Conn

  alias VmuCore.CAM.CustomerSession
  alias VmuCoreWeb.Api.V1.ErrorEnvelope

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with [token] <- get_req_header(conn, "x-customer-token"),
         {:ok, customer_id} <- CustomerSession.verify(token) do
      assign(conn, :current_customer_id, customer_id)
    else
      _ -> ErrorEnvelope.send(conn, 401, "unauthorized", "Missing or invalid X-Customer-Token")
    end
  end
end
