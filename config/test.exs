import Config

config :vmu_core, VmuCore.Repo,
  database: "vmu_core_test",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5432,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :vmu_core, Oban, testing: :inline

# Required for any test exercising the admin console's session/cookie
# handling (Plug.Session, LiveView's socket-session handshake) — found live,
# 2026-07-23, building the first LiveView test in this repo (DPS-P5):
# `secret_key_base` was only ever configured in dev.exs, so every such test
# failed identically with "cookie store expects conn.secret_key_base to be
# set," regardless of what the test itself did. Distinct value from dev.exs
# (never share a secret across environments), test-only, not a real secret.
config :vmu_core, VmuCoreWeb.Endpoint,
  secret_key_base: "test_only_secret_key_base_vmu_core_admin_console_64chars_min_req!!"

# FR-070's NotificationDispatcher.HttpGateway posts to a real URL by
# default; in test, route through Req.Test's Plug pipeline instead of real
# network I/O — see that module's moduledoc.
config :vmu_core, :notification_http_plug,
  {Req.Test, VmuCore.CMS.NotificationDispatcher.HttpGateway}

# Same reasoning for VmuCore.ASM.OidcClient's token/jwks HTTP calls (SSO,
# Way4 parity plan Phase 0 item 6).
config :vmu_core, :oidc_http_plug, {Req.Test, VmuCore.ASM.OidcClient}

# Same reasoning for VmuCore.FAS.HSM.ProductionHSM's Veriscent REST calls
# (Way4 parity plan Phase 0 item 7).
config :vmu_core, :veriscent_hsm_http_plug,
  {Req.Test, VmuCore.FAS.HSM.ProductionHSM.HttpClient}

# Same reasoning for VmuCore.Kyc.Adapters.OcrHttpAdapter's local OCR server
# calls (KYC-P3, docs/kyc/KYC_Implementation_Tracker.md §7).
config :vmu_core, :kyc_ocr_http_plug,
  {Req.Test, VmuCore.Kyc.Adapters.OcrHttpAdapter}

# Same reasoning for VmuCore.DPS.NetworkAdapter.MastercomClient's Mastercom
# v6 API calls (DPS-P5, re-ported 2026-07-29 from Avenza/apps/vmu_dps).
config :vmu_core, :mastercom_http_plug,
  {Req.Test, VmuCore.DPS.NetworkAdapter.MastercomClient}

# Same reasoning for VmuCore.NTS.MastercardMdesClient's MDES Token Connect
# calls (NTS Phase B, 2026-07-31).
config :vmu_core, :mdes_http_plug,
  {Req.Test, VmuCore.NTS.MastercardMdesClient}

# No ISO 8583 listeners under test.
#
# `DaIssuer.ListenerSupervisor` binds the Mastercard MIP (7585) and Visa VAP
# (8600) ports from this list. Binding real ports in the test env means the
# suite cannot run while a dev server is up — it fails at boot with
# :eaddrinuse before a single test executes, which is a poor reason to be
# unable to run tests.
#
# The switch's message handling is exercised through the protocol modules
# directly; nothing in the suite needs a live socket.
config :da_issuer, :issuer_listeners, []

# GL Phase C2 — the posting engine must write under test.
#
# Readers have begun migrating onto `GL.LedgerQuery`, which reads
# `journal_entries`. With shadow off, nothing would populate that table and a
# migrated reader would silently return zero in every test — passing tests
# that prove nothing. Enabling it here makes the test environment mirror
# production, where all five products are cut over.
#
# `:allow` because test fixtures post to arbitrary dates that need not fall in
# an open period; the exception is still recorded either way.
config :vmu_core, VmuCore.Posting.Shadow, enabled: true
config :vmu_core, VmuCore.Posting.RuleEngine, on_closed_period: :allow
