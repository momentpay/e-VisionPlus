# DPS — Dispute Processing System: Module Requirements

**Status:** 📝 Draft for review — drafted from VisionPlus/card-network dispute domain knowledge, cross-checked against `lib/vmu_core/dps/` and the TRAM dispute bridge. Validate reason codes/timelines against current Visa/Mastercard operating regulations.
**Companion spec:** `../tram/08_chargebacks_disputes.md` (workflow detail) — this doc is the module-level inventory; the TRAM sub-spec remains the workflow reference.

---

## 1. Purpose & Scope

DPS owns the **dispute case**: intake, provisional credit, the chargeback/representment/arbitration cycle against the network, deadline enforcement, evidence, and financial resolution. The disputed *transaction's* history stays in TRAMS (linked via `trams_transaction_id`, ADR-T5); the *money movement* posts to CMS ledger.

## 2. Where DPS Sits

| Direction | Module | Contract |
|---|---|---|
| ← TRAMS | Case origin | `TRAMS.DisputeBridge.file_dispute/2` — window-validated intake from a transaction |
| → TRAMS | Lifecycle mirror | `notify_transition/1` appends dispute events to the transaction timeline |
| → CMS | Provisional credit | `InternalGlPoster` DR 3001 / CR 1001 (`DISPUTE_CREDIT`); reversal on loss |
| → COL | Exclusion | Disputed transactions excluded from collections escalation while open |
| ↔ Network | Chargeback cycle | Visa/MC dispute messages (VROL / MC Connect equivalents) |
| → Letters | Correspondence | Acknowledgment, provisional credit notice, outcome letters |

## 3. VisionPlus Feature Inventory

### 3.1 Case Intake (FR-DPS-001 … 008)

| FR | Feature | Notes |
|---|---|---|
| 001 | Intake channels: CS/ops UI, cardholder app/web, IVR handoff | |
| 002 | Transaction resolution via matching hierarchy (RRN → identifiers) | TRAM §6.4 |
| 003 | Dispute window eligibility per network + reason code | 120d default; bridge enforces |
| 004 | Reason-code reference data: network + code + window + evidence requirements (table-driven, not enum) | TRAM 08 §4 |
| 005 | Cardholder narrative + evidence capture at intake | |
| 006 | Retrieval request handling (inbound copy request BEFORE dispute) | overlaps ITS copy requests |
| 007 | Duplicate-dispute prevention (one open case per transaction) | |
| 008 | Multi-transaction disputes (batch intake for one merchant incident) | |

### 3.2 Case Lifecycle (FR-DPS-009 … 018)

| FR | Feature | Notes |
|---|---|---|
| 009 | State machine: FILED → RETRIEVAL_REQUESTED → CHARGEBACK_FILED → REPRESENTED → PRE_ARB → ARBITRATION → CLOSED_WIN / CLOSED_LOSE / CANCELLED | Implemented |
| 010 | Provisional credit posting within regulatory window; reversal on CLOSED_LOSE | ✅ posting + reversal (2026-07-08, also covers CANCELLED) + scheme-recovery entry on CLOSED_WIN |
| 011 | Deadline enforcement per stage (Oban jobs; missed deadline = auto-forfeit) | Implemented |
| 012 | Network case reference tracking | `network_ref` field |
| 013 | Partial chargebacks (amount ≤ original) | |
| 014 | Evidence/document store per stage with retention | ⬜ |
| 015 | Case notes + investigator assignment | ⬜ |
| 016 | Good-faith / pre-chargeback merchant resolution attempt | |
| 017 | Fraud-flagged disputes: link to hot-card block + FAS decline history | |
| 018 | Cardholder communication triggers at each stage | |

### 3.3 Financial & Reporting (FR-DPS-019 … 024)

| FR | Feature | Notes |
|---|---|---|
| 019 | GL lifecycle: provisional credit → win (recover from scheme) / loss (re-debit cardholder) with distinct entries | |
| 020 | Scheme settlement of chargeback amounts (incoming credit reconciliation) | |
| 021 | Write-off small-balance disputes below threshold | |
| 022 | Regulatory SLA reporting (provisional credit timeliness) | |
| 023 | Dispute aging + deadline monitor dashboard | Roadmap 6.12 |
| 024 | Win/loss analytics per reason code + merchant | |

## 4. Current Implementation Map (`lib/vmu_core/dps/`)

| File | Covers |
|---|---|
| `dispute.ex` | Case schema + full state machine + provisional credit + deadline computation + TRAM notify hook (`trams_transaction_id` added TRAM-P5) |
| `deadline_job.ex` | Oban deadline enforcement per stage |
| `trams/dispute_bridge.ex` (TRAMS) | Window-validated intake from transaction + lifecycle mirroring |

