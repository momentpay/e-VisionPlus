# VMU-ADR-001 — Standalone `vmu_core` is the platform of record

## Status

**Accepted** — 2026-07-23. Reverses the prior position.

## Context

Two codebases carried overlapping implementations of the same platform: standalone `vmu_core`, and a merged umbrella (referred to as Avenza) that combined `vmu_core` with `wallet-app` and related apps. For a period the merged umbrella was treated as the base, with work reconciled into it.

That arrangement produced a repeated, expensive failure. Features built in one tree were silently lost when the other was treated as authoritative — COL, LMS and ASM-SSO each had real, completed work disappear this way. By the end of 2026-07-24 the same pattern had recurred seven times, each recurrence costing a re-port of work that had already been finished and verified once.

## Problem Statement

Which tree is authoritative, and in which direction does work move between them?

## Decision

**Standalone `vmu_core` is the platform of record.** Features that exist only in the merged umbrella are **ported into `vmu_core`**. Work is never reconciled in place in the umbrella and never assumed to have carried over.

Operationally, this makes one habit mandatory: **before concluding that any capability is missing, check `Avenza/apps/vmu_*`, the sibling repositories, and the git history.** A capability absent from `vmu_core` has, repeatedly, turned out to be built elsewhere.

## Alternatives Considered

1. **Merged umbrella as base** — the prior position. Rejected: it was the direct cause of seven separate instances of lost work, and the loss mode was silent.
2. **Maintain both, sync bidirectionally** — rejected: doubles the reconciliation surface that was already failing in one direction.
3. **Standalone `vmu_core` as base, port inward** — selected.

## Rationale

A single authoritative tree with a one-directional port removes the failure mode entirely: nothing can be lost by being written in the wrong place, because there is only one right place. `vmu_core` was chosen over the umbrella because it carried the deeper card-platform implementation (FAS, TRAMS, CMS, EOD) and because the umbrella's value was concentrated in a small number of portable features.

## Consequences

**Positive.** One authoritative tree. The silent-loss failure mode is structurally removed.

**Trade-offs.** Features genuinely built in the umbrella must be re-ported, which is real work, and identifying them requires searching a second codebase rather than trusting either tree's documentation.

**Known limitations.** Code changes made in the umbrella *after* the reversal are explicitly **not assumed** to have carried over — including CU-1 and CU-2 era work. Each must be verified individually.

**Operational impact.** The port plan itself was never written. Ports have proceeded case-by-case as gaps were discovered, which is why several were found late.

**Downstream.** This decision **voids** the stated future of [VMU-ADR-012](README.md#42-authorization--switch-was-adr-001003-fas-tracker), which anticipated `vmu_core` and `wallet-app` being co-deployed in one OTP release as "VisionPlus milestone 2". There is no such milestone. Direct posting via `VmuCoreGlAdapter` is the end state, not a stopgap. Any document still describing a co-deployment future is describing the superseded topology.

## Related Documents

- [`docs/architecture/Kosa_Domain_Ownership_Map.md`](../architecture/Kosa_Domain_Ownership_Map.md) §4.9 — capabilities still owned by external repositories
- [`docs/compare/Way4_Parity_Implementation_Plan.md`](../compare/Way4_Parity_Implementation_Plan.md) §0 — the ground-truth correction that prompted this

## Review Date

Review when the last umbrella-only capability has been ported, or when a decision is made about the four external `path:` dependencies (see ownership map §4.9).
