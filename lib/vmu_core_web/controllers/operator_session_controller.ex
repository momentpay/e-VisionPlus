defmodule VmuCoreWeb.OperatorSessionController do
  @moduledoc """
  Operator login/logout (ASM-P1.3).

  A plain controller (not LiveView) because only the Plug pipeline can write
  the session cookie. Renders its own minimal HTML — consistent with the
  admin UI's no-asset-pipeline, self-contained-page approach.
  """

  use Phoenix.Controller, formats: [:html]
  import Plug.Conn

  alias VmuCore.ASM.{Auth, LdapConfig, OidcConfig}

  @admin_path "/visionplus/admin"

  def new(conn, _params) do
    if get_session(conn, "operator_id") && Auth.get_active_operator(get_session(conn, "operator_id")) do
      redirect(conn, to: @admin_path)
    else
      error = get_session(conn, "login_error")
      conn = if error, do: delete_session(conn, "login_error"), else: conn
      html(conn, login_page(conn, error))
    end
  end

  def create(conn, %{"username" => username, "password" => password}) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    case Auth.authenticate(username, password, ip_address: ip) do
      {:ok, operator} ->
        conn
        |> configure_session(renew: true)
        |> put_session("operator_id", operator.operator_id)
        |> put_session("logged_in_at", System.os_time(:second))
        |> redirect(to: @admin_path)

      {:error, :locked} ->
        html(conn, login_page(conn, "Account locked after repeated failures — contact an administrator."))

      {:error, :disabled} ->
        html(conn, login_page(conn, "Account disabled — contact an administrator."))

      {:error, :invalid_credentials} ->
        html(conn, login_page(conn, "Invalid username or password."))
    end
  end

  def create(conn, _params), do: html(conn, login_page(conn, "Enter username and password."))

  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: "/visionplus/admin/login")
  end

  # ---------------------------------------------------------------------------
  # Inline login page
  # ---------------------------------------------------------------------------

  defp login_page(_conn, error) do
    csrf = Plug.CSRFProtection.get_csrf_token()

    error_html =
      if error do
        ~s(<div class="login-error">#{Plug.HTML.html_escape(error)}</div>)
      else
        ""
      end

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8"/>
      <meta name="viewport" content="width=device-width, initial-scale=1"/>
      <title>VisionPlus Admin — Sign In</title>
      <link rel="stylesheet" href="/assets/admin.css"/>
      <style>
        .login-wrap { min-height: 100vh; display: flex; align-items: center; justify-content: center; }
        .login-card { width: 340px; padding: 2rem; border: 1px solid #2a2f3a; border-radius: 8px; }
        .login-card h1 { margin: 0 0 0.25rem; font-size: 1.3rem; }
        .login-card .tag { color: #8a90a0; font-size: 0.85rem; margin-bottom: 1.25rem; }
        .login-card label { display: block; margin: 0.75rem 0 0.25rem; font-size: 0.85rem; }
        .login-card input { width: 100%; padding: 0.5rem; box-sizing: border-box; }
        .login-card button { margin-top: 1.25rem; width: 100%; padding: 0.6rem; cursor: pointer; }
        .login-error { margin-bottom: 0.75rem; padding: 0.5rem 0.75rem; border: 1px solid #a33;
                       border-radius: 4px; color: #e88; font-size: 0.85rem; }
        .login-alt { margin-top: 1.25rem; padding-top: 1rem; border-top: 1px solid #2a2f3a; }
        .login-alt a, .login-alt summary { color: #8a90a0; font-size: 0.85rem; cursor: pointer; }
        .login-alt form { margin-top: 0.75rem; }
      </style>
    </head>
    <body>
      <div class="login-wrap">
        <div class="login-card">
          <h1>VisionPlus</h1>
          <div class="tag">Admin Console — Operator Sign In</div>
          #{error_html}
          <form method="post" action="/visionplus/admin/login">
            <input type="hidden" name="_csrf_token" value="#{csrf}"/>
            <label for="username">Username</label>
            <input type="text" id="username" name="username" autocomplete="username" autofocus/>
            <label for="password">Password</label>
            <input type="password" id="password" name="password" autocomplete="current-password"/>
            <button type="submit">Sign In</button>
          </form>
          #{sso_link_html()}
          #{directory_form_html(csrf)}
        </div>
      </div>
    </body>
    </html>
    """
  end

  # Shown only when SSO is actually enabled+configured — a broken/dead
  # link for a bank that hasn't set it up would be worse than no link.
  defp sso_link_html do
    case OidcConfig.resolve() do
      {:ok, _cfg} ->
        ~s(<div class="login-alt"><a href="/visionplus/admin/auth/oidc/start">Sign in with SSO</a></div>)

      {:error, _} ->
        ""
    end
  end

  defp directory_form_html(csrf) do
    case LdapConfig.resolve() do
      {:ok, _cfg} ->
        """
        <div class="login-alt">
          <details>
            <summary>Sign in with directory (AD/LDAP) credentials</summary>
            <form method="post" action="/visionplus/admin/login/directory">
              <input type="hidden" name="_csrf_token" value="#{csrf}"/>
              <label for="ldap_username">Directory username</label>
              <input type="text" id="ldap_username" name="username" autocomplete="username"/>
              <label for="ldap_password">Directory password</label>
              <input type="password" id="ldap_password" name="password" autocomplete="current-password"/>
              <button type="submit">Sign In via Directory</button>
            </form>
          </details>
        </div>
        """

      {:error, _} ->
        ""
    end
  end
end
