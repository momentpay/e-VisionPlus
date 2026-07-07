# 07 — Statement Transaction Processing

**Parent document:** [TRAM_Module_Developer_Requirements.md](./TRAM_Module_Developer_Requirements.md)
**Status:** ⚠️ Drafted from general VisionPLUS / card-management domain knowledge — **not extracted from the source docx**. Validate cutoff rules and formatting requirements against actual Billing module specs.

---

## 1. Purpose

Statement Transaction Processing is the bridge between TRAM (transaction history) and the Billing module (statement generation). This spec defines what TRAM must supply so Billing can produce an accurate, complete statement each cycle — it does not define statement layout/interest calculation itself (owned by Billing), only the transaction-side inputs and cutoff behavior.

## 2. Functional Requirements

### 2.1 Statement Cycle & Cutoff

- Each account has a **billing cycle** (defined in CMS/Billing, referenced by TRAM) with a cycle start/end date and a cutoff time.
- At cutoff, TRAM must produce the definitive set of transactions "statementable" for that cycle: all transactions that reached `POSTED` state (main doc Section 7.2, State 6) on or before the cutoff, and have not already been included in a prior statement.
- Transactions still in earlier states (`AUTHORIZED`, `CLEARED` but not yet `POSTED`) at cutoff must **not** appear on the current statement — they roll to the next cycle once posted, per standard practice.
- Reversals/adjustments that land **after** cutoff for a transaction already statemented in a prior cycle must appear as their own entries on the **current** cycle's statement (see `06_reversals_adjustments.md` Section 3.5), never by silently editing a past, already-issued statement.

### 2.2 Transaction Grouping

Statement line items are typically grouped/sequenced by:

- Posting date (primary sort, most common convention)
- Transaction type (purchases vs. cash advances vs. fees vs. payments vs. adjustments — often shown in separate statement sections)
- Foreign currency transactions may need a distinct sub-section showing original currency, FX rate applied, and converted amount

### 2.3 Data TRAM Must Provide per Statement Line

| Field | Source | Notes |
|---|---|---|
| Transaction date | Authorization event | Date of original purchase, not posting date. |
| Posting date | `TransactionPosted` event | Date it hit the ledger. |
| Merchant name / MCC | Merchant entity (main doc Section 5.2) | Descriptive text as it should appear on the statement (may differ from raw network merchant string — see `05_transaction_maintenance.md` for correction path). |
| Amount (transaction currency + billing currency) | Clearing/Settlement record | Include FX rate if cross-currency. |
| Reference number | `transaction_identifiers` (main doc Section 6) | The RRN or equivalent shown to the cardholder for later dispute reference — this is what the cardholder will quote back when disputing. |
| Adjustment/reversal indicator | Adjustments/Reversals events | Flag so Billing can render it distinctly (e.g., "Credit Adjustment — Ref TXN-1234"). |

### 2.4 Statement Regeneration / Reprint

- TRAM must support **re-deriving** the exact transaction set for any past statement cycle on demand (e.g., customer requests a reprinted statement, or an internal audit needs to reconstruct it) — this should be a pure function of "replay events up to the original cutoff timestamp," which is a natural fit for the event-sourced design in the main document (Section 7.3). This is one of the concrete payoffs of that architecture choice.

## 3. Non-Functional Requirements

- Statement transaction extraction is a **batch-shaped** operation (whole-account-base, cycle-driven) — see `09_batch_processing.md` for how this should be scheduled/executed (e.g., an Oban/Broadway job per billing-cycle-date bucket, since customers are typically spread across multiple cycle dates per month).
- Must be idempotent: re-running the extraction for a cycle that has already been finalized must not duplicate or alter the finalized statement — only genuinely new events (adjustments/reversals arriving late) should produce new line items on a **later** cycle, per Section 2.1.

## 4. Suggested Elixir/Phoenix Implementation Sketch

```
transactions/
  statement/
    statement_extraction.ex   # given account_id + cycle window, returns statementable txns
    statement_cutoff.ex       # cutoff time/state rules
billing/                       # separate context — consumes extraction output
  statement_generation.ex
```

`statement_extraction.ex` should query the event-sourced projection (not raw live tables) so that "what was true as of cutoff" is answerable even if the transaction has since moved further in its lifecycle (e.g., disputed after statementing).

## 5. Open Questions for SME / Product Validation

- Exact cutoff time definition (per-account cycle date, timezone handling, and how late-arriving clearing records near the cutoff boundary are handled — a common source of "why isn't this transaction on my statement" support calls).
- Whether foreign-currency transactions require a dedicated statement section/format, and current FX markup disclosure requirements (often a regulatory requirement, not just a formatting preference).
- Exact set of transaction types (purchase, cash advance, fee, interest, payment, adjustment) and their required grouping/section order on the actual statement layout — owned by Billing but needs alignment with TRAM's `transaction_type` taxonomy (main doc Section 5.2).
