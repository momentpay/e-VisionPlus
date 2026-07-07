defmodule VmuCoreWeb.Plugs.InternalApiAuth do
  @moduledoc """
  Verifies the `x-vmu-api-key` header on internal API calls from settlement_core.
  Configured via `config :vmu_core, :internal_api_key`.
  Returns 401 on missing or wrong key; passes through otherwise.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    expected = Application.get_env(:vmu_core, :internal_api_key)

    provided =
      case get_req_header(conn, "x-vmu-api-key") do
        [key | _] -> key
        []        -> nil
      end

    # Passthrough when no key is configured (dev/test); enforce in prod.
    if is_nil(expected) or provided == expected do
      conn
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "unauthorized"})
      |> halt()
    end
  end
end
