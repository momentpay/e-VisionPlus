# 11 — Troubleshooting / Production Support

**Parent document:** [TRAM_Module_Developer_Requirements.md](./TRAM_Module_Developer_Requirements.md)
**Status:** ⚠️ Drafted from general card-management production-support domain knowledge — **not extracted from the source docx** (which names these scenarios but doesn't detail them). Treat as a starting runbook skeleton to be expanded with real incidents post-launch.

---

## 1. Purpose

Captures the recurring failure patterns in transaction processing systems (named in the original roadmap as Module 11) and gives developers/on-call a starting diagnostic path for each, framed around the architecture defined in this document set.

## 2. Scenario: Missing Transaction

**Symptom**: Cardholder/CS reports a transaction that should exist (receipt in hand, merchant confirms charge) but doesn't appear in Transaction Inquiry (`04_transaction_inquiry.md`).

**Likely causes**:
- Authorization feed from FAS failed to deliver or was rejected before reaching TRAM (`10_integration_points.md`, Section 2.1) — check FAS-side delivery logs / dead-letter queue.
- Settlement arrived but failed matching (Section 6.4 hierarchy) and landed in the unmatched-review queue (`10_integration_points.md`, Section 2.2) rather than attaching to an existing transaction.
- Transaction was archived (main doc Section 7.2, State 13) and the inquiry search is only hitting the "hot" projection, not the cold-archive search path (`04_transaction_inquiry.md`, Open Questions).

**Diagnostic steps**: search the unmatched-settlement review queue by amount/merchant/date; check FAS delivery logs for the STAN/timeframe in question; check archive search if the transaction is old enough to plausibly be archived.

## 3. Scenario: Duplicate Transaction

**Symptom**: Same purchase appears twice (double posting, double statement line, or double dispute case).

**Likely causes**:
- Idempotency key missing or not enforced on a re-delivered FAS/settlement message (`10_integration_points.md`, Section 3 — idempotency keys).
- Batch job re-run after partial failure without proper checkpointing (`09_batch_processing.md`, Section 2.1) reprocessed already-loaded records.
- Manual re-drive (`05_transaction_maintenance.md`, Section 2.1) performed without checking the transaction wasn't already re-processed by an automated retry.

**Diagnostic steps**: check `transaction_identifiers` for two `transaction_id`s sharing the same STAN/RRN (a violation that should be rare/impossible if de-dup is correctly enforced — treat any occurrence as a defect, not routine noise); check batch job run logs for the affected date/time for repeat executions.

**Resolution**: requires a Maintenance action (`05_transaction_maintenance.md`) to void/merge the duplicate, with an event trail explaining the correction — never simply delete a row, since that breaks the audit trail principle in the main document's Section 4 ("Audit Problem").

## 4. Scenario: Posting Failure

**Symptom**: Transaction stuck in `CLEARED`, never reaches `POSTED` (main doc Section 7.2, States 5→6); no receivable appears in CMS.

**Likely causes**:
- CMS rejected the posting event (account closed/frozen/over-limit) and the rejection wasn't routed to a visible review queue (`10_integration_points.md`, Section 2.3 — failure handling).
- Posting cycle batch job failed partway or excluded the transaction due to a hold flag from Maintenance (`09_batch_processing.md`, Section 2.2).
- Event publishing failure between TRAM and CMS (transport-level issue — check outbox/dead-letter state per `10_integration_points.md`, Section 4).

**Diagnostic steps**: check posting-cycle job logs for the transaction_id; check for an active hold/flag on the transaction (Maintenance history); check CMS-side rejection log for the account.

## 5. Scenario: Reconciliation Break

**Symptom**: Daily reconciliation job (`09_batch_processing.md`, Section 2.6) flags a mismatch between TRAM totals and network/CMS totals.

**Likely causes**:
- A settlement was matched to the wrong authorization (matching hierarchy edge case, main doc Section 6.4) — amounts land against the wrong account.
- An adjustment or reversal event failed to reach CMS (integration failure, `10_integration_points.md` Section 2.3), so TRAM shows the corrected amount but CMS still reflects the original.
- Timing difference — a transaction posted just before/after a reconciliation cutoff boundary, causing an apparent (but not real) break for that single run.

**Diagnostic steps**: use the reconciliation report's per-batch/per-cycle breakdown (not just a pass/fail signal — see `09_batch_processing.md`, Section 2.6) to isolate the affected batch; cross-check the specific transaction's event history (main doc Section 7.3 replay) against CMS's ledger entries.

## 6. General Production-Support Principles

- **Always resolve via the event log, not direct data edits.** Every fix should be expressed as a new event (a correcting `AdjustmentApplied`, a `TransactionMaintenanceApplied`, etc.) so the "what happened and why" audit trail (main doc Section 4) is never broken by a support fix.
- **Every unmatched/failed/rejected item needs a visible queue.** Nothing should silently disappear — if it can't be auto-processed, it must land somewhere a human can see and act on it (unmatched settlements, CMS rejections, batch job failures).
- **Reproduce from history first.** Because the design is event-sourced (main doc Section 7.3), most "what happened" questions should be answerable by replaying `transaction_events` for the affected transaction before reaching for logs or database inspection.

## 7. Open Items for a Complete Runbook

This file is a skeleton. A complete production runbook should additionally include, once available:

- Actual alerting/paging thresholds per scenario (e.g., how many unmatched settlements before it pages on-call).
- Ownership/escalation matrix (which team owns FAS-side vs. CMS-side vs. network-side failures).
- A living log of real incidents and their root causes, to keep this document current — the scenarios above are the well-known categories from general card-processing experience, not an exhaustive list specific to this platform's actual failure history.
