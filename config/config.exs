import Config

config :vmu_core,
  ecto_repos: [VmuCore.Repo]

config :vmu_core, VmuCore.Repo,
  database: "vmu_core_dev",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5432,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

import_config "#{config_env()}.exs"
