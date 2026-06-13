defmodule VmuCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :vmu_core,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {VmuCore.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # --- Core Database & JSON Support ---
      {:ecto_sql, "~> 3.11"},
      {:postgrex, ">= 0.0.0"},
      {:jason, "~> 1.4"},

      # --- Distributed Process Registry ---
      {:horde, "~> 0.9"},
      {:libcluster, "~> 3.3"},

      # --- Standalone Switch ---
      {:da_product_app, path: "../muNSwitch", override: true},

      # --- Settlement Core (tmsuat_apps-main) ---
      {:settlement_core, path: "../tmsuat_apps-main/apps/settlement_core", override: true},
      {:platform_core, path: "../tmsuat_apps-main/apps/platform_core", override: true},

      # --- Cards & GL (wallet-app) ---
      {:wallet_cards, path: "../wallet-app/apps/wallet_cards", override: true},
      {:wallet_gl, path: "../wallet-app/apps/wallet_gl", override: true},
      {:wallet_shared_kernel, path: "../wallet-app/apps/wallet_shared_kernel", override: true},
      {:wallet_observability, path: "../wallet-app/apps/wallet_observability", override: true},
      {:wallet_events, path: "../wallet-app/apps/wallet_events", override: true},
      {:wallet_database, path: "../wallet-app/apps/wallet_database", override: true},

      # --- Risk Engine (mw-core) ---
      {:mw_risk, path: "../mw-core/apps/mw_risk", override: true},
      {:mw_kernel, path: "../mw-core/apps/mw_kernel", override: true},
      {:infra_repo, path: "../mw-core/apps/infra_repo", override: true},
      {:infra_feature_store, path: "../mw-core/apps/infra_feature_store", override: true}
    ]
  end
end
