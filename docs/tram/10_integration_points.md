# 10 — TRAM Integration Points

**Parent document:** [TRAM_Module_Developer_Requirements.md](./TRAM_Module_Developer_Requirements.md)
**Status:** ⚠️ Drafted from general card-management integration domain knowledge — **not extracted from the source docx**. Validate message formats/SLAs against actual FAS/CMS/Collections/Letter Management interfaces once defined.

---

## 1. Purpose

Defines the contracts between TRAM and the other VisionPLUS-equivalent domains (FAS, CMS/Ledger, Billing, Collections, Letter Management), building on the high-level table in the main document's Section 8.

## 2. Integration Contracts

### 2.1 FAS → TRAM (Authorization Feed)

- **Trigger**: FAS approves or declines an authorization request.
- **Payload must include**: account_id, card_id (or pan_token), merchant_id, amount, currency, approval/decline code, STAN, auth_datetime (see main doc Section 6.2 for identifier definitions).
- **TRAM action**: create/update the transaction aggregate, emit `AuthorizationApproved` (or record decline for research purposes, per main doc's "Module 1A" framing — declines are not part of the transaction lifecycle proper but may still need to be queryable for fraud/ops investigation).
- **Idempotency**: use STAN + auth_datetime + account_id (or a network-provided idempotency key if available) to detect and ignore duplicate delivery — FAS may retry on timeout.

### 2.2 Acquirer/Network → TRAM (Clearing/Settlement Feed)

- **Trigger**: merchant settlement/clearing file or message arrives (may be real-time or batch-delivered — see `09_batch_processing.md` Section 2.1).
- **TRAM action**: run matching hierarchy (main doc Section 6.4) against open authorizations, emit `SettlementReceived`, and — if within a reasonable window — auto-progress to `CLEARED` (main doc Section 7.2, State 5).
- **Unmatched handling**: settlements that can't be matched to any open authorization must land in a review queue (production-support scenario — `11_troubleshooting_production_support.md`), never silently dropped or force-matched to a "best guess."

### 2.3 TRAM → CMS/Ledger (Posting Feed)

- **Trigger**: `TransactionPosted` event emitted (main doc Section 7.2, State 6).
- **Payload must include**: transaction_id, account_id, amount, posting_date, transaction_type.
- **CMS action**: create receivable, reduce available credit → outstanding balance transition (main doc Section 7.2, State 6 note on "two separate ledgers").
- **Idempotency**: CMS must dedupe on `transaction_id` — TRAM should guarantee at-least-once delivery (e.g., via Oban job with retry, or a durable PubSub/Kafka topic) and CMS must be safe to receive the same posting event more than once.
- **Failure handling**: if CMS rejects a posting (e.g., account closed/frozen), TRAM must receive a rejection signal and route the transaction to a manual review queue rather than silently retrying indefinitely.

### 2.4 TRAM → Billing (Statement Feed)

- **Trigger**: statement cutoff extraction batch job (`07_statement_transaction_processing.md`, `09_batch_processing.md` Section 2.4).
- **Payload**: statementable transaction set for the cycle, per the fields listed in `07_statement_transaction_processing.md` Section 2.3.
- **Contract**: Billing treats this as the authoritative, final set for the cycle once delivered — any later corrections must arrive as new line items on a subsequent cycle (main doc's non-mutation-of-past-statements principle).

### 2.5 TRAM → Collections (Delinquency Signal)

- **Trigger**: transactions contributing to an overdue/delinquent balance, or transactions under active dispute that affect collections treatment (a disputed transaction should typically be excluded from collections escalation until resolved).
- **Payload**: transaction-level detail supporting collections' need to explain the debt to the cardholder (same detail set as Transaction Inquiry, `04_transaction_inquiry.md`).
- **TRAM action**: expose a query/read API (or publish relevant events) rather than pushing a bespoke feed — Collections is primarily a **consumer** of transaction history via inquiry-style access.

### 2.6 TRAM → Letter Management (Correspondence Triggers)

- **Trigger examples**: dispute acknowledgment letter, provisional credit notice, chargeback outcome notice, statement-related correspondence.
- **TRAM action**: publish the relevant domain event (`DisputeCreated`, `ChargebackReversed`, etc. — see `08_chargebacks_disputes.md`); Letter Management subscribes and generates correspondence — TRAM should not be responsible for letter content/formatting itself.

## 3. Cross-Cutting Integration Requirements

- **Event schema versioning**: every published event (`AuthorizationApproved`, `TransactionPosted`, `DisputeCreated`, etc.) needs a version field from day one — schemas will evolve (e.g., adding installment/BNPL fields per the main document's Section 7.3 forward-looking note) and consumers need a defined upgrade path.
- **Idempotency keys**: every cross-context message needs an explicit idempotency key (`transaction_id` + event type + sequence, or a dedicated `event_id`) — consumers must be built to safely process duplicates, since at-least-once delivery is the realistic guarantee for most transport choices (Phoenix PubSub, Kafka, RabbitMQ, Oban).
- **Retry & backoff**: failed downstream delivery (e.g., CMS temporarily unavailable) should retry with exponential backoff and eventually route to a dead-letter/manual-review path rather than blocking the publishing job indefinitely.
- **Delivery guarantee choice**: decide per-integration whether Phoenix PubSub (in-process, simplest, but not durable across restarts) is sufficient, or whether a durable broker (Kafka/RabbitMQ) or Oban-backed outbox pattern is required — posting/statement/dispute events likely warrant durability given their financial/regulatory weight; purely UI-refresh-type notifications may not.

## 4. Suggested Elixir/Phoenix Implementation Sketch

```
transactions/
  integration/
    fas_consumer.ex             # ingest AuthorizationApproved/Declined
    settlement_consumer.ex      # ingest clearing/settlement feed
    posting_publisher.ex        # publish TransactionPosted (outbox pattern recommended)
    statement_publisher.ex      # publish statement extraction results
    event_schema.ex             # versioned event structs + validation
```

Recommend an **outbox pattern** (write event + outbox row in the same DB transaction, separate process publishes from the outbox) for financially significant events (posting, disputes, chargebacks) to guarantee at-least-once delivery even across process crashes — a plain in-memory PubSub broadcast is not sufficient for these.

## 5. Open Questions for SME / Product Validation

- Actual transport choice(s) available/standardized across the platform (Kafka vs. RabbitMQ vs. Phoenix PubSub-only) — this document assumes flexibility; align with platform-wide infra decisions.
- CMS's actual idempotency/rejection contract (what a rejection response looks like, what reasons are possible).
- Whether Collections needs a push feed or is satisfied with pull/query access.
