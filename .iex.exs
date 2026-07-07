# VisionPlus vmu_core — IEx session bootstrap
# Loaded automatically by `iex -S mix` and by Livebook attached sessions.
#
# Usage:
#   iex -S mix                                         # simple (no Livebook)
#   iex --name vmu@127.0.0.1 --cookie vmu_secret -S mix  # Livebook-connectable

import Ecto.Query

alias VmuCore.Repo
alias VmuCore.Shared.{ParameterEngine, Customer, SysParameter, BankParameter,
                      LogoParameter, BlockParameter}
alias VmuCore.CMS.{Account, BalanceBucket, LedgerEntry, AccountStateCoordinator,
                   InternalGlPoster}
alias VmuCore.FAS.{Authorization, STIP}
alias VmuCore.CTA.{CardActivation, PINIssuance, StockInventory}
alias VmuCore.DPS.Dispute
alias VmuCore.TRAMS.ClearingRecord
alias VmuCore.COL.CollectionCase
alias VmuCore.CDM.{ApplicationScorer, LimitAllocator}
alias VmuCore.MBS.{Merchant, Terminal, MdrEngine}
alias VmuCore.LMS.{Scheme, PointsEngine, Enrollment, RedemptionProcessor}
alias VmuCore.HCS.{Company, EmployeeCard, SpendingControl}
alias VmuCore.ITS.{CopyRequest, FeeClaim, FinancialAdjustment}
alias VmuCore.ASM.OperatorPortal
alias VmuCore.IVR.{IvrSession, OtpEngine}

# ---------------------------------------------------------------------------
# Quick helpers — paste these into any expression
# ---------------------------------------------------------------------------

# Operator stubs (pre-built for each role — no need to type the map each time)
agent      = %{id: "OPR-001", role: :agent}
supervisor = %{id: "OPR-002", role: :supervisor}
manager    = %{id: "OPR-003", role: :manager}
sysadmin   = %{id: "OPR-004", role: :sysadmin}

# Test PANs from seeds (raw PAN strings)
pans = %{
  ahmed:    "4072001234560001",   # Standard Visa  — ACTIVE  — OTB 6200
  sara:     "4072001234560002",   # Standard Visa  — ACTIVE  — OTB 4750
  priya:    "4072001234560003",   # Standard Visa  — ACTIVE  — OTB 9800
  mohammad: "4072001234560004",   # Standard Visa  — ACTIVE  — OTB 22000
  jennifer: "4072001234560005",   # Standard Visa  — DELINQUENT 60 DPD
  abdullah: "4072101234560006",   # Corporate Visa — ACTIVE  — OTB 350000
  fiona:    "5240321234560007",   # Platinum MC    — ACTIVE  — OTB 47000
  khalid:   "5240321234560008",   # Platinum MC    — ACTIVE  — OTB 68000
  rashid:   "4072101234560009",   # Corporate Visa — ACTIVE  — OTB 12500
  fatima:   "4072101234560010"    # Corporate Visa — ACTIVE  — OTB 9000
}

# Fire a test authorization in one line:
# auth.(pans.ahmed, "250.00")
auth = fn pan, amount ->
  Authorization.process(%{pan: pan, amount: Decimal.new(amount), channel: :pos, mcc: "5411"})
end

# Lookup account by last_four
acct = fn last4 ->
  Repo.one(from a in Account, where: a.last_four == ^last4, preload: [])
end

IO.puts """
\e[32m
╔══════════════════════════════════════════════════════════╗
║     vMu VisionPlus — IEx Console Ready                  ║
╠══════════════════════════════════════════════════════════╣
║  LiveDashboard  →  http://localhost:4001/dashboard       ║
║                                                          ║
║  Quick commands:                                         ║
║    auth.(pans.ahmed, "100.00")   # run a live auth       ║
║    acct.("0001")                 # lookup Ahmed's acct   ║
║    ParameterEngine.cache_size()  # ETS health            ║
║    ParameterEngine.refresh_all() # reload from DB        ║
║    OperatorPortal.get_account_summary(id, agent)         ║
║                                                          ║
║  Roles pre-loaded: agent / supervisor / manager / admin  ║
║  PANs pre-loaded: pans.ahmed, pans.khalid, etc.          ║
╚══════════════════════════════════════════════════════════╝
\e[0m
"""
