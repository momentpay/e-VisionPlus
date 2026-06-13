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

config :vmu_core, Oban,
  repo: VmuCore.Repo,
  plugins: [Oban.Plugins.Pruner],
  queues: [
    eod:      10,   # EOD billing jobs (sequential within account)
    cta:      5,    # Card issuance, embossing
    disputes: 5,    # DPS deadline-sensitive jobs
    clearing: 10,   # TRAMS IPM/Base II processing
    collections: 3, # COL dunning, write-off
    default:  5
  ]

import_config "#{config_env()}.exs"
