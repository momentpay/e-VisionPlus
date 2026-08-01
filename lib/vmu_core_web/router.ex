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

  # External API (KYC-P5, 2026-07-29) — bearer-token ASM.ServiceAccount
  # auth, a different trust boundary than :api's internal shared-secret
  # (FAS/settlement_core): external partners (wallet-app, Kosa App, or a
  # genuine third party) with scoped tokens, not another in-umbrella app.
  pipeline :api_v1 do
    plug :accepts, ["json"]
    plug VmuCoreWeb.Plugs.ApiV1Auth
  end

  # Way4 parity plan Phase 0 item 6 (2026-07-24) — dev/test-only mock OIDC
  # provider (see VmuCoreWeb.MockIdp's moduledoc for why: no real
  # corporate IdP is available in this environment, so VmuCore.ASM.
  # OidcClient is exercised against a real, correctly-signed RS256 token
  # flow rather than skipping verification). Compiled out of prod builds
  # entirely — a fake IdP must never exist in a production router.
  if Mix.env() in [:dev, :test] do
    pipeline :mock_idp do
      plug :accepts, ["html", "json"]
    end

    scope "/mock_idp", VmuCoreWeb do
      pipe_through :mock_idp

      get  "/authorize", MockIdpController, :authorize
      post "/token",     MockIdpController, :token
      get  "/jwks",      MockIdpController, :jwks
    end
  end

  # Internal FAS API — consumed by settlement_core (FAS-P4)
  scope "/api/fas", VmuCoreWeb do
    pipe_through :api

    get  "/auth/lookup",        FasApiController, :auth_lookup
    post "/settlement/confirm", FasApiController, :settlement_confirm
  end

  # External KYC API (KYC-P5) — see the :api_v1 pipeline above for the
  # trust-boundary note. Review/approve/reject stays admin-console-only,
  # deliberately no endpoint for it here.
  scope "/api/v1/kyc", VmuCoreWeb.Api.V1 do
    pipe_through :api_v1

    get  "/methods",                 KycController, :list_methods
    post "/requests",                KycController, :create_request
    get  "/requests/:id",            KycController, :show_request
    post "/requests/:id/documents",  KycController, :upload_document
  end

  # External wallet-out payment API (A2A/Instant Payments, Digital Wallet
  # Phase W6, 2026-07-29) — see the :api_v1 pipeline above for the
  # trust-boundary note. Which rail actually moves money is still an
  # external vendor decision (CMS.RailProvider); this contract exists
  # regardless of that.
  scope "/api/v1/wallet", VmuCoreWeb.Api.V1 do
    pipe_through :api_v1

    post "/payments",     ExternalPaymentController, :create
    get  "/payments/:id", ExternalPaymentController, :show
  end

  # Cardholder-identity API (CAM Phase F1, 2026-08-02) — composes on top of
  # :api_v1 (still proves "this is Kosa app") with CardholderAuth (proves
  # "acting as this specific customer", via a separate X-Customer-Token
  # header). See CardholderAuth's moduledoc for why this is additive, not
  # a replacement pipeline.
  pipeline :api_v1_cardholder do
    plug :accepts, ["json"]
    plug VmuCoreWeb.Plugs.ApiV1Auth
    plug VmuCoreWeb.Plugs.CardholderAuth
  end

  # Cardholder login (CAM Phase F1) — no cardholder token exists yet at
  # this point, so plain :api_v1 (app-level only), not :api_v1_cardholder.
  scope "/api/v1/customer/auth", VmuCoreWeb.Api.V1.Customer do
    pipe_through :api_v1

    post "/request_otp", AuthController, :request_otp
    post "/verify_otp",  AuthController, :verify_otp
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

    # SSO (Way4 parity plan Phase 0 item 6, 2026-07-24)
    get  "/visionplus/admin/auth/oidc/start",    VmuCoreWeb.OidcSessionController, :start
    get  "/visionplus/admin/auth/oidc/callback", VmuCoreWeb.OidcSessionController, :callback

    # AD/LDAP directory sign-in (same item)
    post "/visionplus/admin/login/directory", VmuCoreWeb.DirectorySessionController, :create

    # VisionPlus hierarchy-based admin UI — operator-gated (ASM-P1.4)
    live_session :admin,
      on_mount: {VmuCoreWeb.OperatorAuth, :require_operator} do
      live "/visionplus/admin",         VmuCoreWeb.Live.Admin.AdminLive
      live "/visionplus/admin/:module", VmuCoreWeb.Live.Admin.AdminLive
    end
  end

  scope "/" do
    pipe_through [:browser, :operator]

    # DPS evidence download (DPS-P5) — plain controller route so the browser
    # can trigger a real file download; not expressible as a LiveView action.
    get "/visionplus/admin/dps/evidence/:id/download", VmuCoreWeb.DpsEvidenceController, :download
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
