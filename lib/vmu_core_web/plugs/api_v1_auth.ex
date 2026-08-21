defmodule VmuCoreWeb.Plugs.ApiV1Auth do
  @moduledoc """
  Bearer-token auth for `/api/v1/*` (KYC-P5) — validates the `Authorization:
  Bearer <token>` header against `ASM.ServiceAccounts.authenticate/1` and
  assigns `:service_account` on the conn. Use `require_scope/2` in a
  controller action (or pipe it with an opt) to enforce a specific scope
  beyond "any valid token."
  """

  import Plug.Conn

  alias VmuCore.ASM.ServiceAccounts
  alias VmuCoreWeb.Api.V1.ErrorEnvelope

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         %VmuCore.ASM.ServiceAccount{} = account <- ServiceAccounts.authenticate(token) do
      assign(conn, :service_account, account)
    else
      _ -> ErrorEnvelope.send(conn, 401, "unauthorized", "Missing or invalid API token")
    end
  end

  @doc """
  Enforce that the authenticated service account has `scope`. Call from
  inside a controller action after `ApiV1Auth` has run (so a 401 vs. 403
  distinction is meaningful — no token at all vs. a valid token missing
  the needed grant). Returns a conn with `.halted true` on failure — the
  caller must check `conn.halted` before proceeding, same as any other
  Plug short-circuit.
  """
  @spec require_scope(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def require_scope(conn, scope) do
    if VmuCore.ASM.ServiceAccount.authorized?(conn.assigns.service_account, scope) do
      conn
    else
      ErrorEnvelope.send(conn, 403, "forbidden", "This token doesn't have the \"#{scope}\" scope")
    end
  end
end
