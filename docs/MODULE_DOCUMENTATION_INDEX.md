# E-VisionPlus — Module Documentation Index

> Created: 2026-07-04 · One requirements document per VisionPlus module, each in
> its own `docs/<module>/` folder. **Purpose:** a complete, reviewable feature
> inventory per module BEFORE implementation planning — the successor to the
> module-agnostic `VISIONPLUS_ROADMAP.md` (which is UI-phase-oriented and
> predates the FAS/TRAM workstreams).

## How each document is structured

1. **Purpose & scope** — what the module owns, with a boundary test
2. **Where it sits** — integration contracts with other modules
3. **Feature inventory** — numbered FR tables covering the full VisionPlus feature set
4. **Current implementation map** — file-by-file what exists in `lib/vmu_core/`
5. **Gap analysis** — ✅ built / 🔄 partial / ⬜ missing (initial, to verify)
6. **Open questions** — SME/product decisions that gate implementation

## Review status

| Module | Document | Status | Headline from gap analysis |
|---|---|---|---|
| **FAS** | [fas/fas_system_requirements.md](fas/fas_system_requirements.md) + [tracker](fas/FAS_Implementation_Tracker.md) | ✅ Complete (46/46, 2026-07-02) | Done — 107 FRs implemented incl. HSM/EMV + observability |
| **TRAMS** | [tram/TRAM_Module_Developer_Requirements.md](tram/TRAM_Module_Developer_Requirements.md) + [tracker](tram/TRAM_Implementation_Tracker.md) | ✅ Complete (25/25, 2026-07-04) | Done — event-sourced repository, matching, posting, statements, dispute bridge |
| **CMS** | [cms/CMS_Module_Requirements.md](cms/CMS_Module_Requirements.md) | 📝 For review | Core largely built; gaps: payment channels/autopay, account transfer/closure, dormancy, promo pricing, customer-level exposure |
| **CIF** | [cif/CIF_Module_Requirements.md](cif/CIF_Module_Requirements.md) | 📝 For review | Master + KYC UI built; gaps: dedupe, merge, sanctions hook, exposure roll-up, consent/retention |
| **CTA** | [cta/CTA_Module_Requirements.md](cta/CTA_Module_Requirements.md) | 📝 For review | **No first-class card entity** — replacement/renewal/lifecycle history need it; admin UI = Roadmap Phase 5 |
| **DPS** | [dps/DPS_Module_Requirements.md](dps/DPS_Module_Requirements.md) | 📝 For review | State machine + deadlines + TRAM bridge built (2 bugs fixed 07-03); gaps: reason-code reference data, loss-reversal posting, evidence store, ops UI |
| **COL** | [col/COL_Module_Requirements.md](col/COL_Module_Requirements.md) | 📝 For review | Case/dunning/write-off exist; gaps: strategy engine, contact history, workout plans, agency files, recovery accounting, dispute exclusion |
| **CDM** | [cdm/CDM_Module_Requirements.md](cdm/CDM_Module_Requirements.md) | 📝 For review | Scorers exist; **namespace bug in behavioral_rescorer** (runtime crash when invoked); gaps: application workflow/queue, limit-increase program |
| **MBS** | [mbs/MBS_Module_Requirements.md](mbs/MBS_Module_Requirements.md) | 📝 For review | **Scope decision blocks everything** — overlap with tmsuat settlement_core; recommend issuer-side merchant master only |
| **LMS** | [lms/LMS_Module_Requirements.md](lms/LMS_Module_Requirements.md) | 📝 For review | Richest skeleton (16 files); gaps: reversal clawback (TRAM event hook), expiry notices, statement feed |
| **HCS** | [hcs/HCS_Module_Requirements.md](hcs/HCS_Module_Requirements.md) | 📝 For review | Skeleton complete; key gap: **spending controls not wired into FAS auth pipeline** |
| **ASM** | [asm/ASM_Module_Requirements.md](asm/ASM_Module_Requirements.md) | 📝 For review | **Biggest production-readiness gap** — admin UI unauthenticated; all 4-eyes flows honor-system without operator identity |
| **ITS** | [its/ITS_Module_Requirements.md](its/ITS_Module_Requirements.md) | 📝 For review | Copy/fee/adjustment skeletons exist; naming collision with IVR in CLAUDE.md flagged; gaps: TRAM-matching reuse, DPS linkage |
| **IVR** | [ivr/IVR_Module_Requirements.md](ivr/IVR_Module_Requirements.md) | 📝 For review | Session + OTP only; telephony vendor adapter is the real build |

## Cross-module findings surfaced while drafting

1. **ASM is the platform's gating gap** — every 4-eyes control (temp limits, waivers, adjustments, TRAM maintenance) validates maker ≠ checker on unauthenticated free-form IDs.
2. **Known bug:** `cdm/behavioral_rescorer.ex` calls `AccountStateCoordinator` under `VmuCore.Shared.*` instead of `VmuCore.CMS.*` — compile warning today, crash when its limit/restriction actions fire.
3. **Customer-level exposure roll-up** is missing and blocks both CMS FR-030 and CDM FR-016.
4. **MBS scope** must be decided before any MBS work (settlement_core overlap).
5. **ITS/IVR naming collision** in CLAUDE.md's module map should be corrected.
6. **CTA lacks a card entity** — card state rides on `cms_accounts`, which cannot represent plastic generations (replacement/renewal history).
7. Several modules should consume **TRAM lifecycle events** rather than scanning tables: LMS clawback, ITS copy matching, COL dispute exclusion.

## Suggested review order

1. **ASM** (security gate) → 2. **CMS** (largest, most load-bearing) → 3. **CTA** (structural card-entity decision) → 4. **DPS/COL/CDM** (ops workflows) → 5. **LMS/HCS** (products) → 6. **MBS/ITS/IVR** (scope/integration decisions).

After review sign-off per module: convert each gap analysis into a phased implementation tracker (the FAS/TRAM tracker format), then sequence across modules.
