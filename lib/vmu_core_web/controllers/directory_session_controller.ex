defmodule VmuCoreWeb.DirectorySessionController do
  @moduledoc """
  AD/LDAP directory sign-in (Way4 parity plan Phase 0 item 6, 2026-07-24)
  — the directory counterpart to `OperatorSessionController`/
  `OidcSessionController`. Same plain-session shape on success.
  """

  use Phoenix.Controller, formats: [:html]
  import Plug.Conn

  alias VmuCore.ASM.{Auth, LdapClient, LdapConfig}

  @admin_path "/visionplus/admin"
  @login_path "/visionplus/admin/login"

  @doc "POST /visionplus/admin/login/directory"
  def create(conn, %{"username" => username, "password" => password})
      when username != "" and password != "" do
    with {:ok, cfg} <- LdapConfig.resolve(),
         bind_principal = LdapConfig.bind_principal(cfg, username),
         :ok <- LdapClient.bind(bind_principal, password, cfg) do
      finish(conn, username)
    else
      {:error, :directory_not_enabled} ->
        fail(conn, "Directory sign-in is not configured for this deployment.")

      {:error, :directory_not_configured} ->
        fail(conn, "Directory sign-in is not configured for this deployment.")

      {:error, :directory_unreachable} ->
        fail(conn, "Could not reach the directory server. Try again or contact an administrator.")

      {:error, _reason} ->
        fail(conn, "Invalid directory username or password.")
    end
  end

  def create(conn, _params), do: fail(conn, "Enter your directory username and password.")

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp finish(conn, username) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    case Auth.authenticate_directory(username, ip_address: ip) do
      {:ok, operator} ->
        conn
        |> configure_session(renew: true)
        |> put_session("operator_id", operator.operator_id)
        |> put_session("logged_in_at", System.os_time(:second))
        |> redirect(to: @admin_path)

      {:error, :no_matching_operator} ->
        fail(conn, "No VisionPlus operator account matches your directory identity (#{username}). Contact an administrator.")

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
end
