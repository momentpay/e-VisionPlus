defmodule VmuCoreWeb.RedirectController do
  use Phoenix.Controller, formats: [:html]

  # Root → VisionPlus terminal UI
  def visionplus(conn, _params) do
    redirect(conn, to: "/visionplus")
  end

  def dashboard(conn, _params) do
    redirect(conn, to: "/dashboard")
  end
end
