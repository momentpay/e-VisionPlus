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
# `InfraRepo.Repo` is hardcoded `adapter: Ecto.Adapters.MyXQL` in mw-core's own
# `apps/infra_repo/lib/infra_repo/repo.ex` — it always speaks the MySQL wire
# protocol, regardless of what's configured here. The previous config pointed
# it at vmu_core_dev on port 5432 with Postgres credentials — a MySQL client
# aimed at a Postgres-speaking port, which could never connect (confirmed live
# 2026-07-23: every boot logged "MyXQL.Client ... timed out because it was
# handshaking" / "socket closed", and `SanctionsCache`/`RuleCache`/
# `SuppressionsCache` all silently degraded to empty via their own `rescue`
# clauses — not because "infra tables are absent" as this comment previously,
# incorrectly, assumed). Corrected to mw-core's own real MySQL dev database
# (`mw_core_dev`, confirmed listening on 127.0.0.1:3306, real `risk_sanctions_list`
# data loaded 2026-07-23) so the FAS gateway pipeline and CDM's
# `SanctionsScreening` (see `docs/cdm/CDM_Gap_Implementation_Tracker.md`
# CDM-P2) actually reach real data instead of silently no-op'ing.
# Omitting :infra_repo Oban config → InfraRepo.Application skips Oban startup.
config :infra_repo, InfraRepo.Repo,
  database: "mw_core_dev",
  username: "root",
  password: "",
  hostname: "localhost",
  port: 3306,
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
       {"0 4 * * *", VmuCore.CTA.Oban.CardExpirySweepJob},
       # ASM operator audit retention sweep — weekly, Sunday 03:00 (after the
       # TRAMS archive sweep at 02:00)
       {"0 3 * * 0", VmuCore.ASM.Oban.AuditRetentionSweepJob},
       # LMS warehouse-release sweep — daily, 23:45 (after PointsCalculationJob's
       # 23:30 earn run, so same-day earns are eligible for release the moment
       # their warehouse_days window elapses, not a full day later)
       {"45 23 * * *", VmuCore.LMS.Oban.WarehouseReleaseJob},
       # LMS points expiry sweep — found unscheduled anywhere despite its own
       # moduledoc claiming "runs on the 1st of each month"; fixed alongside
       # the warehouse-release job (same class of gap)
       {"0 1 1 * *", VmuCore.LMS.Oban.PointsExpiryJob},
       # Prepaid stored-value expiry sweep (Way4 parity plan Phase 1 item
       # 5, P5) — daily, 04:30 (after CardExpirySweepJob at 04:00)
       {"30 4 * * *", VmuCore.CMS.Oban.PrepaidExpiryJob}
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

# ---------------------------------------------------------------------------
# DPS.NetworkAdapter.Mastercom (re-ported 2026-07-29 from Avenza/apps/vmu_dps)
# — the consumer_key already lives in this project's own .env
# (MASTERCARDCOM_Consumerkey), confirmed by the user (2026-07-30) as the
# same Mastercard Developer registration MDES tokenization will also use.
# private_key_path is genuinely unset — MastercomClient fails closed with
# {:error, :missing_private_key} until one is supplied, on purpose.
# ---------------------------------------------------------------------------
config :vmu_core, :mastercom,
  consumer_key: System.get_env("MASTERCARDCOM_Consumerkey"),
  private_key_path: System.get_env("MASTERCOM_PRIVATE_KEY_PATH", "docs/nts/myrsa.key"),
  base_url: System.get_env("MASTERCOM_BASE_URL", "https://sandbox.api.mastercard.com/mastercom/v6")

# ---------------------------------------------------------------------------
# NTS.MastercardMdesClient (NTS Phase B, 2026-07-31) — MDES Token Connect.
# Same Mastercard Developer registration as :mastercom above (confirmed by
# the user), so the same consumer_key/private_key_path. cert_path is
# MDES's own public field-level-encryption certificate, used by
# NTS.MastercardPayloadEncryption for pushMultipleAccounts' request body.
# google_pay_token_requestor_id stays unset until a real one is known —
# MastercardMdes falls back to discovering it live otherwise.
# ---------------------------------------------------------------------------
config :vmu_core, :mdes,
  consumer_key: System.get_env("MASTERCARDCOM_Consumerkey"),
  private_key_path: System.get_env("MDES_PRIVATE_KEY_PATH", "docs/nts/myrsa.key"),
  cert_path: System.get_env(
    "MDES_CERT_PATH",
    "docs/wallet/mdes-token-connect-clientenc1785255654516-sandbox-client-encryption-key.pem"
  ),
  base_url: System.get_env("MDES_BASE_URL", "https://sandbox.api.mastercard.com/mdes"),
  google_pay_token_requestor_id: System.get_env("MDES_GOOGLE_PAY_TRID")

# ---------------------------------------------------------------------------
# CAM.CustomerSession (Cardholder Access, NTS Phase F1, 2026-08-02) — HS256
# signing key for cardholder session tokens. The fallback is a fixed
# dev-only string, never suitable for a real environment — set
# CAM_SESSION_SIGNING_KEY in prod/staging.
# ---------------------------------------------------------------------------
config :vmu_core, :cam,
  session_signing_key: System.get_env("CAM_SESSION_SIGNING_KEY", "dev-only-insecure-cam-signing-key-do-not-use-in-prod")

# ---------------------------------------------------------------------------
# NTS.PushProvisioningSessions (NTS Phase F2, 2026-08-02) — callback_base_url
# is this app's own publicly-reachable base URL, prepended to
# `/nts/callback/:session_id` and sent to MDES as `signatureData.
# callbackURL` for Cases 1/3/5's browser-redirect flows. Also where a Kosa
# web build lives for the confirmation-screen redirect target.
# ---------------------------------------------------------------------------
config :vmu_core, :nts,
  callback_base_url: System.get_env("NTS_CALLBACK_BASE_URL", "http://localhost:4001"),
  kosa_app_base_url: System.get_env("KOSA_APP_BASE_URL", "http://localhost:5000")

import_config "#{config_env()}.exs"