**Bugs fixed 2026-07-03 (TRAM-P5 verification):** provisional-credit posting crashed on varchar(10) `transaction_code`; deadline scheduling crashed on `"UTC"` timezone. Disputes had never run end-to-end before — treat all DPS flows as newly-verified-basic, not battle-tested.

## 5. Gap Analysis (initial — verify during planning)

| Area | Assessment |
|---|---|
| State machine, deadlines, provisional credit, TRAM linkage | ✅ Built + smoke-tested |
| Reason-code reference table (FR-004) | ⬜ `reason_code` is free string; no reference data |
| Provisional-credit reversal on CLOSED_LOSE (FR-010b) | ✅ Implemented 2026-07-08 — see `docs/dps/DPS_Gap_Implementation_Tracker.md` DPS-P2 |
| Evidence store (FR-014) | 🔄 Scaffolded 2026-07-09 — `db` backend real, `s3`/`azure_blob` stubbed (no cloud SDK dep). See DPS-P3 |
| Case notes/assignment (FR-015) | ⬜ Not found |
| Retrieval request inbound flow (FR-006) | 🔄 ITS `copy_request` exists — integration between ITS copy requests and DPS cases unverified |
| Network message integration (FR-020) | 🔄 Scaffolded 2026-07-09 — `Manual` adapter real (formalizes today's process), `Vrol`/`Mastercom` stubbed (no API credentials). See `docs/dps/DPS_Gap_Implementation_Tracker.md` DPS-P3 |
| Ops UI: case list, detail, actions, deadline monitor | ⬜ Roadmap 6.9–6.12 |

## 6. Open Questions

1. Network connectivity for disputes: manual portal operation (ops re-keys) vs API integration (VROL/Mastercom) — determines FR-020 scope.
Answer: Looking for both options -1. manual portal 2. API integration (VROL/Mastercom) 
2. Provisional credit regulatory window in target market(s).
Answer: It has to be as per customer and market , and so we should keep this configurable 
3. Evidence retention period and storage location (DB blob vs object store).
Answer: Currently keep in db with option for any aws s3/azure blob 
4. Arbitration in v1 scope, or stop at representment?
Answer: Complete the flow

**Resolved 2026-07-08 — questions 1–3 implemented as configurable**, via the new
`VmuCore.Shared.ModuleConfig*` framework — see
`docs/shared/Module_Configuration_Framework.md`. Catalog:
`lib/vmu_core/dps/config_catalog.ex`.

| Question | Config key | Default |
|---|---|---|
| 1. Manual portal vs API integration, per network | `network_connectivity_mode` | `{VISA: manual, MASTERCARD: manual}` |
| 2. Provisional credit window | `provisional_credit_window_days` | `10` |
| 3. Evidence storage backend | `evidence_storage_backend`, `evidence_storage_config` | `db` / `{}` |

Editable via the admin console's **Module Configuration** screen. Question 4
(completing the arbitration flow) is **not** a config key; it's state-machine/GL
feature work, tracked separately (see `docs/shared/Module_Configuration_Framework.md`
§6) and in a future DPS tracker phase.

**Resolved 2026-07-08 — question 4 (complete the flow) implemented.** The state
machine already accepted PRE_ARB → ARBITRATION → CLOSED_WIN/CLOSED_LOSE transitions
(no state-machine change needed); the actual gap was the GL side — win/loss cases
closed with no financial resolution beyond the provisional credit. `VmuCore.DPS.Dispute`
now posts the recovery/reversal entry on closure (see `docs/dps/DPS_Gap_Implementation_Tracker.md`
DPS-P2). Still open, and explicitly out of scope for this pass: real VROL/Mastercom
network message integration (FR-020, still manual transitions), and the broader §5
backlog (reason-code reference table, evidence store, case notes, ops UI).

**Wiring status (2026-07-08, `docs/dps/DPS_Gap_Implementation_Tracker.md` DPS-P1.3):**
question 2 (provisional credit window) is fully wired — `VmuCore.DPS.Dispute` now
computes and stores `provisional_credit_deadline` from the configured value at filing
time, verified against a real account. Questions 1 and 3 (network connectivity mode,
evidence storage backend) were configurable in storage only at this point — there was
no VROL/Mastercom API integration or evidence storage abstraction yet for the config
value to drive.

**Updated 2026-07-09 (DPS-P3):** questions 1 and 3 are now scaffolded, not just
stored. `evidence_storage_backend` drives a real `db`-backend evidence store
(`VmuCore.DPS.Evidence`/`EvidenceStore`) — `s3`/`azure_blob` remain clean stubs
(`{:error, :not_implemented}`) since no cloud SDK dependency exists in this project.
`network_connectivity_mode` drives a real `Manual` network adapter (formalizing
today's actual manual-portal process, wired into `Dispute.transition/2`) — `Vrol`/
`Mastercom` (the `"api"` mode) remain stubs since no scheme API credentials exist.
See `docs/dps/DPS_Gap_Implementation_Tracker.md` DPS-P3 for full verification detail.
