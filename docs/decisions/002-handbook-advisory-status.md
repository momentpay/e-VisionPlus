# VMU-ADR-002 — The Koṣa Architecture Handbook is advisory, and the dev↔architecture channel is one-directional

## Status

**Accepted** — 2026-08-01.

## Context

The architecture team maintains the Koṣa Architecture Handbook (`Kosa/handbook/`): thirty domain documents plus foundation material, written between 2026-07-27 and 2026-08-01 and still in progress.

Its origin explains its shape. The architect began from VisionPlus, judged it structurally dated, benchmarked Way4, and concluded that an Erlang/Elixir/Phoenix platform warrants its own decomposition rather than a reimplementation of either. The handbook is the result, initially drafted over a snapshot of then-current `vmu_core` work.

The two teams work **separately, with no coordination forum**. This was reviewed and judged correct — disrupting development to introduce a joint process was not considered worth the cost.

The handbook had no declared status. Left unresolved, that is genuinely dangerous in both directions: if normative, development had been shipping non-compliant code unknowingly; if advisory, a gap analysis against it would be misread as a defect list.

## Problem Statement

Is the handbook a specification development must build to, or a target-state reference? And if the teams do not coordinate, what connects the two streams?

## Decision

**The handbook is advisory target-state reference, not a build specification.**

- Development does **not** build to the handbook and requires no sign-off gate against it.
- The architecture team maps the handbook against what development has built.
- The channel is **one-directional: development publishes as-built documents; architecture consumes and maps them.**

Development's obligation reduces to one thing: **make the as-built reality legible to an outside reader, in the handbook's vocabulary.**

## Alternatives Considered

1. **Normative handbook** — rejected. It would require a sign-off gate, developers reading ~2 MB of prose, and an architect responsive to implementation reality. All three are organisational changes, and none is achievable without the coordination forum that was deliberately not created.
2. **Two independent products** — rejected on the facts: Koṣa and E-VisionPlus are one product (see [VMU-ADR-003](003-naming-and-rename-deferral.md)).
3. **Bidirectional coordination** — rejected as disruptive to development at this stage.
4. **Advisory, one-directional dev→architecture** — selected.

## Rationale

Advisory status is the only option achievable without first building a coordination process. It costs nothing, invalidates no shipped work, and still gives development a completeness checklist at design time.

One-directional is the honest description of what the organisation will actually sustain. A documented artifact that is useful to its author whether or not anyone else reads it is a far more robust interface between uncoordinated teams than a meeting nobody owns.

## Consequences

**Positive.** Development's velocity is unaffected. The handbook's gap analysis becomes a reference rather than a backlog. Alignment is achieved by adopting the handbook's *vocabulary and patterns* rather than its structure — a unilateral choice needing no permission.

**Trade-offs.** Divergence accumulates silently between publication points. Nothing forces the architect to read what is published.

**Known limitations.** Any plan requiring joint work is void — specifically a merged ADR register (hence the `VMU-ADR-` namespace) and a jointly-filled bounded-context document (hence [`Kosa_Domain_Ownership_Map.md`](../architecture/Kosa_Domain_Ownership_Map.md) being written unilaterally, using the handbook's domain names as headers).

**Operational impact.** Three documents constitute the published interface, and must be maintained as such:

| Document | Role |
|---|---|
| [`architecture/Kosa_Domain_Ownership_Map.md`](../architecture/Kosa_Domain_Ownership_Map.md) | As-built ownership, violations, and deliberate deferrals |
| [`compare/Kosa_Handbook_Alignment_Assessment.md`](../compare/Kosa_Handbook_Alignment_Assessment.md) | Gap analysis, re-run at each phase boundary |
| [`decisions/`](README.md) | Why the implementation is the way it is |

The ownership map's §5 exists specifically to prevent the architect re-proposing deferrals that development already considered and rejected.

## Related Documents

- `Kosa/handbook/` — DOC-109A is the spine document; note that `README.md` and `DOC-100` still describe a superseded 15-document plan
- [`docs/MODULE_DOCUMENTATION_INDEX.md`](../MODULE_DOCUMENTATION_INDEX.md)

## Review Date

Review if a coordination forum is created, if the handbook is proposed as normative, or if two consecutive phase boundaries pass with no evidence the architecture team consumed what was published.
