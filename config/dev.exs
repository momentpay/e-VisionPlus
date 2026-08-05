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

# GL Phase B — shadow posting.
#
# When enabled, every `CMS.InternalGlPoster` write is ALSO mirrored through
# `Posting.RuleEngine` into the new GL tables, so the two implementations can
# be diffed on real traffic before anything is cut over. `InternalGlPoster`
# stays authoritative throughout: `Shadow.mirror/1` always returns :ok and can
# never affect the legacy posting.
#
# Watch the results in the admin GL screen -> Shadow Diff tab. Cutover is
# defensible when mismatch and orphan counts are zero over a real sample.
#
# Off here deliberately — turn it on when you want to start collecting.
config :vmu_core, VmuCore.Posting.Shadow,
  enabled: true
  # only_institutions: [{"MMPD", "MMBD"}]   # optional per-institution rollout

# GL Phase C — cutover.
#
# For a product listed here the new posting engine is AUTHORITATIVE: if its
# write fails, the legacy posting is rolled back and the caller gets an error.
# For anything not listed, shadow behaviour is unchanged (failures swallowed).
#
# `cms_ledger_entries` keeps being written either way — twelve modules still
# read it, including the authorization path and the core banking extract.
# Retiring it is a later step.
#
# Empty = nothing cut over. Revert a cutover by removing the string.
#
# WALLET   cut over 2026-08-03 — newest product, lowest volume, no EOD dependency
# PREPAID  cut over 2026-08-04 — closed-loop, no network settlement
# DEBIT    cut over 2026-08-04 — real network settlement via FAS
#
# CREDIT / CREDIT_CARD cut over 2026-08-04, last and deliberately so: they
# carry interest, fees and statements, all of which post from EOD. Gate was a
# full EOD cycle running clean under shadow — AccrueInterest 10/10,
# AgeBuckets 10/10, GenerateStatement 10/10, 6/6 postings matched.
config :vmu_core, VmuCore.Posting.Cutover,
  products: ["WALLET", "PREPAID", "DEBIT", "CREDIT", "CREDIT_CARD"]

# Closed-period policy (Phase C0).
#
# :quarantine — refuse a posting whose gl_date falls in a closed period.
#               Correct end state; what Phase B ran with.
# :allow      — post anyway AND record the exception. Behaviour-preserving
#               against the legacy poster, which accepts back-dated postings
#               silently. Needed while cutting over, so an EOD re-run for a
#               closed day does not start failing.
#
# :allow while cutting over — a cut-over product whose posting the engine
# refuses would otherwise have its legacy row rolled back too, so an EOD
# re-run into a closed period would start failing. Tighten to :quarantine
# once `gl_posting_exceptions` is consistently empty.
config :vmu_core, VmuCore.Posting.RuleEngine,
  on_closed_period: :allow

