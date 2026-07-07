# 09 — Batch Processing in TRAM

**Parent document:** [TRAM_Module_Developer_Requirements.md](./TRAM_Module_Developer_Requirements.md)
**Status:** ⚠️ Drafted from general VisionPLUS / card-management batch-processing domain knowledge — **not extracted from the source docx**. Validate schedules/SLAs against actual operational requirements.

---

## 1. Purpose

Legacy VisionPLUS relies heavily on nightly/scheduled batch jobs (mainframe COBOL batch programs, per the main document's Section 4.3) because the underlying platform wasn't real-time. E-VisionPlus can process much of this in near-real-time via Elixir/OTP, but several TRAM functions remain inherently **batch-shaped** — they operate over a full data set on a schedule, not per-event — and should be implemented as such using Oban/Broadway rather than forced into a synchronous request path.

## 2. Batch Job Categories

### 2.1 Daily Transaction Load

- Ingests bulk authorization/clearing/settlement files from networks/acquirers that arrive on a schedule rather than as individual real-time messages (common for acquirer settlement files, even in modern systems).
- Must run the same matching logic as real-time ingestion (main doc Section 6.4) but at volume — needs to handle partial failures per-record without failing the whole batch (a bad record shouldn't block the other 100,000 in the file).
- Should be idempotent/re-runnable: if a load job fails partway or a file is redelivered, re-processing must not create duplicate transactions (tie to `transaction_identifiers` uniqueness — main doc Section 5.2/6.3 — as the de-dup key).

### 2.2 Posting Cycles

- Periodic (often nightly, sometimes intraday for real-time-capable rails) job that moves `CLEARED` transactions to `POSTED` (main doc Section 7.2, States 5→6), publishing the `TransactionPosted` event that CMS/Ledger consumes to create receivables.
- Must respect any pending holds (fraud flag from Maintenance, `05_transaction_maintenance.md`) — held transactions should be skipped, not force-posted.

### 2.3 Authorization Auto-Expiry / Reversal Sweep

- Scheduled job that scans for authorizations past their hold period without a matching clearing record and auto-reverses them (see `06_reversals_adjustments.md`, Section 3.1) to release held credit back to the cardholder.
- Hold period is configurable per MCC/transaction type (Open Question in `06_reversals_adjustments.md`).

### 2.4 Statement Cutoff Extraction

- Per-cycle-date batch job that extracts statementable transactions for every account whose cycle closes that day (see `07_statement_transaction_processing.md`) and hands off to Billing.
- Since customers are spread across many cycle dates within a month, this runs daily against the subset of accounts due that day, not once a month for everyone.

### 2.5 Purge / Archive Processing

- Transactions past the "online/fast search" retention window (main doc Section 7.2, State 13 — Archived) should be moved to cold/archival storage on a scheduled basis, remaining searchable (per compliance/audit requirements — main doc Section 4's "Audit Problem") but no longer part of the hot operational path.
- Must never purge a transaction that has an **open** dispute/chargeback case, regardless of age — archival eligibility should check dispute-case status, not just age.

### 2.6 Reconciliation Support

- Daily/periodic job comparing TRAM's transaction totals against network/acquirer settlement totals and against CMS ledger postings, flagging breaks (transactions in TRAM not reflected in CMS, or vice versa) for the production-support team (`11_troubleshooting_production_support.md`).
- Should produce a reconciliation report (counts + amounts, by batch/file, by cycle) rather than only a pass/fail signal, so breaks can be triaged without re-deriving totals from scratch.

## 3. Non-Functional Requirements

- **Idempotency**: every batch job must be safely re-runnable (via `transaction_identifiers` de-dup, or job-level checkpointing) since batch re-runs after partial failure are routine operationally.
- **Observability**: each job run should emit metrics (records processed, records failed, duration) and failures should page/alert per standard on-call practice, not just log silently.
- **Failure isolation**: a single bad record should not abort an entire batch run; failed records should land in a review queue (dead-letter equivalent) for manual handling via Maintenance.

## 4. Suggested Elixir/Phoenix Implementation Sketch

```
transactions/
  batch/
    daily_load_worker.ex        # Oban job / Broadway pipeline — bulk ingestion
    posting_cycle_worker.ex     # Oban job — CLEARED -> POSTED sweep
    auth_expiry_worker.ex       # Oban job — auto-reversal sweep
    statement_extraction_worker.ex  # Oban job, per cycle-date
    archive_worker.ex           # Oban job — cold storage migration
    reconciliation_worker.ex    # Oban job — produces recon report
```

Use **Broadway** for high-volume file ingestion (Section 2.1) where backpressure and per-message error handling matter, and **Oban** (with cron-style scheduling) for the periodic sweep/extraction/reconciliation jobs (Sections 2.2–2.6) where the unit of work is "run once per schedule, iterate a data set."

## 5. Open Questions for SME / Product Validation

- Exact batch windows/SLAs currently expected by operations (e.g., "posting must complete by 6am local time") — needed to size job concurrency and choose real-time vs. batch for borderline cases.
- Archive retention period and any regulator-specific minimums (may differ by data type — transaction vs. dispute evidence vs. statement).
- Acceptable reconciliation break tolerance (exact-match required vs. a rounding/timing tolerance) and escalation path when a break is found.
