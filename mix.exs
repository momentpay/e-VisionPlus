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

      # --- Admin Web UI (LiveDashboard on port 4001) ---
      # Versions pinned to match muNSwitch path dep to avoid resolution conflicts.
      {:phoenix, "~> 1.8.0", override: true},
      {:phoenix_live_view, "~> 1.1.0", override: true},
      {:phoenix_live_dashboard, "~> 0.8.6"},
      {:phoenix_pubsub, "~> 2.1", override: true},
      {:phoenix_ecto, "~> 4.5"},
      {:bandit, "~> 1.5", override: true},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},

      # --- Distributed Process Registry ---
      {:horde, "~> 0.9"},
      {:libcluster, "~> 3.3"},

      # --- Background Jobs (EOD workflow, bureau calls, dunning) ---
      {:oban, "~> 2.18"},

      # --- High-throughput clearing pipeline (G7) ---
      {:broadway, "~> 1.1"},

      # --- Standalone Switch ---
      # Protocol/types engine (packagers, MTIConverter, FAS.Authorizer behaviour) plus the
      # issuer-facing Ranch listener (MIP 7585 / VAP 8600). Replaces vmu_core's own redundant
      # listener + hand-rolled ISO 8583 parser (deleted in Phase 6 of muNSwitch's umbrella tracker).
      {:da_switch_core, path: "../muNSwitch/apps/da_switch_core", override: true},
      {:da_issuer, path: "../muNSwitch/apps/da_issuer", override: true},

      # --- Settlement Core (tmsuat_apps-main) ---
      # runtime: false — code reuse only; their OTP apps (Oban, Repo, MQTT) must not start
      # because platform_core hardcodes name: Oban which conflicts with vmu_core's Oban instance.
      {:settlement_core, path: "../tmsuat_apps-main/apps/settlement_core", override: true, runtime: false},
      {:platform_core, path: "../tmsuat_apps-main/apps/platform_core", override: true, runtime: false},

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
