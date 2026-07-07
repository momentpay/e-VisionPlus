# 08 — Chargebacks & Disputes

**Parent document:** [TRAM_Module_Developer_Requirements.md](./TRAM_Module_Developer_Requirements.md)
**Status:** ⚠️ Lifecycle states covered in main doc Section 7.2 (States 9–11); this file adds the **workflow spec**, drafted from general card-network dispute-process domain knowledge — **not extracted from the source docx**. Exact reason codes/timelines must be validated against current Visa/Mastercard/RuPay operating regulations and any existing dispute-ops documentation.

---

## 1. Purpose

Covers the full dispute lifecycle from cardholder complaint through network chargeback, representment, and resolution — building on the state model already defined (Disputed → Chargeback → Chargeback Reversal → Closed) with the actual workflow, data requirements, and timelines needed to implement it.

## 2. Core Concepts

| Term | Definition |
|---|---|
| **Retrieval Request** | Network/acquirer asks the issuer to produce supporting documentation (receipt, transaction detail) for a transaction — often precedes a formal dispute; issuer must respond within a network-defined window. |
| **Dispute (Cardholder-Initiated)** | Cardholder claims a transaction is unrecognized, incorrect, or undelivered; issuer opens an internal case, which may or may not escalate to a chargeback. |
| **Chargeback** | Issuer formally reverses the transaction amount back to the cardholder and debits the acquirer/merchant, citing a network reason code. |
| **Representment** | Merchant/acquirer contests the chargeback with evidence; if accepted, the chargeback is reversed (main doc State 11). |
| **Pre-Arbitration / Arbitration** | Escalation path when representment is disputed by the issuer; network makes a final ruling. |

## 3. Functional Requirements

### 3.1 Dispute Intake

- Must capture: transaction reference (resolved via the matching hierarchy in main doc Section 6.4 — cardholder typically only has amount/merchant/date, sometimes the RRN from their statement), dispute reason (mapped to a network reason code — e.g., "goods not received," "duplicate processing," "unauthorized transaction"), cardholder statement/narrative, and supporting evidence if provided at intake.
- Must validate **dispute window eligibility** before allowing intake — networks impose a maximum time from transaction/statement date within which a dispute can be raised (commonly 120 days from transaction date per Visa/Mastercard rules, but varies by reason code and network — confirm actuals, see Open Questions).
- On successful intake, emit `DisputeCreated` and transition the transaction to `DISPUTED` (main doc State 9), while preserving the full prior history (Authorization, Settlement, Posting, Statement records) untouched, per the main document's explicit instruction for this state.

### 3.2 Provisional Credit

- Many jurisdictions/regulations (and most issuer policies) require issuing a **provisional credit** to the cardholder while a dispute is investigated, typically within a regulatory timeframe (e.g., 10 business days in several regulatory regimes) — this is a Ledger/CMS-side effect triggered by `DisputeCreated`, not something TRAM itself owns, but TRAM must publish the event promptly enough for Ledger to act within the required window (see `10_integration_points.md`).

### 3.3 Chargeback Processing

- Chargeback message arrives from the network (or is raised internally after dispute investigation confirms merchant fault) referencing the original transaction via RRN/network reference (main doc Section 6.4).
- System must correlate the chargeback to the correct transaction and dispute case, then emit `ChargebackCreated`, moving state to `CHARGEBACKED` (main doc State 10).
- Must record: chargeback reason code, chargeback amount (may be partial), chargeback date, and the network case reference.

### 3.4 Representment / Resolution

- If merchant contests: acquirer submits representment; issuer reviews evidence against the original dispute reason.
- Two outcomes:
  - **Representment accepted** → chargeback reversed, funds returned to merchant side, transaction re-enters a resolved/`CLOSED`-bound path (main doc State 11 → 12). Emit `ChargebackReversed`.
  - **Representment rejected / issuer proceeds to pre-arbitration** → case remains open, potential escalation to network arbitration; final network ruling determines outcome.
- Every step must be captured as its own event (`RepresentmentReceived`, `RepresentmentAccepted`, `PreArbitrationFiled`, `ArbitrationRuled`) rather than collapsing the dispute case into a single mutable status field — consistent with the event-sourced principle in the main document (Section 7.3), and essential here because dispute cases are exactly the kind of multi-month, multi-party workflow that benefits most from full auditability.

### 3.5 Documentation Requirements

- Each stage typically requires supporting documentation (retrieval request response, cardholder dispute statement, merchant evidence, network correspondence) — store as attachments linked to the dispute case, with retention aligned to network/regulatory requirements (often several years).

## 4. Reason Code Handling

> **Developer Note:** Exact reason code sets and their associated timelines differ by card network (Visa, Mastercard, RuPay, etc.) and change periodically via network rule updates. Do not hardcode a fixed enum expecting it to be stable long-term — model `reason_code` as a reference-data table (network + code + description + dispute window + evidence requirements) that can be updated without a code deployment, and confirm current values with compliance/network documentation before go-live.

## 5. Suggested Elixir/Phoenix Implementation Sketch

```
disputes/                       # dedicated context, referencing transactions by transaction_id
  dispute_case.ex                # aggregate: DisputeCreated, ChargebackCreated, RepresentmentReceived, ...
  dispute_reason_codes.ex        # reference-data lookup (network-specific)
  dispute_window_validation.ex   # eligibility check at intake
  dispute_evidence.ex            # attachment/document management
```

Keep `disputes` as its own bounded context (not folded into the core `transactions` aggregate) since its lifecycle, actors (cardholder, network, merchant/acquirer), and timelines are materially different — but every dispute event should still reference the underlying `transaction_id` and be visible in the Transaction Inquiry detail view (`04_transaction_inquiry.md`, Section 2.3).

## 6. Open Questions for SME / Product Validation

- Current dispute window per network and reason code (confirm against latest Visa/Mastercard/RuPay operating regulations rather than assuming a fixed 120-day figure).
- Provisional credit policy and regulatory timeline applicable to your issuing jurisdiction.
- Whether pre-arbitration/arbitration handling is in scope for initial release or a later phase.
- Evidence retention period and storage requirements (may have specific regulatory/audit constraints beyond general data retention policy).
