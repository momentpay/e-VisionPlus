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
