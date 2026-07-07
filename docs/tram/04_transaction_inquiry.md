# 04 — Transaction Inquiry

**Parent document:** [TRAM_Module_Developer_Requirements.md](./TRAM_Module_Developer_Requirements.md)
**Status:** ⚠️ Drafted from general VisionPLUS / card-management domain knowledge — **not extracted from the source docx**, which does not cover this module. Validate against actual current VisionPLUS inquiry screens/behavior before finalizing.

---

## 1. Purpose

Transaction Inquiry is the read-side of TRAM: the set of search, lookup, and detail-view capabilities that customer service, operations, and cardholder-facing channels (app/web/IVR) use to answer "what happened to this transaction?" without touching write paths (Maintenance, Reversals, Disputes).

In legacy VisionPLUS, this corresponds to the TRAMS online inquiry screens (transaction search/detail panels) used by call-center and back-office staff. In E-VisionPlus this should be a dedicated **read model / query context**, separate from the write-side aggregate described in the main document's Section 7.

## 2. Functional Requirements

### 2.1 Search Entry Points

The system must support locating a transaction by any of the following, alone or combined:

| Search Key | Example | Notes |
|---|---|---|
| Account number / Account ID | `1234567890` | Primary entry point from customer service. |
| Card number (PAN, tokenized) / last 4 digits | `**** 1111` | Never search/display raw PAN — use `pan_token` + masked display. |
| Transaction ID (internal UUID) | `TXN-8d2c...` | Exact match, fastest path. |
| RRN | `987654321234` | Used when investigating a dispute/chargeback referencing a specific reference. |
| Auth Code | `A12345` | Cardholder often quotes this from a receipt. |
| Merchant name / Merchant ID | `Amazon` | Should support partial/fuzzy match on name, exact on ID. |
| Amount (exact or range) | `₹9,850` or `₹9,000–₹10,000` | Combine with date range to narrow results. |
| Date / date range | `2026-06-01 to 2026-06-30` | Should default to statement-cycle-aligned ranges as a UX convenience. |
| Transaction status/state | `Disputed`, `Posted`, `Chargebacked` | See lifecycle states in main doc Section 7.2. |

### 2.2 Result List View

Each result row should show, at minimum: transaction date, posting date, merchant name, amount, currency, current lifecycle state, and a flag indicating whether the transaction has related events (reversal/adjustment/dispute) — a quick visual cue before opening full detail.

### 2.3 Transaction Detail View

Opening a transaction must assemble a full picture from across the aggregate, not just the master row:

- Original authorization (amount, date/time, auth code, approval/decline reason)
- All identifiers (STAN, RRN, auth code, network reference) — see main doc Section 6
- Clearing/settlement record(s), with amount variance from original auth highlighted
- Full event timeline (chronological list of every `transaction_events` entry — reuse the event log directly; this view is effectively "replay and display")
- Any adjustments/reversals, with reason codes and who/what triggered them
- Statement linkage (which statement/cycle the transaction appears on, if any)
- Dispute/chargeback case reference, if one exists, with a link/deep-link into the Dispute workflow (see `08_chargebacks_disputes.md`)

### 2.4 Cardholder-Facing vs. Internal Views

Two distinct presentation layers over the same read model:

- **Internal (ops/CS) view** — full detail including internal IDs, network references, raw event log, and any operational flags.
- **Cardholder-facing view** (app/web/statement drill-down) — simplified: merchant, amount, date, status in plain language (e.g., "Pending" instead of `AUTHORIZED`), and a "Don't recognize this transaction?" action that opens the dispute flow.

> **Developer Note:** Do not expose internal event-type names or state-machine terminology directly to cardholders — maintain a status-mapping table (`AUTHORIZED → "Pending"`, `DISPUTED → "Under Review"`, etc.) so internal model changes don't leak into customer-facing copy.

## 3. Non-Functional Requirements

- **Read/write separation**: back this with a dedicated query/read-model (e.g., a materialized view or projection table built off `transaction_events`), not live joins across every write-side table, to keep inquiry latency low under call-center load.
- **Pagination & performance**: multi-year, multi-account search must be paginated and indexed on the common search keys in Section 2.1 (account_id, card_id/pan_token, merchant_id, date range, RRN).
- **PCI scope**: full PAN must never be persisted or rendered in the inquiry read model — only tokens and masked forms.
- **Audit logging**: every inquiry access by an internal user should itself be logged (who viewed which cardholder's transaction, when) for compliance.

## 4. Suggested Elixir/Phoenix Implementation Sketch

```
transactions/
  inquiry/
    transaction_search.ex     # query context: builds filters, paginates
    transaction_projection.ex # read-model projection built from transaction_events
    transaction_view.ex       # detail assembly (auth + clearing + events + disputes)
```

Populate the projection asynchronously off the same event stream that drives the state machine (Section 7.3 of the main doc) via a PubSub subscriber or Broadway consumer — keeps inquiry reads decoupled from the write path.

## 5. Open Questions for SME / Product Validation

- Exact role-based access rules: which fields are visible to which internal roles (Tier 1 CS vs. Tier 2 Ops vs. Compliance)?
- Retention/archival cutoff for online (fast) search vs. archived (slower, compliance-only) search — ties to main doc Section 7.2, State 13 (Archived).
- Whether merchant-name fuzzy search needs a dedicated search index (e.g., Postgres trigram/`pg_trgm`, or an external search service) given expected data volume.
