defmodule VmuCoreWeb.OperatorAuth do
  @moduledoc """
  Operator session enforcement (ASM-P1.4, ADR-A2).

  Two faces, one policy:

  - `on_mount {VmuCoreWeb.OperatorAuth, :require_operator}` — LiveView mount
    hook for the admin `live_session`: revalidates the session's operator
    against the DB on every mount (a DISABLED/LOCKED operator is cut off at
    the next navigation, not at next login), enforces the idle timeout, and
    assigns `:current_operator`.
  - `plug VmuCoreWeb.OperatorAuth` — same checks for non-LiveView routes
    (LiveDashboard, legacy terminal UI).

  Session keys: `"operator_id"`, `"logged_in_at"` (Unix seconds — timeout is
  `config :vmu_core, :operator_session_timeout_minutes`, default 30, measured
  from login; refreshed on each controller pass).
  """

  # No put_flash/redirect imports — Phoenix.LiveView and Phoenix.Controller
  # both export them (ambiguous); each face calls its own qualified version.
  import Plug.Conn

  alias VmuCore.ASM.Auth

  @login_path "/visionplus/admin/login"

  # ---------------------------------------------------------------------------
  # LiveView on_mount hook
  # ---------------------------------------------------------------------------

  def on_mount(:require_operator, _params, session, socket) do
    with operator_id when is_binary(operator_id) <- session["operator_id"],
         false <- expired?(session["logged_in_at"]),
         %{} = operator <- Auth.get_active_operator(operator_id) do
      {:cont, Phoenix.Component.assign(socket, :current_operator, operator)}
    else
      _ ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "Please sign in to access the admin console.")
         |> Phoenix.LiveView.redirect(to: @login_path)}
    end
  end

  # ---------------------------------------------------------------------------
  # Plug (LiveDashboard, legacy terminal, any controller route)
  # ---------------------------------------------------------------------------

  def init(opts), do: opts

  def call(conn, _opts) do
    with operator_id when is_binary(operator_id) <- get_session(conn, "operator_id"),
         false <- expired?(get_session(conn, "logged_in_at")),
         %{} = operator <- Auth.get_active_operator(operator_id) do
      conn
      |> assign(:current_operator, operator)
      |> put_session("logged_in_at", System.os_time(:second))
    else
      _ ->
        conn
        |> Phoenix.Controller.put_flash(:error, "Please sign in to access the admin console.")
        |> Phoenix.Controller.redirect(to: @login_path)
        |> halt()
    end
  end

  # ---------------------------------------------------------------------------
  # Shared
  # ---------------------------------------------------------------------------

  defp expired?(nil), do: true

  defp expired?(logged_in_at) when is_integer(logged_in_at) do
    timeout_min = Application.get_env(:vmu_core, :operator_session_timeout_minutes, 30)
    System.os_time(:second) - logged_in_at > timeout_min * 60
  end

  defp expired?(_), do: true
end
