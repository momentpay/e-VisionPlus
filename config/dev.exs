import Config

# Dev-specific overrides go here.
# Database connection is inherited from config.exs defaults.

# ---------------------------------------------------------------------------
# Admin web UI — http://localhost:4001/dashboard
# ---------------------------------------------------------------------------
config :vmu_core, VmuCoreWeb.Endpoint,
  server: true,
  http: [ip: {127, 0, 0, 1}, port: 4001],
  check_origin: false,
  code_reloader: false,
  debug_errors: true,
  secret_key_base: "dev_only_secret_key_base_vmu_core_admin_console_64chars_minimum_required!!"

# Dev pool sizes — keep small so we stay within PostgreSQL's max_connections.
# Default PostgreSQL max_connections is 100; all path dep repos share the same server.
config :vmu_core,    VmuCore.Repo,    pool_size: 3
config :infra_repo,  InfraRepo.Repo,  pool_size: 2

# Livebook node connection:
#   Start the app with a named node so Livebook can attach:
#   iex --name vmu@127.0.0.1 --cookie vmu_secret -S mix
#
# Then in Livebook → Runtime Settings → Attached Node:
#   Node:   vmu@127.0.0.1
#   Cookie: vmu_secret
