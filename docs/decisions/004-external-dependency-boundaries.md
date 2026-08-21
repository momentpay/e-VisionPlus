# VMU-ADR-004 — External dependency boundaries: retire wallet-app, keep muNSwitch and mw-core

## Status

**Accepted** — 2026-08-01.

## Context

`vmu_core` is the platform of record ([VMU-ADR-001](001-platform-of-record.md)), yet `mix.exs` consumes **12 applications from 4 sibling repositories** as `path:` dependencies. Several own live, load-bearing capability:

| Repository | Applications | What it owns |
|---|---|---|
| `../muNSwitch` | `da_switch_core`, `da_issuer` | The ISO 8583 protocol engine and the issuer-facing Ranch listener (MIP 7585 / VAP 8600). vmu_core's own listener and hand-rolled parser were deleted in favour of these |
| `../mw-core` | `mw_risk`, `mw_kernel`, `infra_repo`, `infra_feature_store` | Fraud and risk detection — rule engine, activation engine, velocity, sanctions, ML scoring, explainability |
| `../wallet-app` | `wallet_gl`, `wallet_cards`, `wallet_database`, `wallet_shared_kernel`, `wallet_events`, `wallet_observability` | A GL adapter behaviour, a posting-record struct, and a Money value type |
| `../tmsuat_apps-main` | `settlement_core`, `platform_core` (`runtime: false`) | Code reuse only; their OTP apps are deliberately not started |

This arrangement was never decided. It is an accident of the project's lineage — each dependency arrived when a source repository was being mined for reuse, and none was ever revisited. Until now the platform has had no stated position on which capabilities it intends to own.

## Problem Statement

Which external dependencies are a deliberate architectural boundary, and which are unfinished migration?

## Decision

**Two of the four are deliberate boundaries and stay. One is retired. One is already inert.**

| Repository | Decision |
|---|---|
| **`../muNSwitch`** | **Keep, as-is.** A deliberate boundary. The ISO 8583 engine and Ranch listener remain externally owned and separately versioned |
| **`../mw-core`** | **Keep, as-is.** A deliberate boundary. Fraud and risk detection remains externally owned |
| **`../wallet-app`** | **Retire.** wallet-app is not going to be used. All six dependencies are removed and the small surface vmu_core uses is absorbed natively. See [`architecture/Wallet_App_Dependency_Migration.md`](../architecture/Wallet_App_Dependency_Migration.md) |
| **`../tmsuat_apps-main`** | **No change.** Already `runtime: false`; code reuse only. Revisit only if a runtime need appears |

"Deliberate boundary" carries an obligation: muNSwitch and mw-core are to be treated as **owned external services with contracts**, not as vendored source. Their capabilities are named in the ownership map so that reading `vmu_core` alone no longer understates the platform.

## Alternatives Considered

1. **Absorb everything into `vmu_core`.** Rejected. It would mean taking ownership of an ISO 8583 protocol stack and a fraud engine — both substantial, both working, both legitimately separable and separately versioned. No benefit proportional to the cost or risk.
2. **Keep all four as-is.** Rejected for wallet-app specifically: the product is not being used, so a dependency on it is dead weight that will confuse every future reader about what the platform is built on.
3. **Retire wallet-app, formalise the other two.** Selected.

## Rationale

The distinction is *whether the upstream product has a future*. muNSwitch and mw-core are live, maintained, and own capability vmu_core has no reason to reimplement. wallet-app is not going to be used, which makes any dependency on it a liability rather than reuse — it misrepresents the platform's foundation and blocks nothing if removed.

The measured coupling made the decision easy. wallet-app's surface turned out to be **two files** in `vmu_core`, one behaviour, one struct and one 55-line value type. Four of the six dependencies are referenced **nowhere in code at all**.

## Consequences

**Positive.** The build stops depending on a retired product. Four dead dependencies disappear. The remaining two external boundaries become stated architecture rather than accident, and the ownership map documents what they own.

**Trade-offs.** vmu_core still cannot be built or deployed without `../muNSwitch` and `../mw-core` checked out adjacent to it. That constraint is now explicit rather than discovered.

**Known limitations.** This decision does not resolve *how* the two retained boundaries are versioned or released. They remain `path:` dependencies on a sibling working directory, which is a development-time convenience, not a release strategy. That is a separate decision when it matters.

**Operational impact.** Removing wallet-app also removes the last dependency-level trace of the merge topology reversed by VMU-ADR-001 — completing at the build level what [VMU-ADR-012](README.md#42-authorization--switch-was-adr-001003-fas-tracker) settled at the call-site level.

## Related Documents

- [`architecture/Wallet_App_Dependency_Migration.md`](../architecture/Wallet_App_Dependency_Migration.md) — the migration plan
- [`architecture/Kosa_Domain_Ownership_Map.md`](../architecture/Kosa_Domain_Ownership_Map.md) §4.9 — what each external repository owns
- [VMU-ADR-001](001-platform-of-record.md) · [VMU-ADR-012](README.md#42-authorization--switch-was-adr-001003-fas-tracker)

## Review Date

Review the muNSwitch and mw-core boundaries if either upstream is retired, or if `path:` dependencies become an obstacle to release — whichever comes first.
