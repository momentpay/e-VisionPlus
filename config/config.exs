import Config

config :vmu_core,
  ecto_repos: [VmuCore.Repo]

# ---------------------------------------------------------------------------
# Admin web UI — LiveDashboard (port configured per env in dev.exs / prod.exs)
# ---------------------------------------------------------------------------
config :vmu_core, VmuCoreWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [formats: [html: VmuCoreWeb.ErrorHTML], layout: false],
  pubsub_server: VmuCore.PubSub,
  live_view: [signing_salt: "vmu_lv_admin_salt"]

config :vmu_core, VmuCore.Repo,
  database: "vmu_core_dev",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5432,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# ---------------------------------------------------------------------------
# muNSwitch path deps (da_switch_core + da_issuer) — config lives here because
# path-dep config files are NOT loaded in the root app's config context.
#
# da_issuer's Ranch listeners (MIP 7585 / VAP 8600) replace vmu_core's own
# retired FAS TCP listener (was port 9100) — see Phase 6 of muNSwitch's
# UMBRELLA_TRACKER.md. da_issuer starts automatically as an OTP dependency
# app; no manual start call is needed (compare VmuCore.FAS.Listener.start(),
# removed from application.ex).
# ---------------------------------------------------------------------------
config :da_switch_core, :fas_authorizer, VmuCore.FAS.Authorization

config :da_issuer, :issuer_listeners, [
  %{
    id: :mastercard_mip_listener,
    port: 7585,
    protocol: DaIssuer.Protocol,
    # NetworkPackagers.MasterCardPackager has a pre-existing pack/1-unpack/1
    # arity bug (see muNSwitch config/issuer_listeners.exs) — same placeholder
    # workaround used there.
    packager: DaSwitchCore.Packagers.ISO87BPackager,
    max_connections: 50,
    name: "Mastercard MIP Listener"
  },
  %{
    id: :visa_vap_listener,
    port: 8600,
    protocol: DaIssuer.Protocol,
    packager: DaSwitchCore.Packagers.ISO87BPackager,
    max_connections: 50,
    name: "Visa VAP Listener"
  }
]

# ---------------------------------------------------------------------------
# wallet-app + mw-core path deps — config must live here, not in the dep
# ---------------------------------------------------------------------------

# WalletDatabase.Repo is not needed in vmu_core — vmu_core manages cards via
# its own CMS schemas. Skipping the repo avoids the missing :database error.
config :wallet_database, :start_repo, false

# mw_risk's RuleCache/SuppressionsCache/ActivationWatcher only support integer
# tenant_id (see VmuCore.FAS.RiskAdapter.resolve_tenant_id/1) — map each alpha
# `sys_id` from priv/repo/seeds.exs to a stable integer so its risk rules stay
# isolated from other tenants instead of collapsing to tenant_id 0.
config :vmu_core, :mw_risk_tenant_ids, %{
  "MMPD" => 1,
  "MMRW" => 2
}

# InfraRepo.Repo backs the mw_risk scoring pipeline (fail-safe: errors → approve).
# Point to vmu_core_dev so the connection pool starts; infra tables are absent
# but MwRisk.Pipeline handles all errors gracefully.
# Omitting :infra_repo Oban config → InfraRepo.Application skips Oban startup.
config :infra_repo, InfraRepo.Repo,
  database: "vmu_core_dev",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5432,
  pool_size: 3

# ASM-P3.2 — per-role approval authority (max amount an approver may sign
# off). ADMIN is unlimited in code; roles absent here have zero authority.
config :vmu_core, :asm_authority_limits, %{
  "SUPERVISOR" => "10000.00",
  "RISK"       => "5000.00",
  "OPS"        => "1000.00"
}

config :vmu_core, Oban,
  repo: VmuCore.Repo,
  plugins: [
    Oban.Plugins.Pruner,
    # EOD scheduler: fires at 21:00 nightly to enqueue LockAccountsJob per due cycle_code
    {Oban.Plugins.Cron,
     crontab: [
       {"0 21 * * *", VmuCore.CMS.EOD.EodSchedulerJob},
       # TRAM posting cycle (TRAM-P3): match clearing records + post CLEARED
       # transactions — 22:30, after the 21:30 IPM file ingest completes
       {"30 22 * * *", VmuCore.TRAMS.Oban.PostingCycleJob},
       # TRAM auth expiry sweep (TRAM-P4): release holds never cleared —
       # 23:00, after the posting cycle consumed any clearing that DID arrive
       {"0 23 * * *", VmuCore.TRAMS.Oban.AuthExpirySweepJob},
       # TRAM close+archive sweep (TRAM-P6): weekly, Sunday 02:00
       {"0 2 * * 0", VmuCore.TRAMS.Oban.ArchiveSweepJob},
       # Autopay collection (CMS-G2.2): 06:00 daily, after EOD statements
       {"0 6 * * *", VmuCore.CMS.Oban.AutopayRunJob},
       # Account lifecycle sweep (CMS-G3): pending closures + dormancy — 05:00
       {"0 5 * * *", VmuCore.CMS.Oban.AccountLifecycleSweepJob},
       # Card expiry + auto-renewal sweep (CTA-P2.4) — 04:00
       {"0 4 * * *", VmuCore.CTA.Oban.CardExpirySweepJob}
     ]}
  ],
  queues: [
    eod:         10,  # EOD billing jobs (sequential within account)
    cta:          5,  # Card issuance, embossing
    disputes:     5,  # DPS deadline-sensitive jobs
    clearing:    10,  # TRAMS IPM/Base II processing
    collections:  3,  # COL dunning, write-off
    lms:          5,  # LMS points calculation, expiry, auto-disbursement
    cdm:          3,  # CDM behavioral rescoring
    hcs:          3,  # HCS payment sweep + consolidated statements
    its:          4,  # ITS1/ITS2 batch, fee settlement, copy request expiry
    default:      5
  ]

import_config "#{config_env()}.exs"
