# VMU-ADR-003 — The product is Koṣa; the code namespace rename is deferred indefinitely

## Status

**Accepted** — 2026-08-01.

## Context

Three names are in circulation for one thing:

| Name | Where it appears |
|---|---|
| **Koṣa** | The architecture handbook; the product name |
| **E-VisionPlus** | Documentation titles, `docs/E-VisionPlus_Product_Overview.md`, tracker headings |
| **`vmu_core` / `VmuCore.*`** | Repository directory, Mix application, every Elixir module |

`vMu` (VisionMu) and E-VisionPlus both originate in the project's beginning as an Elixir reimplementation of Visa VisionPlus — the same lineage that gives the codebase its VisionPlus subsystem layout (CMS, FAS, TRAMS, …).

It was confirmed on 2026-08-01 that **Koṣa and E-VisionPlus are one product, not two**, and that the product name is Koṣa.

## Problem Statement

Given one product with three names, does the code adopt the product name?

## Decision

**Adopt "Koṣa" in documentation and product-facing language. Defer the code namespace rename indefinitely.**

- New and refreshed documents are titled and framed as Koṣa.
- `vmu_core`, `VmuCore.*`, the repository directory and the Mix application keep their current names.
- Existing documents are renamed opportunistically when touched for other reasons, not as a campaign.

## Alternatives Considered

1. **Rename everything now** — repository, Mix app, `VmuCore.*` → `Kosa.*`, plus every document. Rejected: see Rationale.
2. **Rename documents only** — selected.
3. **Change nothing, keep using E-VisionPlus** — rejected: it perpetuates a name for a product that has one, and the handbook already uses Koṣa throughout.
4. **Rename the code but not the docs** — rejected as strictly worse than either coherent option.

## Rationale

The rename buys **no functional gain** and carries **real regression risk**. A prior app-atom rename in this codebase required sweeping every `Application.get_env`/`put_env` call site, not merely the `config.exs` declarations — an incompleteness that is easy to miss and fails at runtime rather than at compile time.

The cost is also broader than it looks: `VmuCore.*` appears in every module in the repository, in four sibling repositories that consume `vmu_core` or are consumed by it as `path:` dependencies, and in the `mix.exs` of each. The `_build` and deployment paths change with it.

Set against a documentation-only change that achieves the entire communicative purpose, the code rename is a poor trade at this stage.

## Consequences

**Positive.** External readers — principally the architecture team — see one consistent product name. No build, deployment or dependency risk is taken.

**Trade-offs.** The codebase and its documentation use different names, which is mildly confusing to newcomers. Mitigated by stating the mapping explicitly in [`Kosa_Domain_Ownership_Map.md`](../architecture/Kosa_Domain_Ownership_Map.md) §6 and [`MODULE_DOCUMENTATION_INDEX.md`](../MODULE_DOCUMENTATION_INDEX.md) §1.

**Known limitations.** Documentation renaming is opportunistic, so mixed naming will persist in untouched documents for some time.

**Operational impact.** None.

## Related Documents

- [`architecture/Kosa_Domain_Ownership_Map.md`](../architecture/Kosa_Domain_Ownership_Map.md) §6
- [`MODULE_DOCUMENTATION_INDEX.md`](../MODULE_DOCUMENTATION_INDEX.md) §1

## Review Date

Revisit only if the namespace must be touched for an independent reason — for example an umbrella restructuring or an extraction that already requires rewriting module names.
