defmodule VmuCoreWeb.OidcSessionController do
  @moduledoc """
  OIDC login start/callback (Way4 parity plan Phase 0 item 6, 2026-07-24)
  — the SSO counterpart to `OperatorSessionController`. Establishes the
  exact same plain-session shape `OperatorSessionController.create/2`
  does (`operator_id`/`logged_in_at` under the Plug session cookie) on
  success, so every downstream piece (`OperatorAuth` plug, LiveView
  mounts) is unaware which path a given session came from.
  """

  use Phoenix.Controller, formats: [:html]
  import Plug.Conn

  alias VmuCore.ASM.{Auth, OidcConfig, OidcClient}

  @admin_path "/visionplus/admin"
  @login_path "/visionplus/admin/login"

  @doc "GET /visionplus/admin/auth/oidc/start"
  def start(conn, _params) do
    case OidcConfig.resolve() do
      {:ok, cfg} ->
        state = random_token()
        nonce = random_token()

        conn
        |> put_session("oidc_state", state)
        |> put_session("oidc_nonce", nonce)
        |> redirect(external: OidcClient.authorization_url(cfg, state, nonce))

      {:error, _reason} ->
        conn
        |> put_session("login_error", "SSO is not configured for this deployment.")
        |> redirect(to: @login_path)
    end
  end

  @doc "GET /visionplus/admin/auth/oidc/callback"
  def callback(conn, %{"code" => code, "state" => state}) do
    expected_state = get_session(conn, "oidc_state")
    expected_nonce = get_session(conn, "oidc_nonce")

    conn = conn |> delete_session("oidc_state") |> delete_session("oidc_nonce")

    if is_nil(expected_state) or state != expected_state do
      fail(conn, "SSO login failed — session expired or invalid state, please try again.")
    else
      with {:ok, cfg} <- OidcConfig.resolve(),
           {:ok, id_token} <- OidcClient.exchange_code(cfg, code),
           {:ok, claims} <- OidcClient.verify_id_token(cfg, id_token, expected_nonce),
           username when is_binary(username) <- claims[cfg.username_claim] do
        finish(conn, username)
      else
        _ -> fail(conn, "SSO login failed — could not verify the identity provider's response.")
      end
    end
  end

  def callback(conn, %{"error" => error}) do
    fail(conn, "SSO login was not completed (#{error}).")
  end

  def callback(conn, _params) do
    fail(conn, "SSO login failed — missing authorization code.")
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp finish(conn, username) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    case Auth.authenticate_sso(username, ip_address: ip) do
      {:ok, operator} ->
        conn
        |> configure_session(renew: true)
        |> put_session("operator_id", operator.operator_id)
        |> put_session("logged_in_at", System.os_time(:second))
        |> redirect(to: @admin_path)

      {:error, :no_matching_operator} ->
        fail(conn, "No VisionPlus operator account matches your SSO identity (#{username}). Contact an administrator.")

      {:error, :locked} ->
        fail(conn, "Account locked after repeated failures — contact an administrator.")

      {:error, :disabled} ->
        fail(conn, "Account disabled — contact an administrator.")
    end
  end

  defp fail(conn, message) do
    conn
    |> put_session("login_error", message)
    |> redirect(to: @login_path)
  end

  defp random_token, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
end
