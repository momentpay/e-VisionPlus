# vMu_core — VisionPlus Elixir Implementation

## What This Project Is

vMu (VisionMu) is a complete reimplementation of the Visa VisionPlus card management system in Elixir/Phoenix. The goal is full functional parity with VisionPlus so that existing VisionPlus customers can migrate naturally.

VisionPlus is a credit card management system built around: a real-time authorization switch, a credit ledger with interest and EOD billing cycles, clearing and settlement, fraud/risk rules, and cardholder/operator service channels.

---

## Current Build State

What is built and compiles clean (as of Phase 0):

| File | Status |
|---|---|
| `lib/vmu_core/repo.ex` | ✅ PostgreSQL Ecto repo |
| `lib/vmu_core/application.ex` | ✅ Supervision tree: Repo → ParameterEngine |
| `lib/vmu_core/shared/parameter_engine.ex` | ✅ Production-quality GenServer + ETS cache |
| `lib/vmu_core/shared/sys_parameter.ex` | ✅ Ecto schema + changeset |
| `lib/vmu_core/shared/bank_parameter.ex` | ✅ Ecto schema + changeset |
| `lib/vmu_core/shared/logo_parameter.ex` | ✅ Ecto schema + changeset |
| `lib/vmu_core/shared/block_parameter.ex` | ✅ Ecto schema + changeset |
| `priv/repo/migrations/*_create_parameter_tables.exs` | ✅ All 4 tables with FK constraints |

**Next milestone:** Phase 1 — wire the ParameterEngine into the authorization switch and build AccountStateCoordinator. See `docs/phase1-implementation-spec.md`.

---

## Architecture: 11-Module VisionPlus Map

vMu maps to VisionPlus's 11 modules. Current `mix.exs` pulls 5 existing source repos as path deps — these are the raw material, not finished modules.

| vMu App (target) | VisionPlus Module | Source Repo(s) | Reusability |
|---|---|---|---|
| `vMu_fas` | FAS — Financial Authorization System | `muNSwitch / da_product_app` | ~85% |
| `vMu_cms` | CMS — Credit Management System | `wallet_cards`, `wallet_gl` | ~50% |
| `vMu_trams` | TRAMS — Transaction Management System | `settlement_core` | ~70% |
| `vMu_cdm` | CDM — Credit Decision Module | `mw_risk` | ~60% |
| `vMu_asm` | ASM — Access Security Module (operator portal) | None | 0% — net new |
| `vMu_mbs` | MBS — Merchant Billing System | None | 0% — net new |
| `vMu_its` | ITS — Integrated Telephony System (IVR) | None | 0% — net new |
| `vMu_cta` | CTA — Card Transaction Administration | None | 0% — net new |
| `vMu_col` | COL — Collections & Recovery | None | 0% — net new |
| `vMu_dps` | DPS — Dispute Processing System | None | 0% — net new |
| `vMu_shared` | Shared — Parameter engine, CIF, schemas | `vmu_core` (current) | ✅ Started |

---

## Source Repo Roles

### `muNSwitch` → `da_product_app` (vMu_fas source)
ISO 8583 switch. **Do not modify this repo.** Wrap and extend in vMu_fas context.
Key modules to know:
- `DaProductApp.Switch.Router` — routes MTI 0100/0110/0400/0800 messages
- `DaProductApp.Switch.AsyncCorrelator` — STAN-keyed request/response correlation (GenServer pool)
- `DaProductApp.Switch.Protocol` / `EnhancedProtocol` — Ranch TCP listener, length-prefixed framing
- `DaProductApp.Switch.ReversalOrchestrator` — MTI 0400 reversal handling
- `DaProductApp.SoftHSM` — PIN block operations (T-DES ISO FORMAT-0)

### `tmsuat_apps-main` → `settlement_core`, `platform_core` (vMu_trams source)
Settlement and transaction matching. Currently acquirer-focused (UAE POS). Needs issuer-side extension.
Key modules:
- `SettlementCore.CoreTransaction` — rich transaction schema, lifecycle: unmatched→matched→approved→paid
- `SettlementCore.InterchangeRate`, `MdrRate`, `MdrTemplate` — fee calculation engine (reuse as-is)
- `SettlementCore.AlipayPlus.*` — Broadway + SFTP pattern to follow for IPM file processing

### `wallet-app` → `wallet_cards`, `wallet_gl`, plus shared/events/observability (vMu_cms source)
Debit/prepaid card model. Provides the event-sourced command/event pattern and card status machine. **Not a credit card CMS** — missing: credit_limit, OTB, balance buckets, interest, EOD.
Key modules:
- `WalletCards.Card` — card entity with status machine (active/frozen/blocked/expired)
- `WalletCards.BinValidator`, `CardTokenizer` — reuse directly
- `WalletGl.GlAdapter` — adapter behaviour for GL posting (extend for internal double-entry)

### `mw-core` → `mw_risk`, `mw_kernel`, `infra_repo`, `infra_feature_store` (vMu_cdm source)
ML-enhanced fraud detection engine.
Key modules:
- `MwRisk.Pipeline` — full scoring pipeline (fail-safe: any error → approve passthrough)
- `MwRisk.VelocityPipeline` — sliding window velocity via Broadway
- `MwRisk.SanctionsChecker` + `SanctionsCache` — OFAC/sanctions screening
- `MwRisk.GatewayRuleEngine` — configurable card authorization rules

