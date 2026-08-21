defmodule VmuCoreWeb.NtsCallbackController do
  @moduledoc """
  Public inbound callback the Token Requestor redirects the cardholder's
  browser to after tokenization completes — NTS Phase F2 (2026-08-02),
  Cases 1/3/5. Under the plain `:browser` pipeline (same precedent as
  `OidcSessionController`'s `/callback` route) — Phoenix's
  `protect_from_forgery` only guards unsafe HTTP methods, so this GET
  route needs no separate public pipeline.

  There is no MDES-defined inbound signature/auth scheme for this
  redirect (unlike a real webhook) — the Token Requestor is trusted by
  virtue of holding the one-time `session_id` in the URL, matching the
  `pushAccountReceipt` we already gave them. See `PushProvisioningSessions.
  complete/2`'s moduledoc caveat on the result-param shape being
  best-effort, not a confirmed per-TR contract.
  """

  use Phoenix.Controller, formats: [:html]

  alias VmuCore.NTS.PushProvisioningSessions

  @doc "GET /nts/callback/:session_id"
  def show(conn, %{"session_id" => session_id} = params) do
    kosa_base = Application.get_env(:vmu_core, :nts, [])[:kosa_app_base_url]

    case PushProvisioningSessions.complete(session_id, params) do
      {:ok, session} ->
        redirect(conn, external: "#{kosa_base}/nts/result?session_id=#{session_id}&status=#{session.status}")

      {:error, :not_found} ->
        redirect(conn, external: "#{kosa_base}/nts/result?status=UNKNOWN_SESSION")
    end
  end
end
