# 06 — Reversals & Adjustments

**Parent document:** [TRAM_Module_Developer_Requirements.md](./TRAM_Module_Developer_Requirements.md)
**Status:** ⚠️ Concepts covered in main doc Sections 5 & 7 (State 4, State 5); this file adds the **functional rules** needed to implement them, drafted from general card-management domain knowledge — **not extracted from the source docx**. Validate thresholds/limits against actual business policy.

---

## 1. Purpose

Reversals and Adjustments are the two mechanisms by which a transaction's **amount** changes after initial authorization, without being a dispute/chargeback. They are financial actions (unlike Maintenance, `05_transaction_maintenance.md`) and must be modeled as first-class events per the main document's event-sourced design (Section 7.3).

## 2. Definitions

| Term | Definition | Example (from main doc) |
|---|---|---|
| **Full Reversal** | The entire authorized amount is released/cancelled; no settlement follows. | Customer cancels a hotel booking before check-in; full ₹20,000 auth reversed. |
| **Partial Reversal** | Part of the authorized amount is released; remainder proceeds to settlement. | Fuel pump: ₹5,000 authorized, ₹2,000 actual — ₹3,000 partially reversed. |
| **Credit Adjustment** | A correction that increases the amount owed back to the cardholder (reduces posted amount). | Merchant over-charged; corrected downward. |
| **Debit Adjustment** | A correction that increases the amount posted against the cardholder. | Merchant under-charged; corrected upward (e.g., missed a service fee). |

## 3. Functional Rules

### 3.1 Reversal Triggers

- **Network-initiated**: an authorization reversal message arrives from the network/acquirer (most common — e.g., merchant terminal sends a reversal because the transaction was cancelled or timed out).
- **System-initiated (auto-expiry)**: an authorization that is never cleared within a configurable hold period (e.g., 7–10 days for most MCCs, longer for hotel/car-rental) should be automatically reversed to release held credit back to the cardholder. This requires a scheduled job (see `09_batch_processing.md`).
- **Manual (ops-initiated)**: an ops user manually reverses an authorization, typically discovered via Transaction Inquiry, and requires the maker-checker controls from `05_transaction_maintenance.md`.

### 3.2 Reversal Rules

- A reversal can only be applied to a transaction in `AUTHORIZED` or `AUTHORIZATION_MAINTENANCE` state (main doc Section 7.2, States 3–4) — never to a transaction already `POSTED`; a posted transaction requires an **adjustment**, not a reversal.
- Partial reversal amount must be ≤ remaining authorized (not-yet-settled) amount.
- Every reversal must record: original auth reference, reversed amount, remaining amount, reason (network code or manual reason), timestamp, and initiator (system/network/user).
- Emit `AuthorizationReversed` (full) or `AuthorizationPartiallyReversed` (partial) events — never mutate the original authorization record in place.

### 3.3 Adjustment Triggers

- **Merchant-submitted correction**: acquirer sends a corrected clearing record after initial settlement (common with tip adjustments, restaurant/hotel final-bill corrections).
- **Operational correction**: ops identifies a posting error (wrong amount posted due to a matching or data error) and issues a manual adjustment, again under maker-checker controls.
- **Currency/FX correction**: for cross-border transactions, a later FX rate correction from the network requires an adjustment to the posted local-currency amount.

### 3.4 Adjustment Rules

- Adjustments can only be applied to a transaction that has reached `POSTED` (main doc Section 7.2, State 6) or later — pre-posting corrections should go through Reversal or Maintenance, not Adjustment.
- Every adjustment must record: transaction reference, old amount, new amount, delta, reason code, and must emit an `AdjustmentApplied` event that is picked up by the Ledger/CMS integration (`10_integration_points.md`) to correct the outstanding balance — never adjust CMS balances directly from this context; always go through the published event.
- Adjustments should have a configurable **approval threshold** (e.g., adjustments above a certain amount require supervisor approval) — exact threshold is a business-policy input, not a technical one (see Open Questions).
- Adjustments must be linked back to the original transaction, not created as new standalone transactions, so statement/dispute history remains coherent (main doc Section 5.2, `adjustments` table).

### 3.5 Interaction with Statements & Disputes

- A reversal that completes **before** the statement cycle closes should never appear on the statement at all (or should appear net of the reversal, depending on timing — see `07_statement_transaction_processing.md` for cutoff rules).
- A reversal or adjustment that completes **after** the statement cycle closes must appear as its own line item on the **next** statement, referencing the original transaction.
- A dispute raised against a transaction that already has an adjustment history must show the full adjustment chain to the dispute investigator (`08_chargebacks_disputes.md`).

## 4. Suggested Elixir/Phoenix Implementation Sketch

```
transactions/
  reversals/
    reversal_command.ex        # validates state, amount bounds
    reversal_event.ex          # AuthorizationReversed / PartiallyReversed
  adjustments/
    adjustment_command.ex      # validates state, approval threshold
    adjustment_event.ex        # AdjustmentApplied
    adjustment_approval.ex     # maker-checker for above-threshold adjustments
```

Both should reuse the same command → validate → event → publish pipeline as the rest of the lifecycle (main doc Section 7.4), with validation guards specific to the state rules in Sections 3.2 and 3.4 above.

## 5. Open Questions for SME / Product Validation

- Exact auto-expiry hold periods per MCC/transaction type (varies by network rules — e.g., hotel/car rental typically hold longer than retail).
- Adjustment approval thresholds and role mapping.
- Whether partial reversals need to support **multiple sequential** partial reversals against one authorization (e.g., a hotel authorization adjusted three times before final settlement), and how the remaining-balance tracking should behave in that case.
- Currency/FX adjustment policy — who absorbs rounding differences (issuer vs. cardholder vs. merchant) and how that's represented in the adjustment record.
