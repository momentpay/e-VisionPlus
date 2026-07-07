defmodule VmuCoreWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :vmu_core

  @session_options [
    store: :cookie,
    key: "_vmu_core_admin",
    signing_salt: "vmu_admin_lv",
    same_site: "Lax"
  ]

  # LiveView websocket — used by LiveDashboard real-time updates
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  # Serve JS assets (phoenix.js, phoenix_live_view.js) needed by LiveView
  plug Plug.Static,
    at: "/",
    from: :vmu_core,
    gzip: false,
    only: ~w(assets)

  # LiveDashboard request logger (shows request details on the dashboard)
  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug VmuCoreWeb.Router
end
