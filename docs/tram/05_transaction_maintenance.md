# 05 — Transaction Maintenance

**Parent document:** [TRAM_Module_Developer_Requirements.md](./TRAM_Module_Developer_Requirements.md)
**Status:** ⚠️ Drafted from general VisionPLUS / card-management domain knowledge — **not extracted from the source docx**. Validate against actual operational policy before finalizing.

---

## 1. Purpose

Transaction Maintenance covers the **controlled, manual write operations** performed by operations/back-office staff directly against a transaction record — distinct from the automated lifecycle transitions in the main document's Section 7 (which are driven by incoming authorization/clearing/dispute messages) and distinct from Reversals & Adjustments (`06_reversals_adjustments.md`), which are financial in nature.

Typical legacy VisionPLUS maintenance actions include: correcting merchant description/MCC on a posted transaction, correcting a misapplied date, re-linking a misrouted settlement to the correct authorization, manually flagging a transaction (e.g., for fraud review), and manually forcing a status transition when automated matching fails (see `11_troubleshooting_production_support.md`).

## 2. Functional Requirements

### 2.1 Categories of Maintenance Actions

| Category | Example | Financial Impact |
|---|---|---|
| **Descriptive correction** | Fix garbled merchant name/MCC from a bad network feed | None |
| **Linkage correction** | Re-link an orphaned settlement to the correct authorization (mismatch in Section 6.4 matching) | None directly, but corrects downstream posting |
| **Manual status override** | Force a stuck transaction from `CLEARED` to `POSTED` after investigating a batch failure | Indirect — triggers posting effects |
| **Flagging** | Mark transaction for fraud/compliance review; suppress from statement pending review | None, but blocks downstream processing |
| **Manual re-drive** | Re-submit a transaction into the posting pipeline after a fix | Indirect |

> **Developer Note:** Any maintenance action that changes an **amount** (not just descriptive/linkage data) is a financial adjustment and belongs in `06_reversals_adjustments.md`, not here — keep these two contexts cleanly separated in code (`transactions/maintenance` vs `transactions/adjustments`) even though they're often presented together in a single ops UI.

### 2.2 Operational Controls

- **Role-based authorization**: maintenance actions must be restricted by role (e.g., Tier 1 ops cannot override status; only Tier 2/Supervisor can force-transition a transaction).
- **Maker-checker (dual control)**: any action with downstream financial effect (status override that triggers posting, linkage correction that changes which account/statement a transaction lands on) should require a second approver before committing — standard practice in card platforms and a common regulatory expectation.
- **Reason code required**: every maintenance action must capture a reason/comment; free-text alone is insufficient — use a controlled reason-code list (e.g., `DATA_CORRECTION`, `MATCHING_ERROR`, `FRAUD_HOLD`, `MANUAL_REDRIVE`) plus optional free text.
- **Full audit trail**: every maintenance action must itself be recorded as an event (`TransactionMaintenanceApplied` with actor, reason, before/after values) — consistent with the event-sourced design in the main document's Section 7.3, so maintenance history is queryable the same way lifecycle history is.
- **Reversibility**: descriptive/linkage corrections should be reversible (keep prior value in the event payload); manual status overrides should be logged such that "why did this transaction skip a state" is always answerable later.

### 2.3 Typical Ops Workflow

1. Ops user locates transaction via Transaction Inquiry (`04_transaction_inquiry.md`).
2. Ops user selects a maintenance action, provides reason code + comment.
3. If action requires dual control, a second approver reviews and confirms before it commits.
4. System emits a `TransactionMaintenanceApplied` (or specific subtype) event, updates the projection, and — if the action affects downstream state (e.g., force-post) — publishes the appropriate lifecycle event so CMS/Billing pick it up normally rather than through a special-cased code path.

## 3. Suggested Elixir/Phoenix Implementation Sketch

```
transactions/
  maintenance/
    maintenance_command.ex     # validates role + reason code, dispatches
    maintenance_approval.ex    # maker-checker workflow state
    maintenance_event.ex       # TransactionMaintenanceApplied and subtypes
```

Route any maintenance action with downstream financial/posting effect back through the **same command → validation → event** pipeline used for normal lifecycle transitions (main doc Section 7.4), rather than mutating `transactions` rows directly — this keeps Maintenance from becoming a backdoor that bypasses the event log.

## 4. Open Questions for SME / Product Validation

- Full list of allowed reason codes and which roles can use each.
- Which maintenance actions require dual control vs. single-approver, and any monetary/impact thresholds that change the approval requirement.
- SLA expectations for manual maintenance queues (e.g., fraud-hold review turnaround).
- Whether maintenance actions need to be reversible/undoable by a subsequent maintenance action, or only correctable going forward.
