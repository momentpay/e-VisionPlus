# ITS — Interchange Transaction Services (Scheme Exception Processing): Module Requirements

**Status:** 📝 Draft for review — **naming clarification included** (§1): the codebase's `its/` implements scheme exception/fee processing, which is what this doc covers. Validate scheme message scope against Visa/MC documentation.

---

## 1. Purpose & Scope — and a Naming Clarification

Two different "ITS" definitions exist in project docs:
- `CLAUDE.md`'s module map says *"ITS — Integrated Telephony System (IVR)"* — but telephony actually lives in `lib/vmu_core/ivr/` (documented separately in `../ivr/IVR_Module_Requirements.md`).
- The actual `lib/vmu_core/its/` code implements **scheme exception processing**: copy (retrieval) requests, scheme fee claims/collection messages, and network financial adjustments — i.e. the non-clearing scheme message traffic between issuer and network.

This document covers what the code does. **Recommend updating CLAUDE.md's module map** to resolve the collision.

## 2. Where ITS Sits

| Direction | Module | Contract |
|---|---|---|
| ↔ Network | Scheme messages | Copy requests (Visa request-for-copy / MC retrieval), fee collection (MC 1740 / Visa fee collection), miscellaneous adjustments |
| → DPS | Retrieval | Inbound copy request may precede a dispute — fulfillment feeds the dispute file |
| ← TRAMS | Source data | Copy fulfillment pulls transaction detail; fee claims tie to clearing records (IpmPipeline calls `FeeClaimProcessor.create_claim`) |
| → CMS | Financial | Fee claims and adjustments post to ledger |

## 3. VisionPlus Feature Inventory

### 3.1 Copy / Retrieval Requests (FR-ITS-001 … 006)

| FR | Feature | Notes |
|---|---|---|
| 001 | Inbound copy request intake (from network file/message) | `copy_request.ex` |
| 002 | Request-to-transaction matching (RRN hierarchy) | should reuse TRAM matching |
| 003 | Fulfillment: assemble transaction detail/receipt substitute, respond within deadline | `copy_request_manager.ex` |
| 004 | Deadline tracking + auto-expiry (non-fulfillment → chargeback exposure) | Oban `copy_request_expiry` referenced in queue config |
| 005 | Copy request fee assessment (cardholder statement-copy fee) | `statement copy` fee in CMS fee engine |
| 006 | Link fulfilled requests to subsequent DPS cases | DPS FR-006 |

### 3.2 Fee Claims & Scheme Adjustments (FR-ITS-007 … 014)

| FR | Feature | Notes |
|---|---|---|
| 007 | Inbound fee collection message processing (scheme fees, penalties) | `fee_claim.ex` · `fee_claim_processor.ex` |
| 008 | Fee claim from clearing records (interchange-related claims) | IpmPipeline hook exists |
| 009 | Outbound fee collection (issuer claims against acquirer) | |
| 010 | Miscellaneous financial adjustment messages (in/out) | `financial_adjustment*.ex` |
| 011 | Adjustment-to-transaction correlation + GL posting | |
| 012 | ITS batch cycles (ITS1/ITS2 per queue config comment) | `batch/` |
| 013 | Scheme fee reconciliation vs network billing reports (VSS/QMR equivalents) | |
| 014 | Rejects/exception queue for unmatched claims | |

## 4. Current Implementation Map (`lib/vmu_core/its/`)

| File | Covers |
|---|---|
| `copy_request.ex` · `copy_request_manager.ex` | Retrieval request intake + fulfillment + expiry |
| `fee_claim.ex` · `fee_claim_processor.ex` | Fee claims (wired from IpmPipeline clearing inserts) |
| `financial_adjustment.ex` · `financial_adjustment_processor.ex` | Scheme adjustment processing |
| `batch/` · `oban/` | ITS batch cycles + scheduled jobs (`its: 4` Oban queue) |

## 5. Gap Analysis (initial — verify during planning)

| Area | Assessment |
|---|---|
| Copy request, fee claim, adjustment skeletons + batch | ✅ Exist (depth unverified) |
| Copy-request → TRAM transaction matching (FR-002) | ⬜ verify — should reuse `TRAMS.MatchingEngine` hierarchy instead of bespoke lookup |
| Copy-request ↔ DPS case linkage (FR-006) | ⬜ Not found |
| Outbound claims (FR-009), scheme billing recon (FR-013) | ⬜ Not found |
| Network message format handling (real Visa/MC formats vs internal stubs) | ⬜ verify |
| Ops UI | ⬜ None (Roadmap 9.16) |

## 6. Open Questions

1. Actual network delivery channel for these messages in target deployment (Visa/MC direct, or via a processor gateway?) — determines format work.
2. Copy fulfillment format: TIFF/PDF receipt substitute vs data-only response.
3. Resolve the ITS-vs-IVR naming in CLAUDE.md (recommended: ITS = scheme exception services, IVR = telephony).
