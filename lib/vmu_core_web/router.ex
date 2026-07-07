defmodule VmuCoreWeb.Router do
  use Phoenix.Router, helpers: false
  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router
  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug VmuCoreWeb.Plugs.InternalApiAuth
  end

  # Internal FAS API — consumed by settlement_core (FAS-P4)
  scope "/api/fas", VmuCoreWeb do
    pipe_through :api

    get  "/auth/lookup",        FasApiController, :auth_lookup
    post "/settlement/confirm", FasApiController, :settlement_confirm
  end

  # Authenticated operator pipeline (ASM-P1) — legacy UI + LiveDashboard
  pipeline :operator do
    plug VmuCoreWeb.OperatorAuth
  end

  scope "/" do
    pipe_through :browser

    # Root → VisionPlus admin UI
    get "/", VmuCoreWeb.RedirectController, :visionplus

    # Operator sign in/out (ASM-P1.3) — MUST precede the /:module live route
    get    "/visionplus/admin/login",  VmuCoreWeb.OperatorSessionController, :new
    post   "/visionplus/admin/login",  VmuCoreWeb.OperatorSessionController, :create
    get    "/visionplus/admin/logout", VmuCoreWeb.OperatorSessionController, :delete

    # VisionPlus hierarchy-based admin UI — operator-gated (ASM-P1.4)
    live_session :admin,
      on_mount: {VmuCoreWeb.OperatorAuth, :require_operator} do
      live "/visionplus/admin",         VmuCoreWeb.Live.Admin.AdminLive
      live "/visionplus/admin/:module", VmuCoreWeb.Live.Admin.AdminLive
    end
  end

  scope "/" do
    pipe_through [:browser, :operator]

    # VisionPlus terminal UI — legacy (command mode + menu)
    live "/visionplus",        VmuCoreWeb.Live.VisionPlusLiveLegacy
    live "/visionplus/legacy", VmuCoreWeb.Live.VisionPlusLiveLegacy

    # LiveDashboard — metrics, accounts overview, operator console
    live_dashboard "/dashboard",
      metrics: VmuCoreWeb.Telemetry,
      ecto_repos: [VmuCore.Repo],
      additional_pages: [
        parameters:  VmuCoreWeb.Pages.ParameterEnginePage,
        accounts:    VmuCoreWeb.Pages.AccountsPage,
        console:     VmuCoreWeb.Pages.OperatorConsolePage
      ]
  end
end
