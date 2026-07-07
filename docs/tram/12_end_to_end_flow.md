# 12 — End-to-End VisionPLUS Transaction Flow

**Parent document:** [TRAM_Module_Developer_Requirements.md](./TRAM_Module_Developer_Requirements.md)
**Status:** ⚠️ Assembled from concepts scattered throughout the main document (Sections 4, 7) plus the sub-specs below, per general card-management domain knowledge — **not extracted from the source docx as a single artifact**. Treat as the integration/reference view; validate against the detailed specs it summarizes.

---

## 1. Purpose

Provides one consolidated sequence view of a transaction's full journey across every domain, referencing the detailed specs for each stage. Use this as an onboarding/reference diagram, not as the primary spec for any individual stage.

## 2. End-to-End Sequence

```
1. AUTHORIZATION
   Merchant → Network → FAS
   FAS approves/declines → publishes to TRAM
   (main doc Sections 4.1, 7.2 State 2-3; 10_integration_points.md Section 2.1)

2. AUTHORIZATION MAINTENANCE (optional)
   Incremental auth / partial reversal events
   (main doc Section 7.2 State 4; 06_reversals_adjustments.md)

3. CLEARING / SETTLEMENT
   Acquirer/Network → TRAM
   TRAM matches settlement to original authorization
   (main doc Section 6.4; 10_integration_points.md Section 2.2)

4. POSTING
   TRAM → CMS/Ledger
   CMS creates receivable, reduces available credit / increases outstanding balance
   (main doc Section 7.2 State 6; 10_integration_points.md Section 2.3)
   [Batch posting cycle: 09_batch_processing.md Section 2.2]

5. STATEMENT
   TRAM → Billing (at cycle cutoff)
   Statementable transactions extracted, statement generated
   (main doc Section 7.2 State 7; 07_statement_transaction_processing.md)
   [Batch extraction: 09_batch_processing.md Section 2.4]

6. PAYMENT
   Cardholder pays → CMS applies payment
   Ideally allocated at transaction level
   (main doc Section 7.2 State 8)

7. DELINQUENCY (if unpaid)
   CMS/Billing → Collections
   Transaction-level detail available on demand for collections treatment
   (10_integration_points.md Section 2.5)

8. DISPUTE (if raised)
   Cardholder → TRAM/Dispute case
   Full prior history preserved; provisional credit triggered
   (main doc Section 7.2 State 9; 08_chargebacks_disputes.md Sections 3.1-3.2)

9. CHARGEBACK (if escalated)
   TRAM/Dispute case → Network
   Chargeback processed, funds returned to cardholder
   (main doc Section 7.2 State 10; 08_chargebacks_disputes.md Section 3.3)

10. REPRESENTMENT / RESOLUTION
    Merchant contests → accepted (chargeback reversed) or rejected (arbitration)
    (main doc Section 7.2 State 11; 08_chargebacks_disputes.md Section 3.4)

11. CLOSURE
    Transaction finalized, no further activity
    (main doc Section 7.2 State 12)

12. ARCHIVE
    Moved to cold storage, still searchable for compliance
    (main doc Section 7.2 State 13; 09_batch_processing.md Section 2.5)
```

## 3. Cross-Domain Participants at Each Stage

| Stage | Primary Domain | Consumers |
|---|---|---|
| Authorization | FAS | TRAM |
| Clearing/Settlement | TRAM | — |
| Posting | TRAM → CMS/Ledger | Billing (indirectly, via balance) |
| Statement | TRAM → Billing | Cardholder (statement view), Collections (if overdue) |
| Payment | CMS/Ledger | TRAM (allocation reference), Collections |
| Delinquency | Collections | Letter Management (correspondence) |
| Dispute/Chargeback | TRAM (Dispute context) | CMS/Ledger (provisional credit), Letter Management, Collections (pause escalation) |
| Archive | TRAM | Compliance/Audit (query access) |

## 4. Where to Apply Your Own VisionPLUS Knowledge

Every stage above links back to a sub-spec that is explicitly flagged as **drafted, not extracted** from the source material. Before treating any stage as final:

- Compare against actual current VisionPLUS screen flows / batch job names if you have access to the legacy system or its documentation.
- Validate timelines (dispute windows, hold periods, statement cutoffs) against your actual network agreements and regulatory obligations — these vary by issuer, market, and network, and get updated periodically.
- Confirm the exact field-level data contracts with whichever team owns FAS, CMS, Billing, and Collections in this implementation, since this document assumes reasonable/standard contracts, not confirmed ones.

## 5. Suggested Use

Use this file as the **table of contents for a whiteboard/architecture walkthrough** with the wider team — each numbered stage is a natural checkpoint to confirm domain ownership, data contracts, and open questions (collected at the end of each linked sub-spec) before implementation begins.