---

## VisionPlus Core Concepts (critical to understand before coding)

### SYS → BANK → LOGO → BLOCK Parameter Hierarchy
Every configuration value (APR, fees, limits, cycle code) resolves via a 4-level cascade:
```
Block (product-specific override)
  └─ Logo (BIN range / card brand defaults)
        └─ Bank (institution-wide defaults)
              └─ System (global fallback)
```
`VmuCore.Shared.ParameterEngine.get/5` implements this. **All downstream modules read from ETS — never hit the DB on the hot path.**

### AccountStateCoordinator (most critical missing piece)
One GenServer process per active account, registered in Horde (distributed registry). Holds in memory:
- current OTB (open-to-buy)
- current balance buckets
- active delinquency bucket
- pending authorization count

Authorization path: `Switch.Router` → `ParameterEngine.resolve_bin/1` (BIN→Logo) → `AccountStateCoordinator.authorize/3` (OTB check, limit check) → approve/decline.

This replaces DB row-level locking. Never lock the `cms_accounts` row during authorization — use the GenServer message queue instead.

### ETS Table: `:vmu_parameter_cache`
Public, read-concurrent ETS table. Key format: `{level_atom, ids..., param_key}`.
- `{:sys, sys_id, :base_currency}` → value
- `{:bank, sys_id, bank_id, :country_code}` → value
- `{:logo, sys_id, bank_id, logo_id, :bin_prefix}` → value
- `{:block, sys_id, bank_id, logo_id, block_id, :apr_percentage}` → value

Call `VmuCore.Shared.ParameterEngine.refresh_all/0` after any parameter update.

### Decimal Precision (mandatory for all money)
**Always use `Decimal` for monetary values, never float.** Use `Decimal.add/2`, `Decimal.mult/2`, `Decimal.div/2`. Ecto schema fields use `:decimal` type.

---

## Coding Conventions

| Concern | Library | Notes |
|---|---|---|
| Money/amounts | `Decimal` | Never `Float` for financial values |
| Background jobs | `Oban` | All async work: EOD, dunning, bureau calls |
| Distributed GenServer registry | `Horde` | AccountStateCoordinator per account |
| High-volume pipelines | `Broadway` | IPM file processing, velocity counters |
| HTTP clients | `Req` or `Tesla` | Bureau API, card network REST |
| Database | `Ecto` + `Postgrex` | PostgreSQL only |
| Real-time UI | `Phoenix LiveView` | ASM operator portal |
| ISO 8583 | `MercuryISO8583` | Already in muNSwitch — do not reimplement |

### Module Naming Convention
All new code lives in the `VmuCore.*` namespace (or `VmuFas.*`, `VmuCms.*` etc. when the umbrella is created).
When calling source repo code, wrap it behind a vMu-namespaced context module rather than calling it directly from business logic.

```elixir
# Good — vMu context module delegates to source repo
defmodule VmuCore.FAS.Switch do
  def route(msg), do: DaProductApp.Switch.Router.route(msg)
end

# Bad — business logic directly calling source repo
DaProductApp.Switch.Router.route(msg)
```

### Error Handling
- Authorization path: **fail-safe** — any unexpected error returns a decline with RC "91" (switch inoperative), never raises
- EOD workflows: **idempotent** — every Oban job must be safe to retry; use DB idempotency keys
- GL posting: **exactly-once** — idempotency guard before every journal entry insert

---

## Database Schema (existing + planned Phase 1)

### Existing (migrated, in production use):
```sql
sys_parameters    (sys_id PK, base_currency, description)
bank_parameters   (sys_id, bank_id PK, country_code, description)
logo_parameters   (sys_id, bank_id, logo_id PK, bin_prefix, description)
block_parameters  (sys_id, bank_id, logo_id, block_id PK, apr_percentage, cash_advance_fee_percent, credit_limit_default)
```

### Phase 1 additions (see phase1-implementation-spec.md for full DDL):
```
cms_customers     — CIF customer master (above accounts)
cms_accounts      — credit card accounts with cycle_code, delinquency_bucket, OTB
cms_balance_buckets — per-account balance breakdown (retail, cash, fee, interest)
stip_thresholds   — Stand-In Processing limits by logo
```

---

## Key Documents

| Document | Location | Purpose |
|---|---|---|
| Architecture assessment | `docs/architecture-assessment.md` | Full module map, reusability scores, net-new build list |
| Phase 1 spec | `docs/phase1-implementation-spec.md` | Tactical implementation guide for Phase 1 (6 tasks) |
| Initial plan | `docs/initial-implementation-plan.txt` | Original scope and current build status |
| YSP API docs | `docs/ysp-cards-integration-document/` | YSP/Narada APIs — treated as VisionPlus feature reference, not integration target |

---

## What NOT To Do

- Do not mock the database in integration tests — use a real test PostgreSQL database
- Do not use `Float` for any monetary value
- Do not call `DaProductApp.*` or `WalletCards.*` or `MwRisk.*` directly from vMu business logic — always go through a vMu context wrapper
- Do not restructure the umbrella layout until Phase 2 — keep the hub-and-spoke `mix.exs` path-dep approach for now
- Do not add `override: true` to new deps unless there is a genuine version conflict
- Do not add GenServer calls on the authorization hot path that involve DB round-trips — use ETS or Horde GenServer state only
